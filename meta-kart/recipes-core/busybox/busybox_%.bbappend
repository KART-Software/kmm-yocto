# i.MX のみ: kart-uboot-try/commit/status が PERSIST_SECONDARY_BOOT
# (SRC_GPR10) を操作するのに devmem を使う。poky の busybox defconfig は
# CONFIG_DEVMEM を無効にしているため fragment で有効化する。
# RPi5 / QEMU ビルドには何も追加しない (append がオーバーライドで空)。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:mx8mm-generic-bsp = " file://devmem.cfg"
