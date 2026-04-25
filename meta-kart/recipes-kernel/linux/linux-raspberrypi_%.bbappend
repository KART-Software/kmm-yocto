FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " \
    file://can.cfg \
    file://nvme.cfg \
    file://usb-net.cfg \
    file://slim.cfg \
"
