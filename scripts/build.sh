#!/bin/bash
# build.sh — Wrapper for kas-container build
#
# Usage:
#   ./scripts/build.sh <target> [options]
#
# Targets:
#   imx8mp  DEBIX Infinity (i.MX8M Plus) — 最新
#   imx8mm  XPI-iMX8MM (i.MX8M Mini)
#   qemu    QEMU 開発
#   prod    RPi5 本番 (NVMe boot、旧)
#   dev     RPi5 開発 (debug-tweaks, ブート方式の指定が必要、旧)
#
# Options:
#   --emmc       eMMC A/B レイアウト (imx8mm/imx8mp; 省略時は SD 持ち込み用シングルスロット)
#   --falcon     Falcon Mode + SPL スプラッシュを合成 (製品ブート経路; --emmc 必須)
#                imx8mp の SPL スプラッシュ (kas/imx8mp-splash.yml) は HDMI 用なので、--hdmi の
#                ときだけ付く (LVDS 版は未実装、docs/imx8mp-debix-bringup/open-issues.md #15)
#   --hdmi       表示を HDMI にする (imx8mp; kas/imx8mp-hdmi.yml)。省略時は J10 の LVDS パネル
#   --netboot    TFTP/NFS root (imx8mm、bring-up 用)
#   --sdcard     SD カードブート (RPi5 用)
#   --nvme       NVMe ブート (RPi5 用)
#
# target と起動方式の組み合わせ (表に無いものはエラーで止める。target と起動方式は 1 つずつ):
#   imx8mp       なし | --emmc [--falcon]   (どれにも --hdmi を足せる)
#   imx8mm       なし | --emmc [--falcon] | --netboot
#   qemu         なし
#   prod / dev   --sdcard | --nvme (必須)
#
# アプリ (C++ 版) は常にイメージに含まれる（レシピが SRCREV 固定で取得）。
#
# 例:
#   ./scripts/build.sh imx8mp --emmc            # dev イメージ (U-Boot proper 起動)
#   ./scripts/build.sh imx8mp --emmc --falcon   # 製品ブート (falcon、LVDS、SPL スプラッシュなし、M7 なし)
#   ./scripts/build.sh imx8mp --emmc --falcon --hdmi  # 同じく HDMI (falcon + SPL スプラッシュ)
#
# Cortex-M CAN ゲートウェイ (M7/M4) は別オーバーレイ。--falcon の kas 構成に
# :kas/imx8mp-m7.yml (または imx8mm-m4.yml) を足す。手順は README 参照。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Parse arguments ---
TARGET=""
BOOT=""
FALCON=""
HDMI=""
USAGE="Usage: $0 <imx8mp|imx8mm|qemu|prod|dev> [--emmc|--netboot|--sdcard|--nvme] [--falcon] [--hdmi]"

die() {
    echo "Error: $*" >&2
    exit 1
}

for arg in "$@"; do
    case "$arg" in
        prod|dev|qemu|imx8mm|imx8mp)
            [ -z "$TARGET" ] || die "specify only one target (got $TARGET and $arg)"
            TARGET="$arg"
            ;;
        --sdcard|--nvme|--emmc|--netboot)
            [ -z "$BOOT" ] || die "specify only one boot option (got --$BOOT and $arg)"
            BOOT="${arg#--}"
            ;;
        --falcon)
            [ -z "$FALCON" ] || die "--falcon given twice"
            FALCON=1
            ;;
        --hdmi)
            [ -z "$HDMI" ] || die "--hdmi given twice"
            HDMI=1
            ;;
        -h|--help)
            sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "$USAGE" >&2
            exit 1
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "$USAGE" >&2
    exit 1
fi

# --- Check the combination (no silent fallback to a default config) ---
case "$TARGET" in
    imx8mp)   ALLOWED_BOOT="emmc" ;;
    imx8mm)   ALLOWED_BOOT="emmc netboot" ;;
    qemu)     ALLOWED_BOOT="" ;;
    prod|dev) ALLOWED_BOOT="sdcard nvme" ;;
esac
if [ -n "$BOOT" ]; then
    case " $ALLOWED_BOOT " in
        *" $BOOT "*) ;;
        *) die "$TARGET does not support --$BOOT (allowed: ${ALLOWED_BOOT:-none})" ;;
    esac
fi
if [ -n "$FALCON" ]; then
    case "$TARGET" in
        imx8mm|imx8mp) ;;
        *) die "--falcon is only supported for imx8mm/imx8mp" ;;
    esac
fi
if [ -n "$HDMI" ] && [ "$TARGET" != imx8mp ]; then
    die "--hdmi is only supported for imx8mp (DEBIX の表示の選択)"
fi

# --- Map target to kas config ---
case "$TARGET" in
    prod)
        if [ -z "$BOOT" ]; then
            echo "Error: prod target requires --sdcard or --nvme" >&2
            exit 1
        fi
        KAS_CONFIG="kas/rpi5-prod.yml:kas/boot-${BOOT}.yml"
        ;;
    dev)
        if [ -z "$BOOT" ]; then
            echo "Error: dev target requires --sdcard or --nvme" >&2
            exit 1
        fi
        KAS_CONFIG="kas/local-dev.yml:kas/boot-${BOOT}.yml"
        ;;
    qemu) KAS_CONFIG="kas/qemu-dev.yml" ;;
    imx8mm)
        case "$BOOT" in
            emmc)    KAS_CONFIG="kas/imx8mm-dev.yml:kas/imx8mm-emmc-ab.yml" ;;
            netboot) KAS_CONFIG="kas/imx8mm-dev.yml:kas/imx8mm-netboot.yml" ;;
            "")      KAS_CONFIG="kas/imx8mm-dev.yml" ;;
        esac
        ;;
    imx8mp)
        case "$BOOT" in
            emmc)    KAS_CONFIG="kas/imx8mp-dev.yml:kas/imx-emmc-ab.yml" ;;
            "")      KAS_CONFIG="kas/imx8mp-dev.yml" ;;
        esac
        [ -z "$HDMI" ] || KAS_CONFIG="$KAS_CONFIG:kas/imx8mp-hdmi.yml"
        ;;
esac

# --- Optional Falcon Mode + SPL splash overlay (product boot path) ---
# M7/M4 CAN gateway is intentionally kept separate: append the M-core overlay
# (kas/imx8mp-m7.yml / kas/imx8mm-m4.yml) to the printed KAS_CONFIG by hand.
if [ -n "$FALCON" ]; then
    if [ "$BOOT" != "emmc" ]; then
        echo "Error: --falcon requires --emmc (falcon boots falcon.itb from the eMMC A/B layout)" >&2
        exit 1
    fi
    case "$TARGET" in
        # 8MP の SPL スプラッシュは HDMI の表示チェーンを直接叩くので、HDMI のときだけ付ける
        imx8mp) KAS_CONFIG="$KAS_CONFIG:kas/imx8mp-falcon.yml${HDMI:+:kas/imx8mp-splash.yml}" ;;
        imx8mm) KAS_CONFIG="$KAS_CONFIG:kas/imx8mm-falcon.yml:kas/imx8mm-splash.yml" ;;
        *) echo "Error: --falcon is only supported for imx8mm/imx8mp" >&2; exit 1 ;;
    esac
fi

# --- Build ---
# kas-container bind-mounts these into the container (/downloads, /sstate) and
# exports DL_DIR/SSTATE_DIR inside it. Without them, base.yml's weak defaults
# (${TOPDIR}/../...) resolve against TOPDIR=/build — i.e. the container root,
# which is not writable — and bitbake's sanity checker aborts the build.
export DL_DIR="${DL_DIR:-$PROJECT_DIR/downloads}"
export SSTATE_DIR="${SSTATE_DIR:-$PROJECT_DIR/sstate-cache}"

echo "==> Building: kas-container build $KAS_CONFIG"
cd "$PROJECT_DIR"
kas-container build "$KAS_CONFIG"

echo "==> Build complete ($TARGET)"
