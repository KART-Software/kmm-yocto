SUMMARY = "Re-arm falcon boot on every successful Linux boot"
DESCRIPTION = "SPL のデッドマンスイッチ (falcon 発動時に boot_os=no を書き戻す) の\
補充側。起動早期に fw_setenv boot_os yes を打ち、次回も falcon で起動させる。\
kas/imx8mp-falcon.yml が IMAGE_INSTALL に追加する (falcon ビルド専用)。"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://falcon-rearm.service"

inherit systemd

RDEPENDS:${PN} = "libubootenv-bin"

SYSTEMD_SERVICE:${PN} = "falcon-rearm.service"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/falcon-rearm.service ${D}${systemd_system_unitdir}/
}
