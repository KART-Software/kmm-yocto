# M コア CAN ゲートウェイ (rpmsg チャネル "rpmsg-can") を CAN netdev rpmsgcan0 に
# 見せる out-of-tree カーネルモジュール。Linux 自身の FlexCAN (can%d) とは名前空間を
# 分けてあるので udev の改名は不要。M コア側ファームは別リポジトリ
# data-logger-zephyr (https://github.com/KART-Software/data-logger-zephyr) の apps/can-gw。
#
# recipes-kernel-imx/ 配下なので meta-freescale がある構成でしか読まれない
# (layer.conf の BBFILES_DYNAMIC) — RPi5/QEMU ビルドには影響しない。
SUMMARY = "CAN netdev rpmsgcan0 backed by rpmsg (Cortex-M CAN gateway)"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

inherit module

SRC_URI = " \
    file://Makefile \
    file://rpmsg-can.c \
    file://rpmsg-can.conf \
"

S = "${WORKDIR}"

COMPATIBLE_MACHINE = "(mx8mm-generic-bsp)"

# udev の modalias autoload (coldplug の中、~2.7s) を待たず systemd-modules-load で
# 起動直後 (~1.0s) にロードする。rpmsg チャネル自体は remoteproc attach 直後 (0.6s) に
# あるので、これで rpmsgcan0 が kmm 起動より前に生え、GUI と同時に CAN が流れ始める
do_install:append() {
    install -d ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${WORKDIR}/rpmsg-can.conf ${D}${sysconfdir}/modules-load.d/rpmsg-can.conf
}
FILES:${PN} += "${sysconfdir}/modules-load.d/rpmsg-can.conf"
