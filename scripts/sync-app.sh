#!/bin/bash
# sync-app.sh — Deploy kart-machine-manager to QEMU or RPi5 via rsync over SSH
#
# Usage: ./scripts/sync-app.sh [OPTIONS] [SRC_DIR]
#
# SRC_DIR: Local kart-machine-manager directory (default: ../kart-machine-manager)
#          Deployed to /opt/kart/kart-machine-manager/ on target.
#          Service runs app/main.py from within.
#
# Target options (default: --qemu):
#   --qemu            QEMU with TAP networking (root@192.168.7.2)
#   --qemu-slirp      QEMU with user-mode networking (root@localhost -p 2222)
#   --target HOST     Custom host/IP, connects as root@HOST
#   --host HOST       SSH config host name (user/port from ~/.ssh/config)
#
# Other options:
#   --no-restart      Skip kart-machine-manager service restart after deploy
#   -h, --help        Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
SRC_DIR=""
SSH_HOST="root@192.168.7.2"
SSH_PORT=""
OPT_RESTART=1
DEPLOY_DST="/opt/kart/kart-machine-manager/"

usage() {
    sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --qemu)        SSH_HOST="root@192.168.7.2"; SSH_PORT="" ;;
        --qemu-slirp)  SSH_HOST="root@localhost"; SSH_PORT="2222" ;;
        --target)      SSH_HOST="root@$2"; shift ;;
        --target=*)    SSH_HOST="root@${1#--target=}" ;;
        --host)        SSH_HOST="$2"; shift ;;
        --host=*)      SSH_HOST="${1#--host=}" ;;
        --no-restart)  OPT_RESTART=0 ;;
        -h|--help)     usage ;;
        -*)            echo "ERROR: unknown option: $1" >&2; exit 1 ;;
        *)             SRC_DIR="$1" ;;
    esac
    shift
done

SRC_DIR="${SRC_DIR:-${PROJECT_DIR}/../kart-machine-manager}"

if [[ ! -d "$SRC_DIR" ]]; then
    echo "ERROR: Source directory not found: $SRC_DIR" >&2
    exit 1
fi

# Build SSH/rsync options
SSH_OPTS=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no)
RSYNC_SSH="ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
if [[ -n "$SSH_PORT" ]]; then
    SSH_OPTS+=(-p "$SSH_PORT")
    RSYNC_SSH="$RSYNC_SSH -p $SSH_PORT"
fi

echo "==> Deploying $(realpath "$SRC_DIR") -> ${SSH_HOST}:${DEPLOY_DST}"

# Ensure parent directory exists
ssh "${SSH_OPTS[@]}" "$SSH_HOST" "mkdir -p $(dirname "${DEPLOY_DST%/}")"

# Precompile .pyc on host (using uv to ensure dependencies are available)
echo "==> Precompiling Python bytecode on host..."
(cd "$SRC_DIR/app" && uv run python -m compileall -q "$SRC_DIR") 2>/dev/null || true

rsync -avz --delete \
    -e "$RSYNC_SSH" \
    --exclude='.git/' \
    --exclude='.venv/' \
    --exclude='.ruff_cache/' \
    --exclude='log/' \
    --exclude='uv.lock' \
    --exclude='.python-version' \
    --exclude='.gitignore' \
    --exclude='ruff.toml' \
    --exclude='run_debug.sh' \
    "$SRC_DIR/" "${SSH_HOST}:${DEPLOY_DST}"

# Fix ownership
echo "==> Setting ownership to kart:kart"
ssh "${SSH_OPTS[@]}" "$SSH_HOST" "chown -R kart:kart ${DEPLOY_DST}"

if [[ "$OPT_RESTART" -eq 1 ]]; then
    echo "==> Restarting kart-machine-manager service"
    ssh "${SSH_OPTS[@]}" "$SSH_HOST" "systemctl restart kart-machine-manager"
    echo "==> Done. kart-machine-manager restarted."
else
    echo "==> Done. Service restart skipped (--no-restart)."
fi
