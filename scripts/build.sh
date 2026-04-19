#!/bin/bash
# build.sh — Wrapper for kas-container build
#
# Usage:
#   ./scripts/build.sh <target> [options]
#
# Targets:
#   prod   RPi5 本番 (NVMe boot)
#   dev    RPi5 開発 (debug-tweaks, ブート方式の指定が必要)
#   qemu   QEMU 開発
#
# Options:
#   --sdcard     SD カードブート (dev 用)
#   --nvme       NVMe ブート (dev 用)
#   --with-app   kart-machine-manager をイメージに埋め込む
#                (kas/app-embed.yml で GitHub からクローン)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Parse arguments ---
TARGET=""
WITH_APP=false
BOOT=""

for arg in "$@"; do
    case "$arg" in
        prod|dev|qemu) TARGET="$arg" ;;
        --with-app)    WITH_APP=true ;;
        --sdcard)      BOOT="sdcard" ;;
        --nvme)        BOOT="nvme" ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 <prod|dev|qemu> [--sdcard|--nvme] [--with-app]" >&2
            exit 1
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "Usage: $0 <prod|dev|qemu> [--sdcard|--nvme] [--with-app]" >&2
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
esac

# --- App embedding ---
if [ "$WITH_APP" = true ]; then
    KAS_CONFIG="$KAS_CONFIG:kas/app-embed.yml"
fi

# --- Build ---
echo "==> Building: kas-container build $KAS_CONFIG"
cd "$PROJECT_DIR"
kas-container build "$KAS_CONFIG"

echo "==> Build complete ($TARGET)"
