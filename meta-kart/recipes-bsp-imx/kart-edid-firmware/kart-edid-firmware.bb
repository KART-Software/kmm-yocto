SUMMARY = "EDID firmware file for the XPI development panel (TFP401)"
DESCRIPTION = "Panel EDID as a firmware file for drm.edid_firmware=, \
eliminating the 1.1-1.4s DDC read through the LT9611 bridge at every \
modeset (cmdline is set in kas/imx8mm.yml). 128 bytes, checksum-verified \
copy of the panel's real EDID."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://kart-tfp401-edid.bin"
# 8MP (DEBIX): パネル実 EDID は 800x480@32.00MHz だが、8MP の Samsung HDMI PHY は
# 離散クロック表に 32MHz が無く mode_valid で弾く。pclk を表にある 33.75MHz に
# 上げ、ブランキング拡張 (htotal 1072 / vtotal 525) で 59.97Hz を維持した版。
# 実機で kmm GUI のフル表示を目視確認済み (docs/imx8mp-debix-bringup/03-first-boot.md §3)。
SRC_URI:append:imx8mp-debix = " file://tfp401-edid-33m75.bin"

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/edid
    install -m 0644 ${WORKDIR}/kart-tfp401-edid.bin \
        ${D}${nonarch_base_libdir}/firmware/edid/kart-tfp401-edid.bin
}

do_install:append:imx8mp-debix() {
    install -m 0644 ${WORKDIR}/tfp401-edid-33m75.bin \
        ${D}${nonarch_base_libdir}/firmware/edid/tfp401-edid-33m75.bin
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/edid/*"
