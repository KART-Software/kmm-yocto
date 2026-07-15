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
    tailscale \
"

# ---------------------------------------------------------------------------
# Raspberry Pi 5 specific packages
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append:raspberrypi5 = " \
    can-utils \
    can-setup \
    kernel-modules \
"

# ---------------------------------------------------------------------------
# QEMU specific packages
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append:qemuarm64 = " \
    kernel-modules \
"

# ---------------------------------------------------------------------------
# Image tweaks
# ---------------------------------------------------------------------------
IMAGE_FEATURES += "read-only-rootfs"
IMAGE_ROOTFS_EXTRA_SPACE = "0"

# Ensure systemd is used
IMAGE_INSTALL:append = " systemd-serialgetty"

# ---------------------------------------------------------------------------
# Precompile Python bytecode (.pyc) at image build time
# ---------------------------------------------------------------------------
ROOTFS_POSTPROCESS_COMMAND += "compile_python_bytecode;create_data_mount;delay_timesyncd_start;mask_journal_catalog_update;delay_resolved_start;generate_ssh_host_keys;configure_wait_online_any;"

# ---------------------------------------------------------------------------
# Create /data mount point and fstab entry for persistent data partition
# ---------------------------------------------------------------------------
create_data_mount() {
    install -d ${IMAGE_ROOTFS}/data
    echo "LABEL=data  /data  ext4  defaults,nofail  0  2" >> ${IMAGE_ROOTFS}${sysconfdir}/fstab

    # /boot is required by systemd local-fs.target; use LABEL for portability
    # across SD (mmcblk0p1) and NVMe (nvme0n1p1).
    install -d ${IMAGE_ROOTFS}/boot
    echo "LABEL=boot  /boot  vfat  defaults,nofail  0  2" >> ${IMAGE_ROOTFS}${sysconfdir}/fstab

    # Ensure /data and /data/log are world-writable at every boot
    install -d ${IMAGE_ROOTFS}${sysconfdir}/tmpfiles.d
    cat > ${IMAGE_ROOTFS}${sysconfdir}/tmpfiles.d/data-partition.conf << 'EOF'
d /data           0777 root root -
d /data/log       0777 root root -
d /data/tailscale 0700 root root -
EOF
}

compile_python_bytecode() {
    ${STAGING_BINDIR_NATIVE}/python3-native/python3 \
        -c "import compileall; compileall.compile_dir('${IMAGE_ROOTFS}/usr/lib/python3.12/', quiet=2, force=True)"
}

delay_timesyncd_start() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timers.target.wants

    # Prevent timesyncd from delaying sysinit (remove wants link only, no mask).
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-timesyncd.service

    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timesyncd-delayed-start.service << 'EOF'
[Unit]
Description=Delayed start of systemd-timesyncd

[Service]
Type=oneshot
ExecStart=/bin/systemctl start systemd-timesyncd.service
EOF

    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/timesyncd-delayed-start.timer << 'EOF'
[Unit]
Description=Delay systemd-timesyncd start until after GUI
After=kmm-start.service

[Timer]
OnActiveSec=500ms
AccuracySec=1ms
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

    # Prevent resolved from delaying sysinit (remove wants link only, no mask).
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-resolved.service

    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/resolved-delayed-start.service << 'EOF'
[Unit]
Description=Delayed start of systemd-resolved

[Service]
Type=oneshot
ExecStart=/bin/systemctl start systemd-resolved.service
EOF

    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/resolved-delayed-start.timer << 'EOF'
[Unit]
Description=Delay systemd-resolved start until after GUI
After=kmm-start.service

[Timer]
OnActiveSec=500ms
AccuracySec=1ms
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
# Reach network-online.target as soon as ANY interface is online.
# Default systemd-networkd-wait-online waits for ALL managed links; a
# disconnected onboard eth0 (no carrier) then blocks boot for the full ~120s
# timeout even when eth1/LTE is already up. --any returns once one link is up.
# ---------------------------------------------------------------------------
configure_wait_online_any() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-networkd-wait-online.service.d
    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-networkd-wait-online.service.d/any.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/lib/systemd/systemd-networkd-wait-online --any
EOF
}

# Weston/Wayland configuration
REQUIRED_DISTRO_FEATURES = "wayland systemd"
