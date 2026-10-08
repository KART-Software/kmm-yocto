SUMMARY = "Apply the product's standard RPi5 EEPROM settings"
DESCRIPTION = "Idempotent helper that stages the validated bootloader EEPROM \
configuration (BOOT_ORDER, PSU_MAX_CURRENT, DISABLE_HDMI, ...) on a new board."
LICENSE = "PolyForm-Noncommercial-1.0.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/PolyForm-Noncommercial-1.0.0;md5=fa4f6eb8206bcfb6954542687e669418"

SRC_URI = "file://eeprom-setup"

RDEPENDS:${PN} = "rpi-eeprom"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/eeprom-setup ${D}${sbindir}/eeprom-setup
}

FILES:${PN} = "${sbindir}/eeprom-setup"

COMPATIBLE_MACHINE = "raspberrypi5"
