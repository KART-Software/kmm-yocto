# NXP BSP 系カーネル (IMX_DEFAULT_BSP=nxp を選んだ場合用)。
# 内容は linux-fslc_%.bbappend と同一 — 説明はそちらを参照。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://can.cfg \
    file://imx8mm-evk-kart.dts \
    file://imx8mm-xpi-kart.dts \
    file://display.cfg \
    file://slim-imx-arch.cfg \
    file://slim-imx.cfg \
    file://watchdog.cfg \
    file://pinctrl-gpio.cfg \
    file://0001-drm-mxsfb-attach-bridge-with-NO_CONNECTOR.patch \
    file://0002-drm-lontium-lt9611-dsi-lanes-from-dt.patch \
    file://0003-drm-lontium-lt9611-reduce-enable-settle-delay.patch \
"

KERNEL_DEVICETREE:append:mx8mm-generic-bsp = " freescale/imx8mm-evk-kart.dtb freescale/imx8mm-xpi-kart.dtb"

do_configure:prepend() {
    cp ${WORKDIR}/imx8mm-evk-kart.dts ${WORKDIR}/imx8mm-xpi-kart.dts ${S}/arch/arm64/boot/dts/freescale/
}
