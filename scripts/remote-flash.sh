#!/bin/bash
# remote-flash.sh — Copy image + flash tool to remote PC, then flash
#
# Usage:
#   ./scripts/remote-flash.sh -sdcard user@remote-pc /dev/sdX
#   ./scripts/remote-flash.sh -sdcard user@remote-pc /dev/mmcblk0
#   ./scripts/remote-flash.sh -nvme user@remote-pc /dev/nvme0n1
#   ./scripts/remote-flash.sh -y -sdcard user@remote-pc /dev/sdX
#
# Options:
#   -y          Skip all confirmation prompts
#
# After flashing, you are always prompted (hidden input, shown locally over the
# ssh -t session) for a Tailscale auth key which is written to the remote
# device's boot partition. Press Enter with no input to skip. The key is never
# passed as a command-line argument.
#
# The -sdcard or -nvme flag is required to select the correct image.
#
# What it does:
#   1. scp image (.wic.bz2 + .bmap) and flash.sh to remote:/tmp/kart-flash/
#   2. ssh into remote and run flash.sh with sudo
#   3. Clean up remote temp files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_DIR="${PROJECT_DIR}/build/tmp/deploy/images/raspberrypi5"

# --- Parse arguments ---
usage() {
    echo "Usage: $0 [-y] <-sdcard|-nvme> <user@remote-host> <device>"
    echo ""
    echo "Options:"
    echo "  -y          Skip all confirmation prompts"
    echo ""
    echo "After flashing, prompts for a Tailscale auth key (Enter to skip)."
    echo ""
    echo "Examples:"
    echo "  $0 -sdcard user@192.168.0.10 /dev/sdb"
    echo "  $0 -sdcard user@laptop /dev/mmcblk0"
    echo "  $0 -nvme user@laptop /dev/nvme0n1"
    echo "  $0 -y -sdcard user@laptop /dev/sdb"
    exit 1
}

AUTO_YES=false
if [ "${1:-}" = "-y" ]; then
    AUTO_YES=true
    shift
fi

if [ $# -lt 3 ]; then
    usage
fi

case "$1" in
    -sdcard) IMAGE_TYPE="sdcard" ;;
    -nvme)   IMAGE_TYPE="nvme" ;;
    *)       echo "ERROR: First argument must be -sdcard or -nvme (got '$1')"; echo ""; usage ;;
esac

SSH_HOST="$2"
DEVICE="$3"

# --- Find image ---
IMAGE_PATH=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5-${IMAGE_TYPE}.wic.bz2" 2>/dev/null | head -1)
if [ -z "$IMAGE_PATH" ]; then
    echo "ERROR: No ${IMAGE_TYPE} image found in $IMAGE_DIR"
    echo "       Expected: kart-image-raspberrypi5-${IMAGE_TYPE}.wic.bz2"
    if [ "$IMAGE_TYPE" = "sdcard" ]; then
        echo "       Build: kas-container build kas/local-dev.yml:kas/boot-sdcard.yml"
    else
        echo "       Build: kas-container build kas/rpi5-prod.yml"
    fi
    exit 1
fi

if [ ! -f "$IMAGE_PATH" ]; then
    echo "ERROR: Image not found: $IMAGE_PATH"
    exit 1
fi

# Find matching .bmap file
BMAP_PATH="${IMAGE_PATH%.bz2}.bmap"
if [ ! -f "$BMAP_PATH" ]; then
    BMAP_PATH=""
fi

FLASH_SCRIPT="${SCRIPT_DIR}/flash.sh"
if [ ! -f "$FLASH_SCRIPT" ]; then
    echo "ERROR: flash.sh not found at $FLASH_SCRIPT"
    exit 1
fi

IMAGE_NAME=$(basename "$IMAGE_PATH")
IMAGE_SIZE=$(du -h "$IMAGE_PATH" | cut -f1)

echo "==> Deploy target: ${SSH_HOST}"
echo "==> Image type: ${IMAGE_TYPE}"
echo "==> Device: ${DEVICE}"
echo "==> Image: ${IMAGE_NAME} (${IMAGE_SIZE})"
[ -n "$BMAP_PATH" ] && echo "==> Bmap: $(basename "$BMAP_PATH")"
echo ""

# --- Check remote prerequisites ---
echo "==> Checking remote prerequisites on ${SSH_HOST}..."
MISSING=""
for cmd in dd sudo wipefs lsblk findmnt; do
    if ! ssh "$SSH_HOST" "command -v $cmd" &>/dev/null; then
        MISSING="$MISSING $cmd"
    fi
done
# bzcat is needed to decompress .wic.bz2
if ! ssh "$SSH_HOST" "command -v bzcat" &>/dev/null; then
    MISSING="$MISSING bzcat(bzip2)"
fi
if [ -n "$MISSING" ]; then
    echo "ERROR: Required commands not found on ${SSH_HOST}:${MISSING}"
    exit 1
fi
# Check if target device exists
if ! ssh "$SSH_HOST" "test -b '${DEVICE}'" 2>/dev/null; then
    echo "ERROR: Device ${DEVICE} not found on ${SSH_HOST}"
    echo "       Check: ssh ${SSH_HOST} lsblk"
    exit 1
fi
# bmaptool is optional but recommended
if [ -n "$BMAP_PATH" ] && ! ssh "$SSH_HOST" "command -v bmaptool" &>/dev/null; then
    echo "    Note: bmaptool not found on remote, will use dd (slower)"
fi
echo "==> Remote prerequisites OK"
echo ""

# --- Transfer files ---
REMOTE_DIR="/tmp/kart-flash"

echo "==> Creating remote directory ${REMOTE_DIR}..."
ssh "$SSH_HOST" "mkdir -p ${REMOTE_DIR}"

echo "==> Copying image to ${SSH_HOST}:${REMOTE_DIR}/..."
scp "$IMAGE_PATH" "${SSH_HOST}:${REMOTE_DIR}/"

if [ -n "$BMAP_PATH" ]; then
    echo "==> Copying bmap..."
    scp "$BMAP_PATH" "${SSH_HOST}:${REMOTE_DIR}/"
fi

echo "==> Copying flash.sh..."
scp "$FLASH_SCRIPT" "${SSH_HOST}:${REMOTE_DIR}/"
ssh "$SSH_HOST" "chmod +x ${REMOTE_DIR}/flash.sh"

# --- Flash on remote ---
echo ""
echo "==> Running flash on ${SSH_HOST}..."
if [ "$AUTO_YES" = true ]; then
    ssh -t "$SSH_HOST" "cd ${REMOTE_DIR} && IMAGE_DIR=${REMOTE_DIR} sudo -E ./flash.sh -y -${IMAGE_TYPE} '${DEVICE}'"
else
    ssh -t "$SSH_HOST" "cd ${REMOTE_DIR} && IMAGE_DIR=${REMOTE_DIR} sudo -E ./flash.sh -${IMAGE_TYPE} '${DEVICE}'"
fi

# --- Cleanup ---
echo ""
if [ "$AUTO_YES" = true ]; then
    ssh "$SSH_HOST" "rm -rf ${REMOTE_DIR}"
    echo "==> Remote files cleaned up."
else
    read -rp "==> Clean up remote files in ${REMOTE_DIR}? [Y/n] " cleanup
    if [[ ! "$cleanup" =~ ^[Nn]$ ]]; then
        ssh "$SSH_HOST" "rm -rf ${REMOTE_DIR}"
        echo "==> Remote files cleaned up."
    fi
fi

echo "==> Done!"
