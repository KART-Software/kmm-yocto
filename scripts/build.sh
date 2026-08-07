#!/bin/bash
# build.sh — Wrapper for kas-container build
#
# Usage:
#   ./scripts/build.sh <target> [options]
#
# Targets:
#   prod    RPi5 本番 (NVMe boot)
#   dev     RPi5 開発 (debug-tweaks, ブート方式の指定が必要)
#   qemu    QEMU 開発
#   imx8mm  i.MX8M Mini EVK 開発 (XPI-iMX8MM 移行の足場)
#
# Options:
#   --sdcard     SD カードブート (dev 用)
#   --nvme       NVMe ブート (dev 用)
#   --emmc       eMMC A/B レイアウト (imx8mm 用; 省略時は SD 持ち込み用シングルスロット)
#
# アプリ (C++ 版) は常にイメージに含まれる（レシピが SRCREV 固定で取得）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Parse arguments ---
TARGET=""
BOOT=""

for arg in "$@"; do
    case "$arg" in
        prod|dev|qemu|imx8mm) TARGET="$arg" ;;
        --sdcard)      BOOT="sdcard" ;;
        --nvme)        BOOT="nvme" ;;
        --emmc)        BOOT="emmc" ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 <prod|dev|qemu|imx8mm> [--sdcard|--nvme]" >&2
            exit 1
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <prod|dev|qemu|imx8mm> [--sdcard|--nvme]" >&2
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
        if [ "$BOOT" = "emmc" ]; then
            KAS_CONFIG="kas/imx8mm-dev.yml:kas/imx8mm-emmc-ab.yml"
        else
            KAS_CONFIG="kas/imx8mm-dev.yml"
        fi
        ;;
esac

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
