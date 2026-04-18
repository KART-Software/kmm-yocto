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
#                (../kart-machine-manager からコピー & プリコンパイル)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_SRC_DIR="$PROJECT_DIR/../kart-machine-manager"
APP_DEST_DIR="$PROJECT_DIR/kart-machine-manager"

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
cleanup_app() {
    if [ -d "$APP_DEST_DIR" ]; then
        echo "==> Cleaning up copied app source"
        rm -rf "$APP_DEST_DIR"
    fi
}

if [ "$WITH_APP" = true ]; then
    if [ ! -d "$APP_SRC_DIR" ]; then
        echo "Error: App source not found at $APP_SRC_DIR" >&2
        exit 1
    fi

    echo "==> Precompiling app bytecode"
    (cd "$APP_SRC_DIR" && uv run python -m compileall -q .)

    echo "==> Copying app source to $APP_DEST_DIR"
    cp -a "$APP_SRC_DIR" "$APP_DEST_DIR"

    KAS_CONFIG="$KAS_CONFIG:kas/app-embed.yml"

    # Cleanup on exit (success or failure)
    trap cleanup_app EXIT

    # Force rebuild of kart-machine-manager (BitBake won't detect external source changes)
    # Run cleansstate + build in a single kas-container invocation
    echo "==> Building with app (cleansstate + build)"
    cd "$PROJECT_DIR"
    kas-container shell "$KAS_CONFIG" -c \
        "bitbake -c cleansstate kart-machine-manager kart-image && bitbake kart-image"

    echo "==> Build complete ($TARGET)"
    exit 0
fi

# --- Build ---
echo "==> Building: kas-container build $KAS_CONFIG"
cd "$PROJECT_DIR"
kas-container build "$KAS_CONFIG"

echo "==> Build complete ($TARGET)"
