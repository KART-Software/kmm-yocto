# XPI (LT9611 位相安定化): 黒埋め広 DE モードでもクライアントをパネル実寸
# 800x480 のまま左上に置けるようにする kiosk-shell 拡張。
# weston.ini の [shell] client-size=800x480 で有効化 (未指定なら素の挙動)。
# mx8mm 限定 — RPi5 ビルドには一切影響しない。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:mx8mm-generic-bsp = " file://0001-kiosk-shell-client-size.patch"
