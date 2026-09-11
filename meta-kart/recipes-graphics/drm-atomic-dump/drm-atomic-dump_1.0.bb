SUMMARY = "LD_PRELOAD shim dumping DRM atomic/setcrtc requests with property names (bench tool)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://drm-atomic-dump.c"
DEPENDS = "libdrm"
inherit pkgconfig deploy

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -shared -fPIC -o libdrm-atomic-dump.so ${WORKDIR}/drm-atomic-dump.c \
        $(pkg-config --cflags --libs libdrm) -ldl
}
do_install() {
    install -d ${D}${libdir}
    install -m 0755 ${B}/libdrm-atomic-dump.so ${D}${libdir}/
}
do_deploy() {
    install -m 0755 ${B}/libdrm-atomic-dump.so ${DEPLOYDIR}/libdrm-atomic-dump.so
}
addtask deploy after do_install before do_build
FILES:${PN} = "${libdir}/libdrm-atomic-dump.so"
FILES_SOLIBSDEV = ""
INSANE_SKIP:${PN} += "dev-so"
