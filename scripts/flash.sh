#!/bin/bash
# flash.sh — Write kart-image to SD card or NVMe SSD
#
# Usage:
#   sudo ./scripts/flash.sh -sdcard /dev/sdX
#   sudo ./scripts/flash.sh -sdcard /dev/mmcblk0
#   sudo ./scripts/flash.sh -nvme /dev/nvme0n1
#   sudo ./scripts/flash.sh -y -sdcard /dev/sdX
#
# Options:
#   -y          Skip confirmation prompt
#
# The -sdcard or -nvme flag is required to select the correct image.

set -euo pipefail

usage() {
    echo "Usage: $0 [-y] <-sdcard|-nvme> <device>"
    echo ""
    echo "Options:"
    echo "  -y          Skip confirmation prompt"
    echo ""
    echo "Examples:"
    echo "  sudo $0 -sdcard /dev/sdb"
    echo "  sudo $0 -sdcard /dev/mmcblk0"
    echo "  sudo $0 -nvme /dev/nvme0n1"
    echo "  sudo $0 -y -sdcard /dev/sdb"
    exit 1
}

AUTO_YES=false
if [ "${1:-}" = "-y" ]; then
    AUTO_YES=true
    shift
fi

if [ $# -lt 2 ]; then
    usage
fi

case "$1" in
    -sdcard) IMAGE_TYPE="sdcard" ;;
    -nvme)   IMAGE_TYPE="nvme" ;;
    *)       echo "ERROR: First argument must be -sdcard or -nvme (got '$1')"; echo ""; usage ;;
esac

DEVICE="$2"
IMAGE_DIR="${IMAGE_DIR:-build/tmp/deploy/images/raspberrypi5}"

# Safety check — allow /dev/sdX, /dev/mmcblkN, /dev/nvmeXnY
if ! [[ "$DEVICE" =~ ^/dev/sd[a-z]+$ ]] && \
   ! [[ "$DEVICE" =~ ^/dev/mmcblk[0-9]+$ ]] && \
   ! [[ "$DEVICE" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
    echo "ERROR: '$DEVICE' does not look like a valid block device."
    echo "       Expected /dev/sdX, /dev/mmcblkN, or /dev/nvmeXnY"
    exit 1
fi

# Find image by type
WIC_FILE=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5-${IMAGE_TYPE}.wic.bz2" 2>/dev/null | head -1)
BMAP_FILE=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5-${IMAGE_TYPE}.wic.bmap" 2>/dev/null | head -1)

if [ -z "$WIC_FILE" ]; then
    echo "ERROR: No ${IMAGE_TYPE} image found in $IMAGE_DIR"
    echo "       Expected: kart-image-raspberrypi5-${IMAGE_TYPE}.wic.bz2"
    if [ "$IMAGE_TYPE" = "sdcard" ]; then
        echo "       Build: kas-container build kas/local-dev.yml:kas/boot-sdcard.yml"
    else
        echo "       Build: kas-container build kas/rpi5-prod.yml"
    fi
    exit 1
fi
IMAGE_PATH="$WIC_FILE"

echo "==> Target device: $DEVICE"
echo "==> Image type: $IMAGE_TYPE"
echo "==> Image: $IMAGE_PATH"
echo ""
echo "WARNING: All data on $DEVICE will be destroyed!"
if [ "$AUTO_YES" = false ]; then
    read -rp "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# Unmount any existing partitions
echo "==> Unmounting existing partitions on $DEVICE..."
if [[ "$DEVICE" =~ ^/dev/(mmcblk|nvme) ]]; then
    # mmcblk/nvme partitions use p1, p2 format
    for part in "${DEVICE}"p*; do
        if mount | grep -q "$part"; then
            umount "$part" 2>/dev/null || true
        fi
    done
else
    # sd devices use 1, 2 format
    for part in "${DEVICE}"[0-9]*; do
        if mount | grep -q "$part"; then
            umount "$part" 2>/dev/null || true
        fi
    done
fi

# Wipe existing filesystem signatures and partition table
echo "==> Wiping existing signatures on $DEVICE..."
wipefs --all --force "$DEVICE" 2>/dev/null || true
dd if=/dev/zero of="$DEVICE" bs=1M count=16 status=none conv=fsync 2>/dev/null || true

# Use bmaptool if available and bmap file exists, otherwise dd
if command -v bmaptool &>/dev/null && [ -n "${BMAP_FILE:-}" ] && [ -f "${BMAP_FILE:-}" ]; then
    echo "==> Flashing with bmaptool (fast)..."
    bmaptool copy "$IMAGE_PATH" "$DEVICE"
else
    echo "==> Flashing with dd (this may take a while)..."
    if [[ "$IMAGE_PATH" == *.bz2 ]]; then
        bzcat "$IMAGE_PATH" | dd of="$DEVICE" bs=4M status=progress conv=fsync
    else
        dd if="$IMAGE_PATH" of="$DEVICE" bs=4M status=progress conv=fsync
    fi
fi

sync
echo ""
echo "==> Done! Image written to $DEVICE"

# Show device-specific next steps
if [[ "$DEVICE" =~ ^/dev/nvme ]]; then
    echo ""
    echo "Next steps:"
    echo "  1. Ensure RPi5 EEPROM is configured for NVMe boot:"
    echo "     sudo rpi-eeprom-config --edit"
    echo "     Set: BOOT_ORDER=0xf416"
    echo "  2. Insert NVMe into RPi5 M.2 HAT and power on."
else
    echo ""
    echo "Next steps:"
    echo "  1. Insert SD card into RPi5 and power on."
fi
echo "  Default login: root (no password) or kart user."
