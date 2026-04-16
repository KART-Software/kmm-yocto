SUMMARY = "Kart product image for Raspberry Pi 5 / QEMU"
DESCRIPTION = "Custom Linux image with Wayland/Weston kiosk, PyQt6 GUI, \
CAN bus, GPIO, NetworkManager, Tailscale, and NVMe boot support."
LICENSE = "MIT"

inherit core-image

# ---------------------------------------------------------------------------
# Common packages (all machines)
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append = " \
    python3 \
    python3-pyqt6 \
    qtbase \
    qtwayland \
    qtdeclarative \
    weston \
    weston-init \
    seatd \
    wayland \
    dbus \
    openssh-sshd \
    openssh-sftp-server \
    networkmanager \
    iproute2 \
    libgpiod \
    libgpiod-tools \
    pciutils \
    usbutils \
    ethtool \
    kart-machine-manager \
    psplash \
    bash \
    less \
"

# ---------------------------------------------------------------------------
# Raspberry Pi 5 specific packages
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append:raspberrypi5 = " \
    tailscale \
    can-utils \
    can-setup \
    kernel-modules \
"

# ---------------------------------------------------------------------------
# Image tweaks
# ---------------------------------------------------------------------------
IMAGE_ROOTFS_EXTRA_SPACE = "0"

# Ensure systemd is used
IMAGE_INSTALL:append = " systemd-serialgetty"

# Weston/Wayland configuration
REQUIRED_DISTRO_FEATURES = "wayland systemd"
