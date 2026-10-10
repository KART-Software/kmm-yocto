#!/bin/bash
# build-recovery-uboot.sh — stock (非 falcon) U-Boot をビルドし、リカバリ・書き込み用の
# 資産として local/recovery/ へ退避する。
#
#   ./scripts/build-recovery-uboot.sh            # XPI (8MM)  → local/recovery/flash.bin-stock
#   ./scripts/build-recovery-uboot.sh imx8mp     # DEBIX (8MP) → local/recovery/imx-boot-imx8mp-stock
#
# なぜ必要か: falcon SPL は USB 書き込み (SDP) の 2 段目 (SDPV) を受けないため、UUU で
# RAM 起動して `u-boot=>` や fastboot に到達できない。UUU 経路は必ずこの stock 版を使う。
#   8MM: scripts/boot.uuu が参照 (docs/imx8mm-xpi-bringup/06-emmc-flash.md、08-falcon.md)
#   8MP: scripts/debix-flash-all.uuu / debix-probe.uuu が参照 (docs/usage/02-first-flash.md)
#
# 注意 (8MM): 実行後、deploy の flash.bin は stock になる。falcon イメージを
# ビルドし直せばオーバーレイの config 差分で u-boot も falcon に戻る。
# 8MP は別のビルドディレクトリ (build/recovery-imx8mp) で作るので、普段の deploy は変わらない。
set -euo pipefail
cd "$(dirname "$0")/.."

export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache
mkdir -p local/recovery

case "${1:-imx8mm}" in
imx8mm)
    kas-container shell kas/imx8mm-prod.yml:kas/imx8mm-emmc-ab.yml -c "bitbake u-boot-fslc"
    cp build/tmp/deploy/images/imx8mm-xpi/flash.bin-imx8mm-xpi-sd local/recovery/flash.bin-stock
    echo "==> local/recovery/flash.bin-stock を更新 (stock / SDPV 対応)"
    echo "    boot.uuu はこのファイルを使う。deploy 側は現在 stock なので、"
    echo "    falcon 運用イメージが必要なら imx8mm-falcon.yml 付きで再ビルドすること。"
    ;;
imx8mp)
    # 2 面の env (debix-ab.cfg) まで含めた、falcon を付けない構成の imx-boot
    export KAS_BUILD_DIR=$PWD/build/recovery-imx8mp
    mkdir -p "$KAS_BUILD_DIR"
    kas-container shell kas/imx8mp-dev.yml:kas/imx-emmc-ab.yml -c "bitbake imx-boot"
    out=local/recovery/imx-boot-imx8mp-stock
    new=$KAS_BUILD_DIR/tmp/deploy/images/imx8mp-debix/imx-boot-imx8mp-debix-sd.bin-flash_evk
    if [ -f "$out" ] && ! cmp -s "$new" "$out"; then
        mv "$out" "$out.prev"
        echo "    それまでの $out は $out.prev に残した"
    fi
    cp "$new" "$out"
    echo "==> $out を更新 (stock / SDPV・fastboot 対応)"
    echo "    scripts/debix-flash-all.uuu と debix-probe.uuu はこのファイルを使う。普段の deploy は変わらない。"
    ;;
*)
    echo "usage: $0 [imx8mm|imx8mp]" >&2
    exit 2
    ;;
esac
