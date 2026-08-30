# NXP 系 U-Boot (8MP/DEBIX。8MM は mainline 系 u-boot-fslc — 隣の bbappend)。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# 既定ロードの DTB を EVK (imx8mp-evk.dtb) から DEBIX 実配線版へ。
# boot パーティションには両方入っている (machine conf の KERNEL_DEVICETREE) ので、
# U-Boot プロンプトから fdtfile を差し替えれば EVK 素 DTB でも起動できる。
#
# DDR: EVK の lpddr4_timing.c (4000MTS, EVK 実装 6GB) は DEBIX Infinity の
# Micron MT53E1G32D2NP (DRAM ID 0xff070018 = ベンダー呼称 D8BJG, 4GB) で
# training FAILED になる (シリアル実測 2026-08-28)。debix-lpddr4_timing.c は
# debix-tech 公開 U-Boot (https://github.com/debix-tech/uboot-nxp-debix) の
# Model A 3732MTS 表に、16Gb ダイの密度由来レジスタ (tRFC 系・ADDRMAP7) を
# 移植した単一表 (ファイル先頭のコメント参照)。サイズは 0001 パッチで
# 6GB→4GB (3GB+1GB、ベンダーの board_phys_sdram_size と同じ割り付け)。
SRC_URI:append:imx8mp-debix = " \
    file://debix.cfg \
    file://debix-ab.cfg \
    file://debix-lpddr4_timing.c \
    file://0001-imx8mp-debix-4gb-dram-size.patch \
"

do_configure:prepend:imx8mp-debix() {
    cp ${WORKDIR}/debix-lpddr4_timing.c ${S}/board/freescale/imx8mp_evk/lpddr4_timing.c
}

# extlinux の root= の差し替え口 (8MM の u-boot-fslc_%.bbappend と同じ理由で
# 間接変数にする)。kas/imx-emmc-ab.yml が KART_EXTLINUX_ROOT を設定する。
# NXP BSP の machine include は extlinux 変数を use-mainline-bsp 限定で定義するため、
# 8MP 用は imx8mp-debix.conf で定義し、root だけここで張る。
KART_EXTLINUX_ROOT ??= "root=/dev/mmcblk2p2"
UBOOT_EXTLINUX_ROOT:default:imx8mp-debix = "${KART_EXTLINUX_ROOT}"
