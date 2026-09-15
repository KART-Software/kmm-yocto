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
#   --netboot    TFTP/NFS root (imx8mm、bring-up 用)
#   --sdcard     SD カードブート (RPi5 dev 用)
#   --nvme       NVMe ブート (RPi5 dev 用)
#
# アプリ (C++ 版) は常にイメージに含まれる（レシピが SRCREV 固定で取得）。
#
# 例:
#   ./scripts/build.sh imx8mp --emmc            # dev イメージ (U-Boot proper 起動)
#   ./scripts/build.sh imx8mp --emmc --falcon   # 製品ブート (falcon+splash、M7 なし)
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

for arg in "$@"; do
    case "$arg" in
        prod|dev|qemu|imx8mm|imx8mp) TARGET="$arg" ;;
        --sdcard)      BOOT="sdcard" ;;
        --nvme)        BOOT="nvme" ;;
        --emmc)        BOOT="emmc" ;;
        --netboot)     BOOT="netboot" ;;
        --falcon)      FALCON=1 ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 <imx8mp|imx8mm|qemu|prod|dev> [--emmc] [--falcon] [--sdcard|--nvme|--netboot]" >&2
            exit 1
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <imx8mp|imx8mm|qemu|prod|dev> [--emmc] [--falcon] [--sdcard|--nvme|--netboot]" >&2
    exit 1
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
            *)       KAS_CONFIG="kas/imx8mm-dev.yml" ;;
        esac
        ;;
    imx8mp)
        case "$BOOT" in
            emmc)    KAS_CONFIG="kas/imx8mp-dev.yml:kas/imx-emmc-ab.yml" ;;
            *)       KAS_CONFIG="kas/imx8mp-dev.yml" ;;
        esac
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
        imx8mp) KAS_CONFIG="$KAS_CONFIG:kas/imx8mp-falcon.yml:kas/imx8mp-splash.yml" ;;
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
