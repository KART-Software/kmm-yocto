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
# After flashing, you are always prompted (hidden input) for a Tailscale auth
# key which is written to the boot partition for first-boot auto-connect.
# Press Enter with no input to skip. The key can also be supplied via the
# TS_AUTHKEY env var.
#
# The -sdcard or -nvme flag is required to select the correct image.

set -euo pipefail

usage() {
    echo "Usage: $0 [-y] <-sdcard|-nvme> <device>"
    echo ""
    echo "Options:"
    echo "  -y          Skip confirmation prompt"
    echo ""
    echo "After flashing, prompts for a Tailscale auth key (Enter to skip)."
    echo ""
    echo "Examples:"
    echo "  sudo $0 -sdcard /dev/sdb"
    echo "  sudo $0 -sdcard /dev/mmcblk0"
    echo "  sudo $0 -nvme /dev/nvme0n1"
    echo "  sudo $0 -y -sdcard /dev/sdb"
    exit 1
}

# Read a Tailscale auth key without exposing it on the command line.
# Priority: $TS_AUTHKEY env > hidden interactive prompt (tty) > piped stdin.
get_authkey() {
    if [ -n "${TS_AUTHKEY:-}" ]; then
        printf '%s' "$TS_AUTHKEY"
        return 0
    fi
    local key=""
    if [ -t 0 ]; then
        read -rsp "Tailscale auth key (empty to skip): " key
        echo >&2
    else
        IFS= read -r key || true
    fi
    printf '%s' "$key"
}

# Write the auth key to the boot partition (label=boot) of the flashed device.
inject_tailscale_key() {
    local device="$1"
    local key bootname bootpart mnt own=false

    key=$(get_authkey)
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    if [ -z "$key" ]; then
        echo "==> No auth key entered; skipping Tailscale injection."
        return 0
    fi

    # Wait for the freshly-written partition table / 'boot' label to appear.
    bootname=""
    for _ in 1 2 3 4 5; do
        bootname=$(lsblk -rno NAME,LABEL "$device" 2>/dev/null | awk '$2=="boot"{print $1; exit}')
        [ -n "$bootname" ] && break
        partprobe "$device" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        sleep 1
    done
    if [ -z "$bootname" ]; then
        echo "WARN: no 'boot' partition found on $device; auth key NOT written." >&2
        return 0
    fi
    bootpart="/dev/$bootname"

    mnt=$(findmnt -nro TARGET "$bootpart" 2>/dev/null | head -1 || true)
    if [ -z "$mnt" ]; then
        mnt=$(mktemp -d); own=true
        mount "$bootpart" "$mnt"
    fi
    printf '%s\n' "$key" > "$mnt/tailscale.authkey"
    sync
    if [ "$own" = true ]; then
        umount "$mnt" 2>/dev/null || true
        rmdir "$mnt" 2>/dev/null || true
    fi
    echo "==> Tailscale auth key written to $bootpart (first boot connects, then deletes it)."
}

AUTO_YES=false
IMAGE_TYPE=""
DEVICE=""
while [ $# -gt 0 ]; do
    case "$1" in
        -y)          AUTO_YES=true ;;
        -sdcard)     IMAGE_TYPE="sdcard" ;;
        -nvme)       IMAGE_TYPE="nvme" ;;
        -h|--help)   usage ;;
        -*)          echo "ERROR: unknown option: $1"; echo ""; usage ;;
        *)           if [ -z "$DEVICE" ]; then DEVICE="$1"; else echo "ERROR: unexpected argument: $1"; echo ""; usage; fi ;;
    esac
    shift
done

if [ -z "$IMAGE_TYPE" ] || [ -z "$DEVICE" ]; then
    usage
fi
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

# Always prompt for a Tailscale auth key (Enter to skip) and write it to the
# boot partition for first-boot auto-connect.
echo ""
inject_tailscale_key "$DEVICE"

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
