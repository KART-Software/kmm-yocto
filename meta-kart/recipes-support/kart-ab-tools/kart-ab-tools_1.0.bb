SUMMARY = "A/B (tryboot) slot helpers for the kart image"
DESCRIPTION = "kart-ab-status shows the active/inactive slot and autoboot.txt; \
kart-ab-commit makes the running slot permanent after a successful tryboot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://kart-ab-status \
    file://kart-ab-commit \
"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/kart-ab-status ${D}${sbindir}/kart-ab-status
    install -m 0755 ${WORKDIR}/kart-ab-commit ${D}${sbindir}/kart-ab-commit
}

FILES:${PN} = "${sbindir}/kart-ab-status ${sbindir}/kart-ab-commit"

COMPATIBLE_MACHINE = "raspberrypi5"
