SUMMARY = "Minimal DRM/KMS raw-image viewer (bench tool, no compositor)"
LICENSE = "PolyForm-Noncommercial-1.0.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/PolyForm-Noncommercial-1.0.0;md5=fa4f6eb8206bcfb6954542687e669418"
SRC_URI = "file://drm-image-view.c"
DEPENDS = "libdrm"
inherit pkgconfig deploy

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} -o drm-image-view ${WORKDIR}/drm-image-view.c \
        $(pkg-config --cflags --libs libdrm)
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/drm-image-view ${D}${bindir}/
}

do_deploy() {
    install -m 0755 ${B}/drm-image-view ${DEPLOYDIR}/drm-image-view
}
addtask deploy after do_install before do_build

FILES:${PN} = "${bindir}/drm-image-view"
