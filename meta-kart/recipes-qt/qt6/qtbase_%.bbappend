# DEBIX (8MP): meta-freescale の qt6 dynamic-layer が DISTRO_FEATURES vulkan で
# qtbase に vulkan を有効化し、vulkan-loader → libvulkan-vsi1 (Vivante) が
# rootfs に入る。kmm は Qt Widgets (raster) で Vulkan を使わないため外す
# (2026-09-02 実機で vulkan ライブラリ無し動作を確認済み)。
PACKAGECONFIG:remove:imx8mp-debix = "vulkan"
