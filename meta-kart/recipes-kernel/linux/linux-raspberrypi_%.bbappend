FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://can.cfg \
    file://nvme.cfg \
    file://usb-net.cfg \
    file://slim.cfg \
    file://slim-aggressive.cfg \
    file://slim-modular.cfg \
"

# meta-raspberrypi が KERNEL_FEATURES で vfat.scc を足しており、これは
# SRC_URI の cfg fragment より後に適用されるため slim-modular.cfg の
# VFAT_FS=m が負ける。機能ごと外す (VFAT はモジュールとして残る)。
KERNEL_FEATURES:remove = "cfg/fs/vfat.scc"
