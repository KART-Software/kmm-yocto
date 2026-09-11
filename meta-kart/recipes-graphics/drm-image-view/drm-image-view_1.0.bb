SUMMARY = "Minimal DRM/KMS raw-image viewer (bench tool, no compositor)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
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
