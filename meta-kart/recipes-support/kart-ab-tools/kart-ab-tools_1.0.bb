SUMMARY = "A/B slot helpers for the kart image"
DESCRIPTION = "kart-ab-status shows the active/inactive slot; kart-ab-commit \
makes the running slot permanent after a successful try-boot. RPi5 uses the \
firmware tryboot + autoboot.txt mechanism; i.MX uses U-Boot bootcount + \
fw_setenv (the i.MX script variants live in files/imx-generic-bsp/ and are \
picked up automatically via FILESPATH)."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://kart-ab-status \
    file://kart-ab-commit \
"

# i.MX 共通: U-Boot 自体の A/B (BootROM の secondary image フォールバック)。
# 仕組みは 8MM (SIT 表) と 8MP (fuse 固定オフセット) で違うが、Linux 側の操作
# (A/B コピーの md5・更新・巻き戻し・ROM イベントログによる起動コピー判定) は
# セクタ定数以外同じなので、スクリプトは 1 組で machine ごとに定数を埋める。
SRC_URI:append:imx-generic-bsp = " \
    file://kart-uboot-status \
    file://kart-uboot-update \
    file://kart-uboot-rollback \
    file://kart-uboot-selfheal \
    file://kart-uboot-selfheal.service \
"

# machine ごとのセクタ定数 (512B 単位) と U-Boot env の場所 (fw_env.config)。
# wks (meta-kart/wic/) と U-Boot の CONFIG_ENV_OFFSET/SIZE と一致させること。
#   8MM (XPI):   A=0x42 (33KiB)  B=0x1042 (2081KiB, SIT firstSectorNumber 0x1000+0x42)  領域 2015KiB
#   8MP (DEBIX): A=0x40 (32KiB)  B=0x2000 (4MiB, fuse IMG_CNTN_SET1_OFFSET 未設定時)   領域 3MiB
KART_UBOOT_A_SECTOR:mx8mm-generic-bsp = "66"
KART_UBOOT_B_SECTOR:mx8mm-generic-bsp = "4162"
KART_UBOOT_AREA_SECTORS:mx8mm-generic-bsp = "4030"
KART_UBOOT_ENV_OFFSET:mx8mm-generic-bsp = "0x400000"
KART_UBOOT_ENV_SIZE:mx8mm-generic-bsp = "0x2000"
KART_UBOOT_A_SECTOR:imx8mp-debix = "64"
KART_UBOOT_B_SECTOR:imx8mp-debix = "8192"
KART_UBOOT_AREA_SECTORS:imx8mp-debix = "6144"
KART_UBOOT_ENV_OFFSET:imx8mp-debix = "0x700000"
KART_UBOOT_ENV_SIZE:imx8mp-debix = "0x4000"

# フォールバック起動 (B copy) を検出したら boot 時に自動で A を修復する
inherit systemd
SYSTEMD_SERVICE:${PN} = ""
SYSTEMD_SERVICE:${PN}:imx-generic-bsp = "kart-uboot-selfheal.service"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/kart-ab-status ${D}${sbindir}/kart-ab-status
    install -m 0755 ${WORKDIR}/kart-ab-commit ${D}${sbindir}/kart-ab-commit
}

do_install:append:imx-generic-bsp() {
    for f in kart-uboot-status kart-uboot-update kart-uboot-rollback; do
        sed -e 's/@KART_UBOOT_A_SECTOR@/${KART_UBOOT_A_SECTOR}/' \
            -e 's/@KART_UBOOT_B_SECTOR@/${KART_UBOOT_B_SECTOR}/' \
            -e 's/@KART_UBOOT_AREA_SECTORS@/${KART_UBOOT_AREA_SECTORS}/' \
            ${WORKDIR}/$f > ${D}${sbindir}/$f
        chmod 0755 ${D}${sbindir}/$f
        grep -q '@KART_UBOOT_' ${D}${sbindir}/$f && bbfatal "unresolved placeholder in $f (machine constants not set?)"
    done
    install -m 0755 ${WORKDIR}/kart-uboot-selfheal ${D}${sbindir}/kart-uboot-selfheal
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kart-uboot-selfheal.service ${D}${systemd_system_unitdir}/kart-uboot-selfheal.service
    install -d ${D}${sysconfdir}
    printf '%s\t%s\t%s\n' /dev/mmcblk2 ${KART_UBOOT_ENV_OFFSET} ${KART_UBOOT_ENV_SIZE} > ${D}${sysconfdir}/fw_env.config
}

FILES:${PN} = "${sbindir}/kart-ab-status ${sbindir}/kart-ab-commit"
FILES:${PN}:append:imx-generic-bsp = " \
    ${sbindir}/kart-uboot-status \
    ${sbindir}/kart-uboot-update \
    ${sbindir}/kart-uboot-rollback \
    ${sbindir}/kart-uboot-selfheal \
    ${systemd_system_unitdir}/kart-uboot-selfheal.service \
    ${sysconfdir}/fw_env.config \
"

# i.MX 版は U-Boot env を fw_printenv/fw_setenv で操作する
RDEPENDS:${PN}:append:imx-generic-bsp = " libubootenv-bin"

# スクリプトの中身がマシンごとに異なるため
PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "(raspberrypi5|imx-generic-bsp)"
