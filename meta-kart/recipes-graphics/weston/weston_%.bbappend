# XPI (LT9611 位相安定化): 黒埋め広 DE モードでもクライアントをパネル実寸
# 800x480 のまま左上に置けるようにする kiosk-shell 拡張。
# weston.ini の [shell] client-size=800x480 で有効化 (未指定なら素の挙動)。
# mx8mm 限定 — RPi5 ビルドには一切影響しない。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:mx8mm-generic-bsp = " file://0001-kiosk-shell-client-size.patch"

# DEBIX (8MP): NXP 版 weston は imxgpu2d で G2D レンダラを組み込み、
# libweston-12 が imx-gpu-g2d (→ libg2d-viv/libopencl-imx) を hard RDEPENDS する。
# 本構成は pixman 合成 (weston-debix.ini) で G2D を使わないため外す —
# GPU コンピュート系 (OpenCL/g2d) が rootfs から消える (2026-09-02 実測で
# pixman 動作に不要と確認済み)。
PACKAGECONFIG_G2D:imx8mp-debix = ""
