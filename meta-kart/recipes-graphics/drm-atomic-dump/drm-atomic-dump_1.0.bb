SUMMARY = "LD_PRELOAD shim dumping DRM atomic/setcrtc requests with property names (bench tool)"
LICENSE = "PolyForm-Noncommercial-1.0.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/PolyForm-Noncommercial-1.0.0;md5=fa4f6eb8206bcfb6954542687e669418"
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
