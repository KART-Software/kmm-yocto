#!/bin/bash
# flash-nvme.sh — Write kart-image to NVMe SSD
#
# Usage:
#   sudo ./scripts/flash-nvme.sh /dev/nvme0n1
#   sudo ./scripts/flash-nvme.sh /dev/nvme0n1 [image-path]
#
# By default, looks for the latest built .wic.bz2 image.

set -euo pipefail

DEVICE="${1:-}"
IMAGE_DIR="build/tmp/deploy/images/raspberrypi5"
IMAGE_PATH="${2:-}"

if [ -z "$DEVICE" ]; then
    echo "Usage: $0 <device> [image-path]"
    echo "  e.g.: sudo $0 /dev/nvme0n1"
    exit 1
fi

# Safety check
if ! [[ "$DEVICE" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]] && ! [[ "$DEVICE" =~ ^/dev/sd[a-z]+$ ]]; then
    echo "ERROR: '$DEVICE' does not look like a valid block device."
    exit 1
fi

# Find image if not specified
if [ -z "$IMAGE_PATH" ]; then
    WIC_FILE=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5.wic.bz2" -type f 2>/dev/null | head -1)
    BMAP_FILE=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5.wic.bmap" -type f 2>/dev/null | head -1)

    if [ -z "$WIC_FILE" ]; then
        echo "ERROR: No .wic.bz2 image found in $IMAGE_DIR"
        echo "       Build first: kas-container build kas/rpi5-prod.yml"
        exit 1
    fi
    IMAGE_PATH="$WIC_FILE"
fi

echo "==> Target device: $DEVICE"
echo "==> Image: $IMAGE_PATH"
echo ""
echo "WARNING: All data on $DEVICE will be destroyed!"
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Unmount any existing partitions
echo "==> Unmounting existing partitions on $DEVICE..."
for part in "${DEVICE}"p*; do
    if mountpoint -q "$part" 2>/dev/null || mount | grep -q "$part"; then
        umount "$part" 2>/dev/null || true
    fi
done

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
echo ""
echo "Next steps:"
echo "  1. Ensure RPi5 EEPROM is configured for NVMe boot:"
echo "     sudo rpi-eeprom-config --edit"
echo "     Set: BOOT_ORDER=0xf416"
echo "  2. Insert NVMe into RPi5 M.2 HAT and power on."
