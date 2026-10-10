SUMMARY = "A/B slot helpers for the image"
DESCRIPTION = "i.MX: the ab command operates the three independent A/B sets \
(linux = BOOT/root slots, mcore = M-core firmware on p3, spl = the raw SPL \
copies) with status / try / commit / update / rollback. RPi5 keeps the older \
ab-status / ab-commit pair built on the firmware tryboot + autoboot.txt."
LICENSE = "PolyForm-Noncommercial-1.0.0"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/PolyForm-Noncommercial-1.0.0;md5=fa4f6eb8206bcfb6954542687e669418"

# RPi5 (製品から外れた前身): ファームの tryboot 版
SRC_URI = " \
    file://ab-status \
    file://ab-commit \
"
# i.MX: ab コマンド一つ (files/imx-generic-bsp/ab の冒頭に使い方)
SRC_URI:imx-generic-bsp = " \
    file://ab \
    file://ab-spl-selfheal.service \
    file://ab-mcore-confirm.service \
"

# machine ごとの定数。wks (meta-kart/wic/) と U-Boot の CONFIG_ENV_OFFSET/SIZE と一致させること。
# SPL のセクタ (512B 単位):
#   8MM (XPI):   A=0x42 (33KiB)  B=0x1042 (2081KiB, SIT firstSectorNumber 0x1000+0x42)  領域 2015KiB
#   8MP (DEBIX): A=0x40 (32KiB)  B=0x2000 (4MiB, fuse IMG_CNTN_SET1_OFFSET 未設定時)   領域 3MiB
# M コアのファームの先頭 4 バイト (hex): 8MM = "M4FW"、8MP = "M7FW" (SPL の M*_MAGIC と同じ)
AB_UBOOT_A_SECTOR:mx8mm-generic-bsp = "66"
AB_UBOOT_B_SECTOR:mx8mm-generic-bsp = "4162"
AB_UBOOT_AREA_SECTORS:mx8mm-generic-bsp = "4030"
AB_UBOOT_ENV_OFFSET:mx8mm-generic-bsp = "0x400000"
AB_UBOOT_ENV_SIZE:mx8mm-generic-bsp = "0x2000"
AB_MCORE_MAGIC:mx8mm-generic-bsp = "4d344657"
AB_UBOOT_A_SECTOR:imx8mp-debix = "64"
AB_UBOOT_B_SECTOR:imx8mp-debix = "8192"
AB_UBOOT_AREA_SECTORS:imx8mp-debix = "6144"
AB_UBOOT_ENV_OFFSET:imx8mp-debix = "0x700000"
AB_UBOOT_ENV_SIZE:imx8mp-debix = "0x4000"
AB_MCORE_MAGIC:imx8mp-debix = "4d374657"
# env 2 面化 (CONFIG_SYS_REDUNDAND_ENVIRONMENT) の 2 面目。空なら 1 面運用 (8MM)。
# fw_env.config が 2 行になると libubootenv は flags (世代カウンタ) で新しい面を選び、
# 保存は反対の面へ書く (U-Boot と同じ規約)。
AB_UBOOT_ENV_OFFSET_REDUND ?= ""
AB_UBOOT_ENV_OFFSET_REDUND:imx8mp-debix = "0x704000"

inherit systemd
SYSTEMD_SERVICE:${PN} = ""
# SPL の自動修復 (ROM が B で起動したら A を直す) と、M コアの試行の自動確定
SYSTEMD_SERVICE:${PN}:imx-generic-bsp = "ab-spl-selfheal.service ab-mcore-confirm.service"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/ab-status ${D}${sbindir}/ab-status
    install -m 0755 ${WORKDIR}/ab-commit ${D}${sbindir}/ab-commit
}

do_install:imx-generic-bsp() {
    install -d ${D}${sbindir}
    sed -e 's/@AB_UBOOT_A_SECTOR@/${AB_UBOOT_A_SECTOR}/' \
        -e 's/@AB_UBOOT_B_SECTOR@/${AB_UBOOT_B_SECTOR}/' \
        -e 's/@AB_UBOOT_AREA_SECTORS@/${AB_UBOOT_AREA_SECTORS}/' \
        -e 's/@AB_MCORE_MAGIC@/${AB_MCORE_MAGIC}/' \
        ${WORKDIR}/ab > ${D}${sbindir}/ab
    chmod 0755 ${D}${sbindir}/ab
    grep -q '@AB_' ${D}${sbindir}/ab && bbfatal "unresolved placeholder in ab (machine constants not set?)"
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/ab-spl-selfheal.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/ab-mcore-confirm.service ${D}${systemd_system_unitdir}/
    install -d ${D}${sysconfdir}
    printf '%s\t%s\t%s\n' /dev/mmcblk2 ${AB_UBOOT_ENV_OFFSET} ${AB_UBOOT_ENV_SIZE} > ${D}${sysconfdir}/fw_env.config
    if [ -n "${AB_UBOOT_ENV_OFFSET_REDUND}" ]; then
        printf '%s\t%s\t%s\n' /dev/mmcblk2 ${AB_UBOOT_ENV_OFFSET_REDUND} ${AB_UBOOT_ENV_SIZE} >> ${D}${sysconfdir}/fw_env.config
    fi
}

FILES:${PN} = "${sbindir}/ab-status ${sbindir}/ab-commit"
FILES:${PN}:imx-generic-bsp = " \
    ${sbindir}/ab \
    ${systemd_system_unitdir}/ab-spl-selfheal.service \
    ${systemd_system_unitdir}/ab-mcore-confirm.service \
    ${sysconfdir}/fw_env.config \
"
# i.MX 版は U-Boot env を fw_printenv/fw_setenv、SPL の判定に devmem/strings、
# M コアのファーム検証に gzip/hexdump を使う (いずれも busybox か libubootenv-bin)
RDEPENDS:${PN}:append:imx-generic-bsp = " libubootenv-bin"
# スクリプトの中身がマシンごとに異なるため
PACKAGE_ARCH = "${MACHINE_ARCH}"
COMPATIBLE_MACHINE = "(raspberrypi5|imx-generic-bsp)"
