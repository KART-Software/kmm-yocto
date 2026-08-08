FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://can.cfg \
    file://nvme.cfg \
    file://usb-net.cfg \
    file://slim.cfg \
    file://slim-aggressive.cfg \
    file://slim-modular.cfg \
"

# poky の linux-yocto.inc が「MACHINE_FEATURES に vfat がある machine には
# cfg/fs/vfat.scc (VFAT_FS=y + NLS) を自動追加する」仕掛けを持ち、
# raspberrypi5 の machine 定義 (meta-raspberrypi) が vfat を宣言しているため
# 発動する。KERNEL_FEATURES は SRC_URI の cfg fragment より後に適用されるので
# slim-modular.cfg の VFAT_FS=m が黙って負ける。機能ごと外す
# (VFAT は =m で残り、/boot マウント時に自動ロードされる)。
KERNEL_FEATURES:remove = "cfg/fs/vfat.scc"
