#!/bin/bash
# release.sh — Build image and upload to GitHub Release
#
# Usage:
#   ./scripts/release.sh [-sdcard] [-nvme] [--with-app] [TAG]
#
# Examples:
#   ./scripts/release.sh -sdcard --with-app          # SD カードのみ、タグ自動
#   ./scripts/release.sh -nvme --with-app v1.0.0     # NVMe のみ、タグ指定
#   ./scripts/release.sh --with-app                   # SD + NVMe 両方、タグ自動
#
# Environment:
#   GITHUB_TOKEN  GitHub Personal Access Token (required)
#                 export GITHUB_TOKEN=ghp_xxxxx

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_DIR="${PROJECT_DIR}/build/tmp/deploy/images/raspberrypi5"
REPO="KART-Software/kmm-yocto"
API="https://api.github.com"

# --- Parse arguments ---
usage() {
    echo "Usage: $0 [-sdcard] [-nvme] [--with-app] [TAG]"
    echo ""
    echo "  省略時は -sdcard -nvme 両方をビルド"
    echo ""
    echo "Environment:"
    echo "  GITHUB_TOKEN  GitHub PAT (required)"
    exit 1
}

BUILD_SDCARD=false
BUILD_NVME=false
WITH_APP=""
TAG=""

for arg in "$@"; do
    case "$arg" in
        -sdcard)    BUILD_SDCARD=true ;;
        -nvme)      BUILD_NVME=true ;;
        --with-app) WITH_APP="--with-app" ;;
        -h|--help)  usage ;;
        *)          TAG="$arg" ;;
    esac
done

# 未指定なら両方
if [ "$BUILD_SDCARD" = false ] && [ "$BUILD_NVME" = false ]; then
    BUILD_SDCARD=true
    BUILD_NVME=true
fi

IMAGE_TYPES=()
[ "$BUILD_SDCARD" = true ] && IMAGE_TYPES+=(sdcard)
[ "$BUILD_NVME" = true ]   && IMAGE_TYPES+=(nvme)

if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "ERROR: GITHUB_TOKEN is not set" >&2
    echo "  export GITHUB_TOKEN=ghp_xxxxx" >&2
    exit 1
fi

# --- Check for uncommitted changes ---
cd "$PROJECT_DIR"
if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "ERROR: Uncommitted or untracked files detected. Commit or stash before releasing." >&2
    git status --short >&2
    exit 1
fi

AUTH="Authorization: Bearer ${GITHUB_TOKEN}"

for IMAGE_TYPE in "${IMAGE_TYPES[@]}"; do
    echo ""
    echo "============================================"
    echo "==> [${IMAGE_TYPE}] Building prod ${WITH_APP}..."
    echo "============================================"
    "${SCRIPT_DIR}/build.sh" prod "--${IMAGE_TYPE}" $WITH_APP

    # --- Find image (resolve symlink to actual file) ---
    SYMLINK_PATH=$(find "$IMAGE_DIR" -name "kart-image-raspberrypi5-${IMAGE_TYPE}.wic.bz2" 2>/dev/null | head -1)
    if [ -z "$SYMLINK_PATH" ] || [ ! -e "$SYMLINK_PATH" ]; then
        echo "ERROR: Image not found: kart-image-raspberrypi5-${IMAGE_TYPE}.wic.bz2" >&2
        exit 1
    fi
    IMAGE_PATH=$(readlink -f "$SYMLINK_PATH")

    IMAGE_NAME=$(basename "$IMAGE_PATH")
    IMAGE_SIZE=$(du -h "$IMAGE_PATH" | cut -f1)

    # --- Derive tag from image filename if not specified ---
    # e.g. kart-image-raspberrypi5-sdcard-20260420123456.wic.bz2 -> 20260420123456
    if [ -z "$TAG" ]; then
        TAG=$(echo "$IMAGE_NAME" | sed "s/kart-image-raspberrypi5-${IMAGE_TYPE}-//;s/\.wic\.bz2//")
        if [ -z "$TAG" ]; then
            echo "ERROR: Could not derive tag from filename: ${IMAGE_NAME}" >&2
            exit 1
        fi
    fi

    echo ""
    echo "==> Image: ${IMAGE_NAME} (${IMAGE_SIZE})"
    echo "==> Tag: ${TAG}"
    echo ""

    # --- Create or get release ---
    RELEASE_JSON=$(curl -sf -H "$AUTH" "${API}/repos/${REPO}/releases/tags/${TAG}" 2>/dev/null || true)

    if [ -n "$RELEASE_JSON" ]; then
        echo "==> Release ${TAG} already exists, uploading asset..."
        UPLOAD_URL=$(echo "$RELEASE_JSON" | grep '"upload_url"' | sed 's/.*"upload_url": *"//;s/{.*//')
    else
        echo "==> Creating release ${TAG}..."
        BODY="- App embedded: $([ -n "$WITH_APP" ] && echo yes || echo no)\\n- Built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

        RELEASE_JSON=$(curl -sf -X POST -H "$AUTH" \
            -H "Content-Type: application/json" \
            -d "{\"tag_name\":\"${TAG}\",\"name\":\"${TAG}\",\"body\":\"${BODY}\"}" \
            "${API}/repos/${REPO}/releases")

        UPLOAD_URL=$(echo "$RELEASE_JSON" | grep '"upload_url"' | sed 's/.*"upload_url": *"//;s/{.*//')
    fi

    if [ -z "$UPLOAD_URL" ]; then
        echo "ERROR: Failed to get upload URL" >&2
        echo "$RELEASE_JSON" >&2
        exit 1
    fi

    # --- Upload asset ---
    echo "==> Uploading ${IMAGE_NAME}..."
    curl -f --progress-bar \
        -H "$AUTH" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${IMAGE_PATH}" \
        "${UPLOAD_URL}?name=${IMAGE_NAME}&label=${IMAGE_NAME}" \
        -o /dev/null

    echo "==> [${IMAGE_TYPE}] Done"
done

echo ""
echo "==> Release complete: ${TAG}"
echo "    https://github.com/${REPO}/releases/tag/${TAG}"
