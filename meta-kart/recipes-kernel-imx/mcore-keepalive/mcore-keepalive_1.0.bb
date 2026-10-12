# M コア (data-logger-zephyr の main-app) のキープアライブを受けて、M コアが動いているかを
# /sys/bus/rpmsg/devices/<dev>/state などに出す out-of-tree カーネルモジュール (kmm-yocto issue #19)。
# 途切れたとき・戻ったときはカーネルのログに出す。仕様はソースの冒頭。
#
# recipes-kernel-imx/ 配下なので meta-freescale がある構成でしか読まれない
# (layer.conf の BBFILES_DYNAMIC) — RPi5/QEMU ビルドには影響しない。
SUMMARY = "M-core keepalive monitor over rpmsg"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/GPL-2.0-only;md5=801f80980d171dd6425610833a22dbe6"

inherit module

SRC_URI = " \
    file://Makefile \
    file://mcore-keepalive.c \
    file://mcore-keepalive.conf \
"

S = "${WORKDIR}"

COMPATIBLE_MACHINE = "(mx8mm-generic-bsp|imx8mp-debix)"

# udev の modalias autoload (coldplug の中) を待たず、systemd-modules-load で起動直後に
# ロードする (rpmsg-can と同じ)。M コアの自動確定と見張りが、起動の早いうちから使える
do_install:append() {
    install -d ${D}${sysconfdir}/modules-load.d
    install -m 0644 ${WORKDIR}/mcore-keepalive.conf ${D}${sysconfdir}/modules-load.d/mcore-keepalive.conf
}
FILES:${PN} += "${sysconfdir}/modules-load.d/mcore-keepalive.conf"
