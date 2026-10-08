SUMMARY = "Boot-time systemd tuning for the image"
DESCRIPTION = "Delays systemd-resolved until after the GUI is on screen \
(timer gated on kmm.service READY) and makes networkd-wait-online return as \
soon as any one link is up instead of waiting for all of them."
LICENSE = "PolyForm-Noncommercial-1.0.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/PolyForm-Noncommercial-1.0.0;md5=fa4f6eb8206bcfb6954542687e669418"

SRC_URI = " \
    file://resolved-delayed-start.service \
    file://resolved-delayed-start.timer \
    file://wait-online-any.conf \
"

inherit systemd

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/resolved-delayed-start.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/resolved-delayed-start.timer ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/systemd/system/systemd-networkd-wait-online.service.d
    install -m 0644 ${WORKDIR}/wait-online-any.conf \
        ${D}${sysconfdir}/systemd/system/systemd-networkd-wait-online.service.d/any.conf
}

SYSTEMD_SERVICE:${PN} = "resolved-delayed-start.timer"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    ${systemd_system_unitdir}/resolved-delayed-start.service \
    ${systemd_system_unitdir}/resolved-delayed-start.timer \
    ${sysconfdir}/systemd/system/systemd-networkd-wait-online.service.d/any.conf \
"
