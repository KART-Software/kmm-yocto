SUMMARY = "Fullscreen raw-image viewer for Wayland (bench tool)"
DESCRIPTION = "Minimal wl_shm client that shows a raw XRGB8888 file fullscreen. \
Used by the LCD validation system (tools/lcd-validation/) to display AprilTag \
test patterns on the target. Not installed into images — the binary is deployed \
to tmp/deploy/images/ and scp'd to the board when needed."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://wl-image-view.c"

DEPENDS = "wayland wayland-native wayland-protocols"

inherit pkgconfig deploy

XDG_SHELL_XML = "${RECIPE_SYSROOT}${datadir}/wayland-protocols/stable/xdg-shell/xdg-shell.xml"

do_compile() {
    wayland-scanner private-code ${XDG_SHELL_XML} xdg-shell-protocol.c
    wayland-scanner client-header ${XDG_SHELL_XML} xdg-shell-client-protocol.h
    ${CC} ${CFLAGS} -I. -I${WORKDIR} ${LDFLAGS} \
        -o wl-image-view ${WORKDIR}/wl-image-view.c xdg-shell-protocol.c \
        $(pkg-config --cflags --libs wayland-client)
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/wl-image-view ${D}${bindir}/wl-image-view
}

do_deploy() {
    install -m 0755 ${B}/wl-image-view ${DEPLOYDIR}/wl-image-view
}
addtask deploy after do_install before do_build

FILES:${PN} = "${bindir}/wl-image-view"
