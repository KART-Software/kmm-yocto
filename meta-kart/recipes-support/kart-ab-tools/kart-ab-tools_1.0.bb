SUMMARY = "A/B slot helpers for the kart image"
DESCRIPTION = "kart-ab-status shows the active/inactive slot; kart-ab-commit \
makes the running slot permanent after a successful try-boot. RPi5 uses the \
firmware tryboot + autoboot.txt mechanism; i.MX uses U-Boot bootcount + \
fw_setenv (machine-specific script variants are picked up automatically from \
files/<override>/ via FILESPATH)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://kart-ab-status \
    file://kart-ab-commit \
"

# i.MX のみ: U-Boot 自体の A/B (ROM secondary image + PERSIST_SECONDARY_BOOT)
SRC_URI:append:mx8mm-generic-bsp = " \
    file://kart-uboot-status \
    file://kart-uboot-update \
    file://kart-uboot-rollback \
    file://kart-uboot-selfheal \
    file://kart-uboot-selfheal.service \
    file://fw_env.config \
"

# フォールバック起動 (B copy) を検出したら boot 時に自動で A を修復する
inherit systemd
SYSTEMD_SERVICE:${PN} = ""
SYSTEMD_SERVICE:${PN}:mx8mm-generic-bsp = "kart-uboot-selfheal.service"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/kart-ab-status ${D}${sbindir}/kart-ab-status
    install -m 0755 ${WORKDIR}/kart-ab-commit ${D}${sbindir}/kart-ab-commit
}

do_install:append:mx8mm-generic-bsp() {
    install -m 0755 ${WORKDIR}/kart-uboot-status ${D}${sbindir}/kart-uboot-status
    install -m 0755 ${WORKDIR}/kart-uboot-update ${D}${sbindir}/kart-uboot-update
    install -m 0755 ${WORKDIR}/kart-uboot-rollback ${D}${sbindir}/kart-uboot-rollback
    install -m 0755 ${WORKDIR}/kart-uboot-selfheal ${D}${sbindir}/kart-uboot-selfheal
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kart-uboot-selfheal.service ${D}${systemd_system_unitdir}/kart-uboot-selfheal.service
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}

FILES:${PN} = "${sbindir}/kart-ab-status ${sbindir}/kart-ab-commit"
FILES:${PN}:append:mx8mm-generic-bsp = " \
    ${sbindir}/kart-uboot-status \
    ${sbindir}/kart-uboot-update \
    ${sbindir}/kart-uboot-rollback \
    ${sbindir}/kart-uboot-selfheal \
    ${systemd_system_unitdir}/kart-uboot-selfheal.service \
    ${sysconfdir}/fw_env.config \
"

# i.MX 版は U-Boot env を fw_printenv/fw_setenv で操作する
RDEPENDS:${PN}:append:mx8mm-generic-bsp = " libubootenv-bin"

# スクリプトの中身がマシンごとに異なるため
PACKAGE_ARCH = "${MACHINE_ARCH}"

COMPATIBLE_MACHINE = "(raspberrypi5|mx8mm-generic-bsp)"
