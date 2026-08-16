# i.MX 向け mainline 系カーネル (IMX_DEFAULT_BSP=mainline のデフォルト)。
#
# - can.cfg: MCP2515 は i.MX でも SPI 接続で使い続けるため RPi5 と共通の fragment
# - imx8mm-evk-kart.dts: MCP2515 ノード入りの EVK バリアント DTB。
#   ソースツリーに複製して KERNEL_DEVICETREE に足すだけでよい
#   (kbuild のパターンルールが dts からビルドするので Makefile パッチは不要)。
#   ブートパーティションへの配置と U-Boot からの選択は kas/imx8mm.yml の
#   IMAGE_BOOT_FILES が行う。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# カーネルバージョン文字列を決定論化 (localversion.cfg と対で効かせる)。
# fsl-kernel-localversion.bbclass は SCMVERSION="y" のとき do_kernel_localversion
# で「git ハッシュ入りの .scmversion 書き込み + CONFIG_LOCALVERSION_AUTO=y の
# 強制再追加」を do_kernel_configme の後に行う。これがあると (a) fragment で
# 切った AUTO が毎回書き戻され (b) カーネル Image は fslc 二重 + git ハッシュ、
# out-of-tree モジュールは fslc 単一と、同一ビルド内でも vermagic が食い違い、
# kart-rpmsg-can が modprobe できない。SCMVERSION="n" でこのブロックごと無効化し、
# バージョンを CONFIG_LOCALVERSION の "-fslc" だけ = "6.12.20-fslc" に固定する。
SCMVERSION = "n"

# レシピの LOCALVERSION="-fslc" は make の LOCALVERSION env に渡り、
# CONFIG_LOCALVERSION="-fslc" と二重に付いて Image が "6.12.20-fslc-fslc"、
# out-of-tree モジュールは utsrelease.h 由来で "6.12.20-fslc" となり食い違う。
# make env 側を空にし、CONFIG_LOCALVERSION は LINUX_VERSION_EXTENSION で
# 明示保持する → 両者 "6.12.20-fslc" に一致する。
LOCALVERSION = ""
LINUX_VERSION_EXTENSION = "-fslc"

SRC_URI += " \
    file://can.cfg \
    file://imx8mm-evk-kart.dts \
    file://imx8mm-xpi-kart.dts \
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

# 注意: meta-freescale は machine-overrides-extender で MACHINEOVERRIDES を
# BSP 種別付きに変換する。素の "mx8mm" は OVERRIDES に存在せず、silently
# 無視される (append は変数履歴に載るのに値へ反映されない)。BSP 非依存で
# 効かせるトークンは "mx8mm-generic-bsp"。
KERNEL_DEVICETREE:append:mx8mm-generic-bsp = " freescale/imx8mm-evk-kart.dtb freescale/imx8mm-xpi-kart.dtb"

do_configure:prepend() {
    cp ${WORKDIR}/imx8mm-evk-kart.dts ${WORKDIR}/imx8mm-xpi-kart.dts ${S}/arch/arm64/boot/dts/freescale/
}
