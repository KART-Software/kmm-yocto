SUMMARY = "EDID firmware file for the XPI development panel (TFP401)"
DESCRIPTION = "Panel EDID as a firmware file for drm.edid_firmware=, \
eliminating the 1.1-1.4s DDC read through the LT9611 bridge at every \
modeset (cmdline is set in kas/imx8mm.yml). 128 bytes, checksum-verified \
copy of the panel's real EDID."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://kart-tfp401-edid.bin"

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/edid
    install -m 0644 ${WORKDIR}/kart-tfp401-edid.bin \
        ${D}${nonarch_base_libdir}/firmware/edid/kart-tfp401-edid.bin
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/edid/kart-tfp401-edid.bin"
