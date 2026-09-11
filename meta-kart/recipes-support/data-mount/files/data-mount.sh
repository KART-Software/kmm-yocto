#!/bin/sh
# /data (永続パーティション) を udev を待たずにマウントする。
# cmdline の root=/dev/XXXp5|p6 (A/B スロット) から基底デバイスを導出し、
# 同デバイスの p7 を直接マウント (devtmpfs のノードはカーネル認識直後から
# 存在する)。A/B レイアウトでない場合 (QEMU 等) は何もせず成功する。
# fsck は行わない (ext4 ジャーナルが電源断を担保)。
base=$(sed -n 's|.*root=\(/dev/[a-z0-9]*\)p[56].*|\1|p' /proc/cmdline)
if [ -n "$base" ]; then
    exec mount -t ext4 "${base}p7" /data
fi
exit 0
