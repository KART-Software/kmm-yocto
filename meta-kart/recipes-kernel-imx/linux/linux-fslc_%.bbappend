# i.MX 向け mainline 系カーネル (IMX_DEFAULT_BSP=mainline のデフォルト)。
#
# - can.cfg: MCP2515 は i.MX でも SPI 接続で使い続けるため RPi5 と共通の fragment
# - imx8mm-evk-kart.dts: MCP2515 ノード入りの EVK バリアント DTB。
#   ソースツリーに複製して KERNEL_DEVICETREE に足すだけでよい
#   (kbuild のパターンルールが dts からビルドするので Makefile パッチは不要)。
#   ブートパーティションへの配置と U-Boot からの選択は kas/imx8mm.yml の
#   IMAGE_BOOT_FILES が行う。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://can.cfg \
    file://imx8mm-evk-kart.dts \
    file://display.cfg \
    file://slim-imx-arch.cfg \
    file://slim-imx.cfg \
"

# 注意: meta-freescale は machine-overrides-extender で MACHINEOVERRIDES を
# BSP 種別付きに変換する。素の "mx8mm" は OVERRIDES に存在せず、silently
# 無視される (append は変数履歴に載るのに値へ反映されない)。BSP 非依存で
# 効かせるトークンは "mx8mm-generic-bsp"。
KERNEL_DEVICETREE:append:mx8mm-generic-bsp = " freescale/imx8mm-evk-kart.dtb"

do_configure:prepend() {
    cp ${WORKDIR}/imx8mm-evk-kart.dts ${S}/arch/arm64/boot/dts/freescale/
}
