SUMMARY = "kmm machine manager GUI application (C++/Qt6)"
DESCRIPTION = "Qt6 Widgets kiosk GUI for machine management with CAN bus \
support. C++ port of the former PyQt6 app: starts the GUI directly at process \
start (the daemon + notifier split existed only to hide PyQt6 import time)."
# アプリ本体 (kart-machine-manager の app-cpp) は Ryomei Osaki の著作物。ただし app-cpp/icons/ の
# 画像 3 つは過去の貢献者 HuanLuo19 が描いたもので、このライセンスの対象外。
LICENSE = "PolyForm-Noncommercial-1.0.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/PolyForm-Noncommercial-1.0.0;md5=fa4f6eb8206bcfb6954542687e669418"

# App updates: bump SRCREV (single pin; the old app-embed.yml dual pin is gone).
SRC_URI = " \
    git://github.com/KART-Software/kart-machine-manager.git;protocol=https;branch=develop \
    file://kmm.service \
"
SRCREV = "bbd8ed2aa9c5753a877a53cc0929f3c18e9af938"

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
