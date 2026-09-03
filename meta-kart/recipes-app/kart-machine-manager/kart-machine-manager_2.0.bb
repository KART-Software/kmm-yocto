SUMMARY = "Kart Machine Manager GUI application (C++/Qt6)"
DESCRIPTION = "Qt6 Widgets kiosk GUI for kart machine management with CAN bus \
support. C++ port of the former PyQt6 app: starts the GUI directly at process \
start (the daemon + notifier split existed only to hide PyQt6 import time)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# App updates: bump SRCREV (single pin; the old app-embed.yml dual pin is gone).
SRC_URI = " \
    git://github.com/KART-Software/kart-machine-manager.git;protocol=https;branch=develop \
    file://kmm.service \
"
SRCREV = "e32206810fffd8da864a4bf1df02c6f72d70fe89"

S = "${WORKDIR}/git/app-cpp"

# QEMU has no CAN hardware; ship a drop-in that runs the app in mock (DEBUG) mode.
SRC_URI:append:qemuarm64 = " file://kmm-debug.conf"

inherit qt6-cmake systemd

DEPENDS = "qtbase"

# The wayland platform plugin is a runtime plugin dependency the shlib
# scanner cannot see.
RDEPENDS:${PN} += "qtwayland"

do_install:append() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kmm.service ${D}${systemd_system_unitdir}/kmm.service
}

do_install:append:qemuarm64() {
    install -d ${D}${systemd_system_unitdir}/kmm.service.d
    install -m 0644 ${WORKDIR}/kmm-debug.conf \
        ${D}${systemd_system_unitdir}/kmm.service.d/debug.conf
}

SYSTEMD_SERVICE:${PN} = "kmm.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN}:append:qemuarm64 = " ${systemd_system_unitdir}/kmm.service.d/debug.conf"
