# NXP BSP 系カーネル (IMX_DEFAULT_BSP=nxp を選んだ場合用)。
# 内容は linux-fslc_%.bbappend と同一 — 説明はそちらを参照。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# 以下の cfg/dts/patch は全て 8MM (XPI) 固有 — mx8mm-generic-bsp でガードする。
# 無条件 SRC_URI だと 8MP (DEBIX) ビルドにスリム化 cfg が混入し、NXP カーネルの
# virtio_video が XEN 削除の巻き添えでリンク不能になる (2026-08-26 実測。
# pitfalls #15 の select 崩壊と同族)。8MP 用の cfg は別途起こす。

# バージョン文字列の決定論化。理由は linux-fslc_%.bbappend の同名変数コメント参照
# (fsl-kernel-localversion の SCMVERSION="y" が AUTO を強制し kernel/module の
# vermagic を食い違わせる)。
SCMVERSION = "n"
LOCALVERSION = ""
LINUX_VERSION_EXTENSION = "-fslc"

SRC_URI:append:mx8mm-generic-bsp = " \
    file://can.cfg \
    file://imx8mm-evk-bench.dts \
    file://imx8mm-xpi.dts \
    file://display.cfg \
    file://slim-imx-arch.cfg \
    file://slim-imx.cfg \
    file://watchdog.cfg \
    file://pinctrl-gpio.cfg \
    file://m4-remoteproc.cfg \
    file://localversion.cfg \
    file://module-force-load.cfg \
    file://0001-drm-mxsfb-attach-bridge-with-NO_CONNECTOR.patch \
    file://0002-drm-lontium-lt9611-dsi-lanes-from-dt.patch \
    file://0003-drm-lontium-lt9611-reduce-enable-settle-delay.patch \
"

KERNEL_DEVICETREE:append:mx8mm-generic-bsp = " freescale/imx8mm-evk-bench.dtb freescale/imx8mm-xpi.dtb"

do_configure:prepend:mx8mm-generic-bsp() {
    cp ${WORKDIR}/imx8mm-evk-bench.dts ${WORKDIR}/imx8mm-xpi.dts ${S}/arch/arm64/boot/dts/freescale/
}

# ===== 8MP (DEBIX Infinity, machine imx8mp-debix) =====
# DTS の差分根拠は docs/imx8mp-debix-bringup/02-dts-delta.md。
# KERNEL_DEVICETREE への追加は machine conf (imx8mp-debix.conf) 側で行う。
SRC_URI:append:imx8mp-debix = " \
    file://imx8mp-debix.dts \
    file://imx8mp-debix-m7.dts \
    file://imx8mp-debix-lvds.dtsi \
    file://imx8mp-debix-hdmi.dtsi \
    file://edid-firmware.cfg \
    file://can-builtin.cfg \
    file://slim-imx8mp.cfg \
    file://boottune-imx8mp.cfg \
    file://0014-drm-imx-imx8mp-ldb-keep-panel-pixel-clock.patch \
"

do_configure:prepend:imx8mp-debix() {
    cp ${WORKDIR}/imx8mp-debix.dts ${WORKDIR}/imx8mp-debix-m7.dts \
       ${WORKDIR}/imx8mp-debix-lvds.dtsi ${WORKDIR}/imx8mp-debix-hdmi.dtsi \
       ${S}/arch/arm64/boot/dts/freescale/
    # 表示 (machine conf の DEBIX_DISPLAY) の DTS を、imx8mp-debix.dts が include する名前で選ぶ。
    # DTB の名前は表示によらず同じ (falcon.itb・extlinux・M7 版の DTS はそのまま)
    case "${DEBIX_DISPLAY}" in
    lvds|hdmi) ;;
    *) bbfatal "DEBIX_DISPLAY は lvds か hdmi (今は '${DEBIX_DISPLAY}')" ;;
    esac
    echo '#include "imx8mp-debix-${DEBIX_DISPLAY}.dtsi"' \
        > ${S}/arch/arm64/boot/dts/freescale/imx8mp-debix-display.dtsi
}
