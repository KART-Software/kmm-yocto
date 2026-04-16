#!/bin/bash
# flash-sdcard.sh — Write kart-image to SD card
#
# Usage:
#   sudo ./scripts/flash-sdcard.sh /dev/sdX
#   sudo ./scripts/flash-sdcard.sh /dev/sdX [image-path]
#
# By default, looks for the latest built .wic.bz2 image.

set -euo pipefail

DEVICE="${1:-}"
IMAGE_DIR="build/tmp/deploy/images/raspberrypi5"
IMAGE_PATH="${2:-}"

if [ -z "$DEVICE" ]; then
    echo "Usage: $0 <device> [image-path]"
    echo "  e.g.: sudo $0 /dev/sdb"
    echo "  e.g.: sudo $0 /dev/mmcblk0"
    exit 1
fi

# Safety check — allow /dev/sdX and /dev/mmcblkN
if ! [[ "$DEVICE" =~ ^/dev/sd[a-z]+$ ]] && ! [[ "$DEVICE" =~ ^/dev/mmcblk[0-9]+$ ]]; then
    echo "ERROR: '$DEVICE' does not look like a valid SD card device."
    echo "       Expected /dev/sdX or /dev/mmcblkN"
    exit 1
fi

# Prevent accidental write to system disk
if [ "$DEVICE" = "/dev/sda" ]; then
    echo "ERROR: Refusing to write to /dev/sda (likely system disk)."
    exit 1
fi

# Find image if not specified
if [ -z "$IMAGE_PATH" ]; then
    WIC_FILE=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5.wic.bz2" -type f 2>/dev/null | head -1)
    BMAP_FILE=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5.wic.bmap" -type f 2>/dev/null | head -1)

    if [ -z "$WIC_FILE" ]; then
        echo "ERROR: No .wic.bz2 image found in $IMAGE_DIR"
        echo "       Build first: kas-container build kas/local-dev.yml:kas/boot-sdcard.yml"
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
if [[ "$DEVICE" =~ ^/dev/mmcblk ]]; then
    # mmcblk partitions use p1, p2 format
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
echo "  1. Insert SD card into RPi5 and power on."
echo "  2. Default login: root (no password) or kart user."
echo "  3. Connect via serial console or SSH (if NetworkManager connects)."
