#!/usr/bin/env bash
#
# Install the agent on a host where Docker Hub, PyPI and public file hosts are all
# unreachable, but the distribution's own apt mirror works.
#
#   curl -fsSL <REPO>/install.sh | bash -s -- <REPO>
#
# Everything arrives over two channels that are reachable in practice on such
# hosts: the OS package mirror for dependencies, and GitHub over plain HTTPS for
# the code.
#
# No Docker: the base image cannot be pulled. No venv: python3-venv may be absent,
# and the distribution's own python3-* packages already provide every dependency
# compiled for this exact interpreter.

set -euo pipefail

REPO_RAW="${1:-}"
APP_DIR="${APP_DIR:-/opt/alpha/bybit-alpha}"
SERVICE=alpha-agent

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

PY=$(command -v python3) || die "python3 not found"

[[ "$(id -u)" -eq 0 ]] || die "run as root"
[[ "$REPO_RAW" =~ ^https?:// ]] || die "usage: curl -fsSL <repo>/install.sh | bash -s -- <repo-raw-url>"
REPO_RAW="${REPO_RAW%/}"

curl -fsSI --connect-timeout 15 -m 30 "${REPO_RAW}/install.sh" >/dev/null 2>&1 \
  || die "cannot reach ${REPO_RAW} — is the repository public and the path correct?"

# The agent's own dependencies. python3-pyarrow is optional: it is only needed to
# read/write the parquet cache, which the live agent never touches.
APT_REQUIRED="python3-pip python3-numpy python3-pandas python3-httpx python3-pydantic
python3-pydantic-settings python3-yaml python3-rich python3-tenacity python3-typer"
APT_OPTIONAL="python3-pyarrow python3-tzdata"

say "1/6 Installing Python dependencies from the OS mirror"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# shellcheck disable=SC2086
apt-get install -y -qq ${APT_REQUIRED} || die "apt could not install the required packages"
echo "  required packages installed"
for pkg in ${APT_OPTIONAL}; do
  if apt-get install -y -qq "${pkg}" >/dev/null 2>&1; then
    echo "  optional: ${pkg} installed"
  else
    warn "optional package ${pkg} is unavailable — continuing without it"
  fi
done

say "2/6 Fetching the agent  (python $("$PY" -c 'import sys; print("%d.%d" % sys.version_info[:2])'))"
TMP=$(mktemp -d); trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${APP_DIR}"
curl -fsSL --retry 3 --retry-delay 3 -m 300 "${REPO_RAW}/alpha-deploy.tgz" -o "${TMP}/agent.tgz" \
  || die "could not download alpha-deploy.tgz"
tar tzf "${TMP}/agent.tgz" >/dev/null 2>&1 || die "alpha-deploy.tgz is not a valid archive"
tar xzf "${TMP}/agent.tgz" -C "${APP_DIR}"
echo "  unpacked to ${APP_DIR}"

say "3/6 Verifying the imports"
export PYTHONPATH="${APP_DIR}/src"
"$PY" -c "
import alpha.cli, alpha.live.agent, alpha.risk.engine, alpha.execution.paper, alpha.data.validation
import numpy, pandas, httpx, pydantic
print('  pandas', pandas.__version__, '| numpy', numpy.__version__, '| httpx', httpx.__version__)
print('  every agent module imports')
" || die "the agent does not import — see the traceback above"

say "4/6 Configuring"
mkdir -p "${APP_DIR}/data/raw" "${APP_DIR}/reports"
[[ -f "${APP_DIR}/.env" ]] || { cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"; chmod 600 "${APP_DIR}/.env"; }

cat > /etc/systemd/system/${SERVICE}.service <<EOF
[Unit]
Description=bybit-alpha trading agent (paper)
After=network-online.target time-sync.target
Wants=network-online.target time-sync.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment=PYTHONPATH=${APP_DIR}/src
Environment=TZ=UTC
Environment=ALPHA_LOG_JSON=1
Environment=ALPHA_CONFIG=${APP_DIR}/config/default.yaml
ExecStart=${PY} -m alpha.cli paper --poll 30
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo "  systemd unit written"

say "5/6 Checking the exchange is reachable"
# Without Bybit the agent can do nothing, and this is exactly the sort of thing
# that is blocked on a filtered host — better to know now than to guess later.
if curl -fsS --connect-timeout 15 -m 30 "https://api.bybit.com/v5/market/time" >/dev/null 2>&1; then
  echo "  api.bybit.com: reachable"
else
  die "api.bybit.com is NOT reachable from this server.
     The agent would start and immediately stand aside.
     Test it directly:  curl -sI https://api.bybit.com/v5/market/time"
fi

say "6/6 Starting and verifying"
systemctl enable --now ${SERVICE}
for i in $(seq 1 12); do
  sleep 10
  if PYTHONPATH="${APP_DIR}/src" "$PY" -m alpha.cli health --data-root "${APP_DIR}/data/raw" 2>/dev/null; then
    echo
    echo "Agent is running in PAPER mode under systemd. Nothing can place a real order."
    echo
    echo "  systemctl status ${SERVICE}"
    echo "  journalctl -u ${SERVICE} -f"
    echo "  PYTHONPATH=${APP_DIR}/src python3 -m alpha.cli status"
    exit 0
  fi
  echo "  waiting for the first cycle (${i}/12)..."
done

warn "health is not green yet. Recent logs:"
journalctl -u ${SERVICE} -n 40 --no-pager || true
exit 1
