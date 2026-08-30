# i.MX のみ: kart-uboot-try/commit/status が PERSIST_SECONDARY_BOOT
# (SRC_GPR10) を操作するのに devmem を使う。poky の busybox defconfig は
# CONFIG_DEVMEM を無効にしているため fragment で有効化する。
# i.MX 全機種共通 (imx-generic-bsp)。RPi5 / QEMU ビルドには何も追加しない。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:imx-generic-bsp = " file://devmem.cfg"
