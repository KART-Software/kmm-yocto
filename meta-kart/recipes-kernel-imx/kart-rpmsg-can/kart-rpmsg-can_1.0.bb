# M4 CAN ゲートウェイ (rpmsg チャネル "kart-can") を CAN netdev rpcan0 に
# 見せる out-of-tree カーネルモジュール。M4 側ファームは別リポジトリ
# data-logger-imx8mm-cortex-m4 の apps/can-gw。
#
# recipes-kernel-imx/ 配下なので meta-freescale がある構成でしか読まれない
# (layer.conf の BBFILES_DYNAMIC) — RPi5/QEMU ビルドには影響しない。
SUMMARY = "CAN netdev backed by rpmsg (kart Cortex-M4 CAN gateway)"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

inherit module

SRC_URI = " \
    file://Makefile \
    file://kart-rpmsg-can.c \
"

S = "${WORKDIR}"

COMPATIBLE_MACHINE = "(mx8mm-generic-bsp)"
