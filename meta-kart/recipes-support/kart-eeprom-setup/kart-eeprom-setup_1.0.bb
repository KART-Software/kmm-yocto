SUMMARY = "Apply the kart product's standard RPi5 EEPROM settings"
DESCRIPTION = "Idempotent helper that stages the validated bootloader EEPROM \
configuration (BOOT_ORDER, PSU_MAX_CURRENT, DISABLE_HDMI, ...) on a new board."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://kart-eeprom-setup"

RDEPENDS:${PN} = "rpi-eeprom"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/kart-eeprom-setup ${D}${sbindir}/kart-eeprom-setup
}

FILES:${PN} = "${sbindir}/kart-eeprom-setup"

COMPATIBLE_MACHINE = "raspberrypi5"
