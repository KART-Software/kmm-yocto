#!/bin/bash
# remote-flash.sh — Copy image + flash tool to remote PC, then flash
#
# Usage:
#   ./scripts/remote-flash.sh user@remote-pc /dev/sdX
#   ./scripts/remote-flash.sh user@remote-pc /dev/mmcblk0
#   ./scripts/remote-flash.sh user@remote-pc /dev/nvme0n1
#   ./scripts/remote-flash.sh user@remote-pc /dev/sdX path/to/image.wic.bz2
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
if [ $# -lt 2 ]; then
    echo "Usage: $0 <user@remote-host> <device> [image-path]"
    echo ""
    echo "Examples:"
    echo "  $0 user@192.168.0.10 /dev/sdb"
    echo "  $0 user@laptop /dev/mmcblk0"
    echo "  $0 user@laptop /dev/nvme0n1"
    echo "  $0 user@laptop /dev/sdb path/to/kart-image.wic.bz2"
    exit 1
fi

SSH_HOST="$1"
DEVICE="$2"
IMAGE_PATH="${3:-}"

# --- Find image ---
if [ -z "$IMAGE_PATH" ]; then
    IMAGE_PATH=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5*.wic.bz2" -type f 2>/dev/null | sort | tail -1)
    if [ -z "$IMAGE_PATH" ]; then
        echo "ERROR: No .wic.bz2 image found in $IMAGE_DIR"
        echo "       Build first: kas-container build kas/local-dev.yml:kas/boot-sdcard.yml"
        exit 1
    fi
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
echo "==> SD card device: ${DEVICE}"
echo "==> Image: ${IMAGE_NAME} (${IMAGE_SIZE})"
[ -n "$BMAP_PATH" ] && echo "==> Bmap: $(basename "$BMAP_PATH")"
echo ""

# --- Check remote prerequisites ---
echo "==> Checking remote prerequisites on ${SSH_HOST}..."
MISSING=""
for cmd in dd sudo wipefs; do
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
ssh -t "$SSH_HOST" "cd ${REMOTE_DIR} && sudo ./flash.sh '${DEVICE}' '${REMOTE_DIR}/${IMAGE_NAME}'"

# --- Cleanup ---
echo ""
read -rp "==> Clean up remote files in ${REMOTE_DIR}? [Y/n] " cleanup
if [[ ! "$cleanup" =~ ^[Nn]$ ]]; then
    ssh "$SSH_HOST" "rm -rf ${REMOTE_DIR}"
    echo "==> Remote files cleaned up."
fi

echo "==> Done!"
