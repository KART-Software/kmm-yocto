SUMMARY = "Early /data mount service (persistent partition)"
DESCRIPTION = "Mounts the A/B-shared /data partition early at boot, deriving \
the device from the kernel cmdline instead of waiting for udev label scan. \
No-op on non-A/B layouts (QEMU etc.)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://data-mount.service \
    file://data-mount.sh \
    file://data-partition.conf \
"

inherit systemd

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/data-mount.sh ${D}${sbindir}/data-mount

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/data-mount.service ${D}${systemd_system_unitdir}/data-mount.service

    install -d ${D}${sysconfdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/data-partition.conf ${D}${sysconfdir}/tmpfiles.d/data-partition.conf
}

SYSTEMD_SERVICE:${PN} = "data-mount.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    ${sbindir}/data-mount \
    ${systemd_system_unitdir}/data-mount.service \
    ${sysconfdir}/tmpfiles.d/data-partition.conf \
"
