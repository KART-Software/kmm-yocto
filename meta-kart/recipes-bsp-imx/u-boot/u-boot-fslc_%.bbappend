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
