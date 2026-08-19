# ATF (bl31) の RDC 設定に M4 用のペリフェラルを追加する。
#
# 既定の imx8mm_bl31_setup.c の rdc[] は M4 (domain1) に UART4 しか
# 割り当てていない。M4 が権限外の ECSPI2/GPIO を read すると RDC が弾いて
# SoC がハードリセットする (docs/imx8mm-xpi-bringup/04-pitfalls.md #26)。
# ここで ECSPI2/GPIO3/GPIO5 を両ドメイン RW に足すと、M4 の rpmsg + CAN/SPI
# 同居が成立する。RDC はブート最初期に ATF が確定 → CSU でロックするため、
# Linux 実行時の devmem では変更できず、ATF に埋め込むのが唯一の正解。
#
# 対象を増やすときはこのパッチの rdc[] に RDC_PDAPn を足す (GPIO はバンク単位)。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:mx8mm-generic-bsp = " file://0001-rdc-grant-m4-ecspi2-gpio.patch"
