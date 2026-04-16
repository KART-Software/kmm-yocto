FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://seatd.service"

inherit systemd

SYSTEMD_SERVICE:${PN} = "seatd.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/seatd.service ${D}${systemd_system_unitdir}/seatd.service
}

FILES:${PN} += "${systemd_system_unitdir}/seatd.service"
