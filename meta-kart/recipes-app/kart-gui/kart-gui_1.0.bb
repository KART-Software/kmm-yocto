SUMMARY = "Kart GUI application"
DESCRIPTION = "PyQt6-based kiosk GUI application for the Kart product"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://kart-gui.py \
    file://kart-gui.service \
    file://gpio-config.json \
"

inherit systemd

RDEPENDS:${PN} = " \
    python3-core \
    python3-pyqt6 \
    python3-json \
    libgpiod \
"

do_install() {
    # Application files
    install -d ${D}/opt/kart-gui
    install -m 0755 ${WORKDIR}/kart-gui.py ${D}/opt/kart-gui/kart-gui.py
    install -m 0644 ${WORKDIR}/gpio-config.json ${D}/opt/kart-gui/gpio-config.json

    # systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kart-gui.service ${D}${systemd_system_unitdir}/kart-gui.service
}

SYSTEMD_SERVICE:${PN} = "kart-gui.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    /opt/kart-gui \
    ${systemd_system_unitdir}/kart-gui.service \
"
