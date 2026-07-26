#!/bin/bash
# ota-update.sh — A/B (tryboot) OTA update over SSH, no SSD removal needed.
#
# Usage:
#   ./scripts/ota-update.sh --host <ssh-host> [image.wic.bz2]
#
#   --host <host>   SSH destination (tailscale name/IP or LAN IP; root login)
#   [image]         wic.bz2 to deploy (default: latest built nvme image)
#
# What it does (each step is printed; nothing is silent):
#   1. Extract boot-FAT and rootfs-ext4 partition images from the local wic
#   2. Query the device's active slot (kart-ab-status)
#   3. Write the INACTIVE slot over SSH:
#        - rootfs: dd (then relabel roota/rootb + fresh UUID)
#        - boot:   file-level copy into the slot's FAT (keeps BOOTA/BOOTB label)
#        - fix root= in the slot's cmdline.txt
#   4. reboot '0 tryboot'  -> firmware boots the new slot ONCE
#   5. Wait for the device, verify it came up on the NEW slot, show health
#   6. Ask for confirmation, then kart-ab-commit (make it permanent)
#      - If the new slot fails to boot, the firmware falls back automatically;
#        just re-run after fixing the image. Nothing to clean up.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE_DIR="${PROJECT_DIR}/build/tmp/deploy/images/raspberrypi5"

HOST=""
IMAGE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --host)   HOST="${2:-}"; shift 2 ;;
        --host=*) HOST="${1#*=}"; shift ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \?//'; exit 0 ;;
        -*) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
        *)  IMAGE="$1"; shift ;;
    esac
done
[ -n "$HOST" ] || { echo "ERROR: --host is required" >&2; exit 1; }

IMAGE="${IMAGE:-$(readlink -f "$IMAGE_DIR/kart-image-raspberrypi5-nvme.wic.bz2")}"
[ -f "$IMAGE" ] || { echo "ERROR: image not found: $IMAGE" >&2; exit 1; }

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@$HOST")

WORK=$(mktemp -d /tmp/kart-ota.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "==> [1/6] Extracting partitions from $(basename "$IMAGE")..."
bunzip2 -kc "$IMAGE" > "$WORK/image.wic"
# p2 = BOOTA (FAT), p5 = roota (ext4) in the A/B layout
mapfile -t PARTS < <(fdisk -l "$WORK/image.wic" | awk '/^\/|wic[0-9]/ {print $0}')
BOOT_START=$(fdisk -l "$WORK/image.wic" | awk '/wic2/{print $2}')
BOOT_SECTORS=$(fdisk -l "$WORK/image.wic" | awk '/wic2/{print $4}')
ROOT_START=$(fdisk -l "$WORK/image.wic" | awk '/wic5/{print $2}')
ROOT_SECTORS=$(fdisk -l "$WORK/image.wic" | awk '/wic5/{print $4}')
[ -n "$BOOT_START" ] && [ -n "$ROOT_START" ] || { echo "ERROR: image is not an A/B layout (wic2/wic5 not found)" >&2; exit 1; }
dd if="$WORK/image.wic" of="$WORK/boot.img" bs=512 skip="$BOOT_START" count="$BOOT_SECTORS" status=none
dd if="$WORK/image.wic" of="$WORK/root.img" bs=512 skip="$ROOT_START" count="$ROOT_SECTORS" status=none
rm -f "$WORK/image.wic"
echo "    boot.img: $(du -h "$WORK/boot.img" | cut -f1), root.img: $(du -h "$WORK/root.img" | cut -f1)"

echo "==> [2/6] Querying device slot state..."
STATUS=$("${SSH[@]}" kart-ab-status)
echo "$STATUS" | grep -E "ACTIVE_SLOT|INACTIVE_SLOT"
ACTIVE=$(echo "$STATUS"      | sed -n 's/^ACTIVE_SLOT=//p')
IN_SLOT=$(echo "$STATUS"     | sed -n 's/^INACTIVE_SLOT=//p')
IN_BOOT=$(echo "$STATUS"     | sed -n 's/^INACTIVE_BOOT_PART=//p')
IN_ROOT=$(echo "$STATUS"     | sed -n 's/^INACTIVE_ROOT_PART=//p')
BASE=$(echo "$STATUS"        | sed -n 's/^BASE_DEV=//p')
[ -n "$IN_BOOT" ] && [ -n "$IN_ROOT" ] && [ -n "$BASE" ] || { echo "ERROR: could not parse kart-ab-status" >&2; exit 1; }
IN_LABEL=$([ "$IN_SLOT" = "A" ] && echo BOOTA || echo BOOTB)
IN_RLABEL=$([ "$IN_SLOT" = "A" ] && echo roota || echo rootb)

echo "==> [3/6] Writing INACTIVE slot $IN_SLOT (${BASE}p${IN_BOOT} + ${BASE}p${IN_ROOT})..."
# Relabel + fresh UUID on the HOST before transfer (the device has no
# e2fsprogs). Prevents roota/rootb label and UUID duplication between slots.
echo "    prepare rootfs image: label=${IN_RLABEL}, new UUID..."
e2label "$WORK/root.img" "$IN_RLABEL"
tune2fs -U random "$WORK/root.img" >/dev/null 2>&1 || true
echo "    rootfs -> ${BASE}p${IN_ROOT} (dd over ssh)..."
gzip -c "$WORK/root.img" | "${SSH[@]}" "gzip -dc | dd of=${BASE}p${IN_ROOT} bs=4M conv=fsync status=none && sync"
echo "    boot files -> ${BASE}p${IN_BOOT} (file copy, label preserved)..."
gzip -c "$WORK/boot.img" | "${SSH[@]}" "
set -e
gzip -dc > /tmp/ota-boot.img
mkdir -p /tmp/ota-src /tmp/ota-dst
mount -o loop,ro /tmp/ota-boot.img /tmp/ota-src
mount ${BASE}p${IN_BOOT} /tmp/ota-dst
rm -rf /tmp/ota-dst/*
cp -r /tmp/ota-src/. /tmp/ota-dst/
sed -i 's|root=/dev/[a-z0-9]*p[56]|root=${BASE}p${IN_ROOT}|' /tmp/ota-dst/cmdline.txt
echo '    cmdline:' \$(cat /tmp/ota-dst/cmdline.txt)
sync
umount /tmp/ota-src /tmp/ota-dst
rm -f /tmp/ota-boot.img
"

echo "==> [4/6] Rebooting into slot $IN_SLOT via tryboot (one-shot)..."
"${SSH[@]}" "reboot '0 tryboot'" || true

echo "==> [5/6] Waiting for the device to come back..."
sleep 15
n=0
until "${SSH[@]}" true 2>/dev/null; do
    n=$((n+1)); [ $n -ge 60 ] && { echo "TIMEOUT: device did not come back; if it fell back to slot $ACTIVE, re-run after investigating." >&2; exit 1; }
    sleep 3
done
NEW_STATUS=$("${SSH[@]}" kart-ab-status)
NEW_ACTIVE=$(echo "$NEW_STATUS" | sed -n 's/^ACTIVE_SLOT=//p')
echo "    came back on slot: $NEW_ACTIVE (expected: $IN_SLOT)"
if [ "$NEW_ACTIVE" != "$IN_SLOT" ]; then
    echo "!!! Device fell back to slot $NEW_ACTIVE — the new slot failed to boot. Nothing was committed." >&2
    exit 1
fi
echo "    health:"
"${SSH[@]}" 'systemctl is-active weston kmmd can0-up 2>/dev/null | tr "\n" " "; echo; systemctl --failed --no-legend | wc -l | xargs echo "    failed units:"'

echo "==> [6/6] Commit?"
read -rp "    Make slot $IN_SLOT permanent? [y/N] " ok
if [[ "$ok" =~ ^[Yy]$ ]]; then
    "${SSH[@]}" kart-ab-commit
    echo "==> OTA complete: slot $IN_SLOT is now the boot slot."
else
    echo "==> NOT committed. Next reboot returns to slot $ACTIVE."
fi
