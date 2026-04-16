SUMMARY = "Kart Machine Manager GUI application"
DESCRIPTION = "PyQt6-based kiosk GUI for kart machine management with CAN bus support"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://kart-machine-manager.service \
"

inherit systemd

RDEPENDS:${PN} = " \
    python3-core \
    python3-pyqt6 \
    python3-can \
    python3-dotenv \
    python3-requests \
    python3-json \
    python3-logging \
"

do_install() {
    # Create directory structure (populated at runtime via sync-app.sh or git clone)
    install -d ${D}/opt/kart

    # systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kart-machine-manager.service ${D}${systemd_system_unitdir}/kart-machine-manager.service
}

SYSTEMD_SERVICE:${PN} = "kart-machine-manager.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    /opt/kart \
    ${systemd_system_unitdir}/kart-machine-manager.service \
"
