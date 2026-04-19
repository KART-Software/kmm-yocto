SUMMARY = "Kart product image for Raspberry Pi 5 / QEMU"
DESCRIPTION = "Custom Linux image with Wayland/Weston kiosk, PyQt6 GUI, \
CAN bus, GPIO, Tailscale, and NVMe boot support."
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
    iproute2 \
    libgpiod \
    libgpiod-tools \
    pciutils \
    usbutils \
    ethtool \
    kart-machine-manager \
    bash \
    less \
    systemd-analyze \
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

# ---------------------------------------------------------------------------
# Precompile Python bytecode (.pyc) at image build time
# ---------------------------------------------------------------------------
ROOTFS_POSTPROCESS_COMMAND += "compile_python_bytecode;mask_vconsole_setup;delay_timesyncd_start;mask_journal_catalog_update;delay_resolved_start;generate_ssh_host_keys;mask_unnecessary_services;"
compile_python_bytecode() {
    ${STAGING_BINDIR_NATIVE}/python3-native/python3 \
        -c "import compileall; compileall.compile_dir('${IMAGE_ROOTFS}/usr/lib/python3.12/', quiet=2, force=True)"
}

mask_vconsole_setup() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-vconsole-setup.service
}

delay_timesyncd_start() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timers.target.wants

    # Prevent timesyncd from delaying sysinit.
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-timesyncd.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-timesyncd.service

    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timesyncd-delayed-start.service << 'EOF'
[Unit]
Description=Delayed start of systemd-timesyncd

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'systemctl unmask systemd-timesyncd.service && systemctl start systemd-timesyncd.service'
EOF

    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timesyncd-delayed-start.timer << 'EOF'
[Unit]
Description=Delay systemd-timesyncd start until after boot

[Timer]
OnBootSec=10s
AccuracySec=1s
Unit=timesyncd-delayed-start.service

[Install]
WantedBy=timers.target
EOF

    ln -sf ../timesyncd-delayed-start.timer \
        ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timers.target.wants/timesyncd-delayed-start.timer
}

mask_journal_catalog_update() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-journal-catalog-update.service
}

delay_resolved_start() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timers.target.wants

    # Prevent resolved from delaying sysinit.
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-resolved.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-resolved.service

    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/resolved-delayed-start.service << 'EOF'
[Unit]
Description=Delayed start of systemd-resolved

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'systemctl unmask systemd-resolved.service && systemctl start systemd-resolved.service'
EOF

    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/resolved-delayed-start.timer << 'EOF'
[Unit]
Description=Delay systemd-resolved start until after boot

[Timer]
OnBootSec=10s
AccuracySec=1s
Unit=resolved-delayed-start.service

[Install]
WantedBy=timers.target
EOF

    ln -sf ../resolved-delayed-start.timer \
        ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timers.target.wants/resolved-delayed-start.timer
}

# ---------------------------------------------------------------------------
# Install pre-generated SSH host keys so sshdgenkeys.service is a no-op
# Note: All images share the same host keys. For per-device unique keys,
#       remove this and accept the ~2s first-boot cost.
# ---------------------------------------------------------------------------
generate_ssh_host_keys() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/ssh
    for keyfile in ssh_host_rsa_key ssh_host_ecdsa_key ssh_host_ed25519_key; do
        install -m 0600 ${THISDIR}/files/ssh-host-keys/${keyfile} \
            ${IMAGE_ROOTFS}${sysconfdir}/ssh/${keyfile}
        install -m 0644 ${THISDIR}/files/ssh-host-keys/${keyfile}.pub \
            ${IMAGE_ROOTFS}${sysconfdir}/ssh/${keyfile}.pub
    done
    # Mask the service so it doesn't even check at boot
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sshdgenkeys.service
}

# ---------------------------------------------------------------------------
# Mask services unnecessary for kiosk operation
# ---------------------------------------------------------------------------
mask_unnecessary_services() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system

    # avahi-daemon: mDNS/DNS-SD not needed for kiosk
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/avahi-daemon.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/avahi-daemon.socket

    # dnsmasq: DNS/DHCP server not needed for kiosk
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/dnsmasq.service

    # rpcbind: NFS RPC port mapper not needed
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/rpcbind.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/rpcbind.socket

    # busybox-klogd/syslog: redundant with systemd-journald
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/busybox-klogd.service
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/busybox-syslog.service
}

# Weston/Wayland configuration
REQUIRED_DISTRO_FEATURES = "wayland systemd"
