SUMMARY = "Wayland splash client showing the SPL boot logo until the GUI appears"
DESCRIPTION = "Minimal wl_shm client that draws the same logo as the SPL splash \
(shared kart_splash_logo.h) so the SPL splash -> weston -> kmm transition has \
no logo-less gap. kiosk-shell stacks the newest mapped surface on top, so kmm \
naturally covers this client."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# kart_splash_logo.h は u-boot (SPL スプラッシュ) と単一ソースを共用する
FILESEXTRAPATHS:prepend := "${THISDIR}/../../recipes-bsp-imx/u-boot/files:"

SRC_URI = " \
    file://kart-splash-wl.c \
    file://kart-splash-wl.service \
    file://kart_splash_logo.h \
"

DEPENDS = "wayland wayland-native wayland-protocols"

inherit systemd pkgconfig

XDG_SHELL_XML = "${RECIPE_SYSROOT}${datadir}/wayland-protocols/stable/xdg-shell/xdg-shell.xml"

do_compile() {
    wayland-scanner private-code ${XDG_SHELL_XML} xdg-shell-protocol.c
    wayland-scanner client-header ${XDG_SHELL_XML} xdg-shell-client-protocol.h
    ${CC} ${CFLAGS} -I. -I${WORKDIR} ${LDFLAGS} \
        -o kart-splash-wl ${WORKDIR}/kart-splash-wl.c xdg-shell-protocol.c \
        $(pkg-config --cflags --libs wayland-client)
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/kart-splash-wl ${D}${bindir}/kart-splash-wl
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kart-splash-wl.service \
        ${D}${systemd_system_unitdir}/kart-splash-wl.service
}

SYSTEMD_SERVICE:${PN} = "kart-splash-wl.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    ${bindir}/kart-splash-wl \
    ${systemd_system_unitdir}/kart-splash-wl.service \
"
