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
#   -y                    Skip confirmation prompt
#   --authkey-file <path> Read the Tailscale auth key from <path> (no prompt)
#   --no-authkey          Do not inject an auth key (skip the prompt)
#   --keep-data           Preserve the existing data partition (LABEL=data)
#                         across the flash. Keeps /data/tailscale state, so the
#                         device stays the SAME tailnet node (no ghost nodes,
#                         no new auth key needed) and /data/log survives.
#
# After flashing, a Tailscale auth key is written to the boot partition for
# first-boot auto-connect. By default you are prompted (hidden input; Enter to
# skip); use --authkey-file to read it from a file, or --no-authkey to skip.
# The key can also be supplied via the TS_AUTHKEY env var.
#
# The -sdcard or -nvme flag is required to select the correct image.

set -euo pipefail

usage() {
    echo "Usage: $0 [-y] <-sdcard|-nvme> <device>"
    echo ""
    echo "Options:"
    echo "  -y                    Skip confirmation prompt"
    echo "  --authkey-file <path> Read the Tailscale auth key from a file (no prompt)"
    echo "  --no-authkey          Skip Tailscale auth key injection (no prompt)"
    echo "  --keep-data           Preserve the data partition (tailscale identity/logs)"
    echo ""
    echo "Auth key: default prompts (Enter to skip); --authkey-file reads a file;"
    echo "          --no-authkey skips entirely."
    echo ""
    echo "Examples:"
    echo "  sudo $0 -sdcard /dev/sdb"
    echo "  sudo $0 --authkey-file key.txt -nvme /dev/nvme0n1"
    echo "  sudo $0 --no-authkey -nvme /dev/nvme0n1"
    exit 1
}

# Read a line from the terminal, echoing '*' for each character so the user can
# see that input is being received (backspace supported). The prompt and mask
# are written to stderr; the typed value is written to stdout (for $(...) capture).
read_masked() {
    local prompt="$1" char value=""
    printf '%s' "$prompt" >&2
    while IFS= read -rsn1 char; do
        case "$char" in
            "")                 # Enter -> end of input
                break ;;
            $'\x7f'|$'\x08')    # Backspace / Delete
                if [ -n "$value" ]; then
                    value="${value%?}"
                    printf '\b \b' >&2
                fi ;;
            *)
                value="$value$char"
                printf '*' >&2 ;;
        esac
    done
    printf '\n' >&2
    printf '%s' "$value"
}

# Read a Tailscale auth key without exposing it on the command line.
# Priority: --authkey-file > $TS_AUTHKEY env > masked interactive prompt > stdin.
get_authkey() {
    if [ -n "${AUTHKEY_FILE:-}" ]; then
        if [ ! -f "$AUTHKEY_FILE" ]; then
            echo "ERROR: auth key file not found: $AUTHKEY_FILE" >&2
            exit 1
        fi
        cat "$AUTHKEY_FILE"
        return 0
    fi
    if [ -n "${TS_AUTHKEY:-}" ]; then
        printf '%s' "$TS_AUTHKEY"
        return 0
    fi
    local key=""
    if [ -t 0 ]; then
        key=$(read_masked "Tailscale auth key (empty to skip): ")
    else
        IFS= read -r key || true
    fi
    printf '%s' "$key"
}

# Write the auth key to the active slot's boot partition (label=BOOTA) of the
# flashed device. autoboot.txt ships with boot_partition=2, so a freshly
# flashed card always boots slot A; kart-boot-mount.service then mounts BOOTA
# on /boot, where tailscale-autoconnect.sh looks for the key.
inject_tailscale_key() {
    local device="$1"
    local key bootname bootpart mnt own=false

    key=$(get_authkey)
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    if [ -z "$key" ]; then
        echo "==> No auth key entered; skipping Tailscale injection."
        return 0
    fi

    # Wait for the freshly-written partition table / 'BOOTA' label to appear.
    bootname=""
    for _ in 1 2 3 4 5; do
        bootname=$(lsblk -rno NAME,LABEL "$device" 2>/dev/null | awk '$2=="BOOTA"{print $1; exit}')
        [ -n "$bootname" ] && break
        partprobe "$device" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        sleep 1
    done
    if [ -z "$bootname" ]; then
        echo "WARN: no 'BOOTA' partition found on $device; auth key NOT written." >&2
        echo "      The device will boot but will NOT join the tailnet." >&2
        echo "      Fix by mounting the BOOTA partition and writing the key to" >&2
        echo "      tailscale.authkey on it, then reboot the device." >&2
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
AUTHKEY_FILE=""
NO_AUTHKEY=false
KEEP_DATA=false
while [ $# -gt 0 ]; do
    case "$1" in
        -y)               AUTO_YES=true ;;
        --authkey-file)   AUTHKEY_FILE="${2:-}"; [ -n "$AUTHKEY_FILE" ] || { echo "ERROR: --authkey-file requires a path"; echo ""; usage; }; shift ;;
        --authkey-file=*) AUTHKEY_FILE="${1#*=}" ;;
        --no-authkey)     NO_AUTHKEY=true ;;
        --keep-data)      KEEP_DATA=true ;;
        -sdcard)          IMAGE_TYPE="sdcard" ;;
        -nvme)            IMAGE_TYPE="nvme" ;;
        -h|--help)        usage ;;
        -*)               echo "ERROR: unknown option: $1"; echo ""; usage ;;
        *)                if [ -z "$DEVICE" ]; then DEVICE="$1"; else echo "ERROR: unexpected argument: $1"; echo ""; usage; fi ;;
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

# --keep-data: back up the data partition (LABEL=data) before it is destroyed
DATA_BACKUP=""
if [ "$KEEP_DATA" = true ]; then
    dataname=$(lsblk -rno NAME,LABEL "$DEVICE" 2>/dev/null | awk '$2=="data"{print $1; exit}')
    if [ -n "$dataname" ]; then
        DATA_BACKUP=$(mktemp /tmp/kart-data-backup.XXXXXX)
        trap '[ -n "$DATA_BACKUP" ] && rm -f "$DATA_BACKUP"' EXIT
        echo "==> Backing up data partition /dev/$dataname ($(lsblk -rno SIZE "/dev/$dataname" 2>/dev/null | head -1))..."
        dd if="/dev/$dataname" of="$DATA_BACKUP" bs=4M status=none conv=fsync
    else
        echo "WARN: --keep-data specified but no 'data' partition found on $DEVICE; continuing without backup." >&2
    fi
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

# --keep-data: restore the backed-up data partition onto the fresh layout
DATA_RESTORED=false
if [ -n "$DATA_BACKUP" ] && [ -s "$DATA_BACKUP" ]; then
    echo ""
    echo "==> Restoring data partition..."
    dataname=""
    for _ in 1 2 3 4 5; do
        dataname=$(lsblk -rno NAME,LABEL "$DEVICE" 2>/dev/null | awk '$2=="data"{print $1; exit}')
        [ -n "$dataname" ] && break
        partprobe "$DEVICE" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        sleep 1
    done
    if [ -z "$dataname" ]; then
        echo "WARN: no 'data' partition in new layout; backup NOT restored." >&2
    else
        newsize=$(blockdev --getsize64 "/dev/$dataname" 2>/dev/null || echo 0)
        oldsize=$(stat -c %s "$DATA_BACKUP")
        if [ "$newsize" = "$oldsize" ]; then
            dd if="$DATA_BACKUP" of="/dev/$dataname" bs=4M status=none conv=fsync
            sync
            e2fsck -p "/dev/$dataname" >/dev/null 2>&1 || true
            DATA_RESTORED=true
            echo "==> Data partition restored (tailscale identity and /data/log preserved)."
        else
            echo "WARN: data partition size changed (old=$oldsize new=$newsize); backup NOT restored." >&2
        fi
    fi
fi

# Inject a Tailscale auth key onto the boot partition for first-boot auto-connect.
# Default: prompt (Enter to skip). --authkey-file: from file. --no-authkey: skip.
if [ "$NO_AUTHKEY" = true ]; then
    echo ""
    echo "==> Skipping Tailscale auth key injection (--no-authkey)."
else
    echo ""
    if [ "$DATA_RESTORED" = true ]; then
        echo "    (data partition preserved: tailscale state carried over, auth key usually NOT needed — press Enter to skip)"
    fi
    inject_tailscale_key "$DEVICE"
fi

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
