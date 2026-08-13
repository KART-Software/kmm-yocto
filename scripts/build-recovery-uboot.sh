#!/bin/bash
# build-recovery-uboot.sh — stock (非 falcon) U-Boot をビルドし、リカバリ資産
# として local/recovery/flash.bin-stock へ退避する。
#
# なぜ必要か: falcon SPL (kas/imx8mm-falcon.yml) は SDPV を受けないため、
# bring up (docs/imx8mm-xpi-bringup/06) や UUU リカバリで必要な
# `u-boot=>` プロンプトに到達できない。UUU 経路は必ずこの stock 版を使う
# (scripts/kart-boot.uuu が参照する)。詳細は docs/imx8mm-xpi-bringup/08-falcon.md。
#
# 注意: 実行後、deploy の flash.bin は stock になる。falcon イメージを
# ビルドし直せばオーバーレイの config 差分で u-boot も falcon に戻る。
set -euo pipefail
cd "$(dirname "$0")/.."

export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache
kas-container shell kas/imx8mm-prod.yml:kas/imx8mm-emmc-ab.yml -c "bitbake u-boot-fslc"

mkdir -p local/recovery
cp build/tmp/deploy/images/imx8mm-xpi/flash.bin-imx8mm-xpi-sd local/recovery/flash.bin-stock
echo "==> local/recovery/flash.bin-stock を更新 (stock / SDPV 対応)"
echo "    kart-boot.uuu はこのファイルを使う。deploy 側は現在 stock なので、"
echo "    falcon 運用イメージが必要なら imx8mm-falcon.yml 付きで再ビルドすること。"
