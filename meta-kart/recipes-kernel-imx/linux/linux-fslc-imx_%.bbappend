# NXP BSP 系カーネル (IMX_DEFAULT_BSP=nxp を選んだ場合用)。
# 内容は linux-fslc_%.bbappend と同一 — 説明はそちらを参照。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://can.cfg \
    file://imx8mm-evk-kart.dts \
    file://display.cfg \
"

KERNEL_DEVICETREE:append:mx8mm-generic-bsp = " freescale/imx8mm-evk-kart.dtb"

do_configure:prepend() {
    cp ${WORKDIR}/imx8mm-evk-kart.dts ${S}/arch/arm64/boot/dts/freescale/
}
