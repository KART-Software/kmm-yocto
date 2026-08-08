#!/bin/bash
# ota-update.sh — A/B OTA update over SSH, no storage removal needed.
#
# Platforms (自動判別: イメージのパーティション構成 + デバイスの kart-ab-status):
#   RPi5  : firmware tryboot (reboot '0 tryboot', 失敗時はファームが自動復帰)
#   i.MX  : U-Boot bootcount (upgrade_available=1 で試行、失敗時は altbootcmd が
#           旧スロットへ復帰。電源断でも旧スロットに戻る)
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

# Standalone-friendly: no Yocto/build environment and no local sudo needed.
# Only these standard tools (e2label/tune2fs come from e2fsprogs):
MISSING=""
for cmd in bunzip2 fdisk gzip e2label tune2fs ssh; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING="$MISSING $cmd"
done
if [ -n "$MISSING" ]; then
    echo "ERROR: required tools not found:$MISSING" >&2
    echo "       (Debian/Ubuntu: sudo apt install bzip2 fdisk gzip e2fsprogs openssh-client)" >&2
    exit 1
fi

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

# fdisk の Sectors 列はブートフラグ '*' の有無で位置がずれるため補正して読む
wic_sectors() { fdisk -l "$WORK/image.wic" | awk -v p="wic$1 " 'index($0,p){ if ($2=="*") print $5; else print $4; exit }'; }
wic_start()   { fdisk -l "$WORK/image.wic" | awk -v p="wic$1 " 'index($0,p){ if ($2=="*") print $3; else print $2; exit }'; }

# レイアウト判別:
#   RPi5 A/B  : p1 = AUTOBOOT (4MiB = 8192 sectors), boot = p2, root = p5
#   i.MX eMMC : p1 = BOOTA (256MiB),                boot = p1, root = p5
P1_SECTORS=$(wic_sectors 1)
[ -n "$P1_SECTORS" ] || { echo "ERROR: cannot read partition table from image" >&2; exit 1; }
if [ "$P1_SECTORS" -le 16384 ]; then
    PLATFORM=rpi;  BOOT_WICPART=2; BOOT_CFG="cmdline.txt"
else
    PLATFORM=imx;  BOOT_WICPART=1; BOOT_CFG="extlinux/extlinux.conf"
fi
echo "    layout: $PLATFORM (boot=wic${BOOT_WICPART}, root=wic5)"

BOOT_START=$(wic_start "$BOOT_WICPART")
BOOT_SECTORS=$(wic_sectors "$BOOT_WICPART")
ROOT_START=$(wic_start 5)
ROOT_SECTORS=$(wic_sectors 5)
[ -n "$BOOT_START" ] && [ -n "$ROOT_START" ] || { echo "ERROR: image is not an A/B layout (boot/root partitions not found)" >&2; exit 1; }
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

# デバイス側プラットフォーム判別 (i.MX 版 kart-ab-status は UBOOT_* を出す)
# — イメージのレイアウト判別と食い違ったら即中断
if echo "$STATUS" | grep -q '^UBOOT_KART_SLOT='; then DEV_PLATFORM=imx; else DEV_PLATFORM=rpi; fi
if [ "$DEV_PLATFORM" != "$PLATFORM" ]; then
    echo "ERROR: image layout is '$PLATFORM' but device is '$DEV_PLATFORM' — wrong image for this device" >&2
    exit 1
fi
IN_LABEL=$([ "$IN_SLOT" = "A" ] && echo BOOTA || echo BOOTB)
IN_RLABEL=$([ "$IN_SLOT" = "A" ] && echo roota || echo rootb)

echo "==> [3/6] Writing INACTIVE slot $IN_SLOT (${BASE}p${IN_BOOT} + ${BASE}p${IN_ROOT})..."
# Relabel + fresh UUID on the HOST before transfer (the device has no
# e2fsprogs). Prevents roota/rootb label and UUID duplication between slots.
echo "    prepare rootfs image: label=${IN_RLABEL}, new UUID..."
e2label "$WORK/root.img" "$IN_RLABEL"
tune2fs -U random "$WORK/root.img" >/dev/null 2>&1 || true
echo "    rootfs -> ${BASE}p${IN_ROOT} (dd over ssh)..."
gzip -c "$WORK/root.img" | "${SSH[@]}" "gzip -dc | dd of=${BASE}p${IN_ROOT} bs=4M && sync"
echo "    boot files -> ${BASE}p${IN_BOOT} (file copy, label preserved)..."
gzip -c "$WORK/boot.img" | "${SSH[@]}" "
set -e
gzip -dc > /tmp/ota-boot.img
mkdir -p /tmp/ota-src /tmp/ota-dst
mount -o loop,ro /tmp/ota-boot.img /tmp/ota-src
mount ${BASE}p${IN_BOOT} /tmp/ota-dst
rm -rf /tmp/ota-dst/*
cp -r /tmp/ota-src/. /tmp/ota-dst/
sed -i 's|root=/dev/[a-z0-9]*p[56]|root=${BASE}p${IN_ROOT}|' /tmp/ota-dst/${BOOT_CFG}
echo '    root cfg:' \$(grep -o 'root=[^ ]*' /tmp/ota-dst/${BOOT_CFG})
sync
umount /tmp/ota-src /tmp/ota-dst
rm -f /tmp/ota-boot.img
"

echo "==> [4/6] Rebooting into slot $IN_SLOT (one-shot try)..."
if [ "$PLATFORM" = "rpi" ]; then
    # Pre-flight: the [tryboot] section must point at the slot we just wrote,
    # otherwise tryboot would boot the WRONG slot (seen once when a commit did
    # not persist). Read the selector fresh from disk via kart-ab-status.
    TB_TARGET=$("${SSH[@]}" kart-ab-status | sed -n '/^\[tryboot\]/,/^\[/s/^boot_partition=\([0-9]*\)/\1/p' | head -n 1)
    if [ "$TB_TARGET" != "$IN_BOOT" ]; then
        echo "ERROR: autoboot.txt [tryboot] points at partition '$TB_TARGET' but we wrote partition $IN_BOOT." >&2
        echo "       Selector state is inconsistent — run 'kart-ab-status' on the device and fix" >&2
        echo "       (usually: run 'kart-ab-commit' on the device to resync, then re-run this update)." >&2
        exit 1
    fi
    "${SSH[@]}" "reboot '0 tryboot'" || true
else
    # i.MX: U-Boot bootcount 方式。upgrade_available=1 + bootlimit で
    # 「新スロットを試し、起動失敗が続けば altbootcmd が旧スロットへ復帰」。
    # Pre-flight: 別の更新が試行中 (upgrade_available=1) なら手を出さない。
    UA=$(echo "$STATUS" | sed -n 's/^UBOOT_UPGRADE_AVAILABLE=//p')
    if [ "$UA" = "1" ]; then
        echo "ERROR: upgrade_available=1 — a previous update try is still pending." >&2
        echo "       Commit it (kart-ab-commit) or power-cycle to fall back, then re-run." >&2
        exit 1
    fi
    IN_LC=$(echo "$IN_SLOT" | tr 'AB' 'ab')
    ACTIVE_LC=$(echo "$ACTIVE" | tr 'AB' 'ab')
    "${SSH[@]}" "
set -e
printf 'kart_slot ${IN_LC}\nkart_fallback_slot ${ACTIVE_LC}\nupgrade_available 1\nbootcount 0\n' > /tmp/ota-env
fw_setenv -s /tmp/ota-env
v=\$(fw_printenv -n kart_slot)
[ \"\$v\" = \"${IN_LC}\" ] || { echo 'ERROR: fw_setenv read-back failed' >&2; exit 1; }
rm -f /tmp/ota-env
"
    "${SSH[@]}" reboot || true
fi

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
"${SSH[@]}" 'systemctl is-active weston kmm can0-up 2>/dev/null | tr "\n" " "; echo; systemctl --failed --no-legend | wc -l | xargs echo "    failed units:"'

echo "==> [6/6] Commit?"
read -rp "    Make slot $IN_SLOT permanent? [y/N] " ok
if [[ "$ok" =~ ^[Yy]$ ]]; then
    "${SSH[@]}" kart-ab-commit
    echo "==> OTA complete: slot $IN_SLOT is now the boot slot."
else
    echo "==> NOT committed. Next reboot returns to slot $ACTIVE."
fi
