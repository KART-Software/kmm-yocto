SUMMARY = "Early /data mount service (persistent partition)"
DESCRIPTION = "Mounts the A/B-shared /data partition early at boot, deriving \
the device from the kernel cmdline instead of waiting for udev label scan. \
No-op on non-A/B layouts (QEMU etc.)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://kart-data-mount.service \
    file://kart-data-mount.sh \
"

inherit systemd

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/kart-data-mount.sh ${D}${sbindir}/kart-data-mount

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kart-data-mount.service ${D}${systemd_system_unitdir}/kart-data-mount.service
}

SYSTEMD_SERVICE:${PN} = "kart-data-mount.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    ${sbindir}/kart-data-mount \
    ${systemd_system_unitdir}/kart-data-mount.service \
"
