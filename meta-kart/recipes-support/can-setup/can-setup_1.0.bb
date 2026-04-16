SUMMARY = "CAN bus (can0) setup service"
DESCRIPTION = "Systemd service to bring up can0 interface at boot"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://can0-up.service \
    file://can0-up.sh \
    file://can0.default \
"

inherit systemd

RDEPENDS:${PN} = "iproute2"

do_install() {
    # Script
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/can0-up.sh ${D}${sbindir}/can0-up.sh

    # Default config
    install -d ${D}${sysconfdir}/default
    install -m 0644 ${WORKDIR}/can0.default ${D}${sysconfdir}/default/can0

    # systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/can0-up.service ${D}${systemd_system_unitdir}/can0-up.service
}

SYSTEMD_SERVICE:${PN} = "can0-up.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    ${sbindir}/can0-up.sh \
    ${sysconfdir}/default/can0 \
    ${systemd_system_unitdir}/can0-up.service \
"

CONFFILES:${PN} = "${sysconfdir}/default/can0"
