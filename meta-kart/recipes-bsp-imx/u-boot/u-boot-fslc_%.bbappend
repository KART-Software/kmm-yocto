# kart A/B (U-Boot bootcount) の設定フラグメント。
# 環境変数の中身は recipes-bsp-imx/kart-uboot-env/ が wic に焼き込む。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://kart-ab.cfg \
    file://kart-uboot-slim.cfg \
"

# extlinux の root= の差し替え口。machine include (imx8mm-evk.inc) が
# UBOOT_EXTLINUX_ROOT:default:use-mainline-bsp のフル修飾で = 代入しており、
# local.conf からは同じ修飾で書いても parse 順 (conf → machine conf) で負ける。
# レシピ/bbappend は全 conf の後に parse されるため、ここで同修飾を張り直して
# 間接変数 KART_EXTLINUX_ROOT に逃がす。kas フラグメント (local.conf) からは
# この間接変数を設定する。デフォルトは machine include と同じ値。
KART_EXTLINUX_ROOT ??= "root=/dev/mmcblk1p2"
UBOOT_EXTLINUX_ROOT:default:use-mainline-bsp = "${KART_EXTLINUX_ROOT}"

# falcon の proper フォールバック FIT (kart-falcon-itb が組む u-boot.itb) 用に
# 素材を deploy へ出す。falcon 非使用ビルドでも小物 2 ファイルで無害
do_deploy:append:mx8mm-generic-bsp() {
    # UBOOT_CONFIG 使用時は ${B}/${config}/ 配下に成果物ができる
    for cfg in ${UBOOT_MACHINE} ${UBOOT_CONFIG}; do
        if [ -f ${B}/$cfg/u-boot-nodtb.bin ]; then
            install -m 0644 ${B}/$cfg/u-boot-nodtb.bin ${DEPLOYDIR}/u-boot-nodtb.bin
            install -m 0644 ${B}/$cfg/u-boot.dtb ${DEPLOYDIR}/u-boot-proper.dtb
            return
        fi
    done
    if [ -f ${B}/u-boot-nodtb.bin ]; then
        install -m 0644 ${B}/u-boot-nodtb.bin ${DEPLOYDIR}/u-boot-nodtb.bin
        install -m 0644 ${B}/u-boot.dtb ${DEPLOYDIR}/u-boot-proper.dtb
    else
        bbfatal "u-boot-nodtb.bin not found under ${B} (checked ${UBOOT_MACHINE} ${UBOOT_CONFIG})"
    fi
}
