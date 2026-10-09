#!/usr/bin/env bash
#
# Install the agent on a host where Docker Hub, PyPI and public file hosts are all
# unreachable, but the distribution's own apt mirror works.
#
#   curl -fsSL <base>/install.sh | bash -s -- <owner/repo>
#
# Everything arrives over two channels that are reachable in practice on such
# hosts: the OS package mirror for dependencies, and GitHub over plain HTTPS for
# the code.
#
# The repository path is given as `owner/repo`, not as a URL, because
# raw.githubusercontent.com is unreliable from some networks — it answers for a
# while and then times out. The script therefore tries several independent
# mirrors of the same GitHub content and uses whichever responds.
#
# No Docker: the base image cannot be pulled. No venv: python3-venv may be absent,
# and the distribution's own python3-* packages already provide every dependency
# compiled for this exact interpreter.

set -euo pipefail

REPO_ARG="${1:-}"
APP_DIR="${APP_DIR:-/opt/alpha/bybit-alpha}"
SERVICE=alpha-agent

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

PY=$(command -v python3) || die "python3 not found"

[[ "$(id -u)" -eq 0 ]] || die "run as root"

# Accept either `owner/repo` or a full base URL. Both forms have been handed out at
# different points, and an installer that only understands one of them fails with a
# usage error that looks like a bug in the command rather than in the argument.
REPO="$REPO_ARG"
if [[ "$REPO" =~ ^https?:// ]]; then
  REPO="${REPO#*://}"
  REPO="${REPO#raw.githubusercontent.com/}"
  REPO="${REPO#cdn.jsdelivr.net/gh/}"
  REPO="${REPO#github.com/}"
  REPO="${REPO#gitcdn.link/repo/}"
  REPO="${REPO%@main}"; REPO="${REPO%/main}"; REPO="${REPO%/raw}"; REPO="${REPO%/}"
fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || die "usage: bash install.sh <owner/repo>   (or a raw base URL)"

# Independent mirrors of the same GitHub content. raw is canonical but is the one
# that fails intermittently from filtered networks, so the CDN is kept as a
# fallback.
CHANNELS=(
  "https://raw.githubusercontent.com/${REPO}/main"
  "https://cdn.jsdelivr.net/gh/${REPO}@main"
  "https://github.com/${REPO}/raw/main"
)

# Content validation, not just an HTTP status check.
#
# Some "GitHub proxies" answer 200 with a small HTML redirect page instead of the
# file — gitcdn.link did exactly that, returning 114 bytes where the file was
# 3 KB. An installer that trusts the status code would happily treat that as an
# archive and then fail somewhere far away from the real cause. So every download
# is verified by its actual bytes before it is used.
validate_content() {  # validate_content <filename> <path>
  local name="$1" path="$2"
  [[ -s "$path" ]] || return 1
  case "$name" in
    *.tgz|*.tar.gz)
      # gzip magic number, then a real tar listing.
      [[ "$(head -c 2 "$path" | od -An -tx1 | tr -d ' \n')" == "1f8b" ]] || return 1
      tar tzf "$path" >/dev/null 2>&1
      ;;
    *.sh)
      head -c 2 "$path" | grep -q '#!' || return 1
      # A redirect page is HTML; a shell script is not.
      ! grep -qi '<!doctype html>' "$path"
      ;;
    *)
      return 0
      ;;
  esac
}

fetch() {  # fetch <filename> <destination>
  local name="$1" dest="$2" base tmp
  tmp="${dest}.part"
  for base in "${CHANNELS[@]}"; do
    rm -f "$tmp"
    if curl -fsSL --connect-timeout 20 -m 240 "${base}/${name}" -o "$tmp" 2>/dev/null \
       && validate_content "$name" "$tmp"; then
      mv "$tmp" "$dest"
      echo "  ${name}  <-  ${base}"
      return 0
    fi
    echo "  ${name}  x   ${base} (unreachable or bad content)"
  done
  rm -f "$tmp"
  return 1
}

fetch install.sh "${APP_DIR}.selfcheck" \
  || die "no mirror could serve the repository — is ${REPO} public and the branch 'main'?"
rm -f "${APP_DIR}.selfcheck"

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
fetch alpha-deploy.tgz "${TMP}/agent.tgz" \
  || die "could not download alpha-deploy.tgz from any mirror"
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
