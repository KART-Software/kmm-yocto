#!/bin/sh
# target-stage-setup.sh — 実ブート 3 stage 計測のための「実験モード」を
# ボードに入れる/戻す (全て可逆)。
#
#   ./target-stage-setup.sh install   [root@host]
#   ./target-stage-setup.sh uninstall [root@host]
#
# install が行うこと:
#  1. p1 (BOOTA) の logo.bin を bootloader パターンの LOGO に交換 (原本は logo.bin.orig)
#     → SPL スプラッシュが bootloader パターンを表示する。SPL は A/B の面に関係なく
#       p1 から読むので、/boot が p2 (b 面で稼働中) なら p1 を一時マウントして書く
#  2. wl-image-view を /usr/bin へ、weston/gui パターン raw を /etc/lcdval へ
#  3. splash-wl.service を drop-in で wl-image-view (weston パターン) に差し替え
#  4. kmm.service を drop-in で wl-image-view (gui パターン) に差し替え
#     (Type=notify → simple。GUI アプリの代わりにパターンが出る)
#
# uninstall は上記を全て戻す。ボード側は busybox 前提 (POSIX 構文のみ)。
set -eu

MODE=${1:?install|uninstall}
BOARD=${2:-root@192.168.0.7}
HERE=$(cd "$(dirname "$0")" && pwd)
DEPLOY=$HERE/../../build/tmp/deploy/images/imx8mp-debix

case "$MODE" in
install)
    # パターン素材を生成 (無ければ)
    for f in out/bootloader.logo out/weston.raw out/gui.raw; do
        [ -f "$HERE/$f" ] || {
            echo "素材が無い: $f — generate_pattern.py で生成してから" >&2
            exit 1
        }
    done
    scp -O "$DEPLOY/wl-image-view" "$HERE/out/bootloader.logo" \
        "$HERE/out/weston.raw" "$HERE/out/gui.raw" "$BOARD:/tmp/" >/dev/null

    ssh "$BOARD" '
set -e
mount -o remount,rw /
mkdir -p /etc/lcdval
cp /tmp/wl-image-view /usr/bin/wl-image-view && chmod 755 /usr/bin/wl-image-view
cp /tmp/weston.raw /tmp/gui.raw /etc/lcdval/

mkdir -p /etc/systemd/system/splash-wl.service.d
printf "[Service]\nExecStart=\nExecStart=/usr/bin/wl-image-view /etc/lcdval/weston.raw\n" \
    > /etc/systemd/system/splash-wl.service.d/lcdval.conf
mkdir -p /etc/systemd/system/kmm.service.d
printf "[Service]\nType=simple\nExecStart=\nExecStart=/usr/bin/wl-image-view /etc/lcdval/gui.raw\n" \
    > /etc/systemd/system/kmm.service.d/lcdval.conf
systemctl daemon-reload

p1=/dev/mmcblk2p1
if grep -q "^$p1 /boot " /proc/mounts; then
    d=/boot; mount -o remount,rw /boot
else
    d=/run/lcdval-p1; mkdir -p $d; mount -t vfat $p1 $d
fi
[ -f $d/logo.bin.orig ] || cp $d/logo.bin $d/logo.bin.orig
cp /tmp/bootloader.logo $d/logo.bin
sync
if [ "$d" = /boot ]; then mount -o remount,ro /boot; else umount $d; rmdir $d; fi
mount -o remount,ro /
echo "experiment mode: INSTALLED"'
    ;;
uninstall)
    ssh "$BOARD" '
set -e
mount -o remount,rw /
rm -f /etc/systemd/system/splash-wl.service.d/lcdval.conf
rm -f /etc/systemd/system/kmm.service.d/lcdval.conf
rmdir /etc/systemd/system/splash-wl.service.d 2>/dev/null || true
rmdir /etc/systemd/system/kmm.service.d 2>/dev/null || true
rm -rf /etc/lcdval /usr/bin/wl-image-view
systemctl daemon-reload

p1=/dev/mmcblk2p1
if grep -q "^$p1 /boot " /proc/mounts; then
    d=/boot; mount -o remount,rw /boot
else
    d=/run/lcdval-p1; mkdir -p $d; mount -t vfat $p1 $d
fi
if [ -f $d/logo.bin.orig ]; then
    cp $d/logo.bin.orig $d/logo.bin
    rm $d/logo.bin.orig
fi
sync
if [ "$d" = /boot ]; then mount -o remount,ro /boot; else umount $d; rmdir $d; fi
mount -o remount,ro /
echo "experiment mode: UNINSTALLED"'
    ;;
*)
    echo "usage: $0 install|uninstall [root@host]" >&2
    exit 2
    ;;
esac
