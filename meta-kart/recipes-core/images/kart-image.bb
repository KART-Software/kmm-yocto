SUMMARY = "Kart product image for Raspberry Pi 5 / QEMU"
DESCRIPTION = "Custom Linux image with Wayland/Weston kiosk, C++/Qt6 GUI, \
CAN bus, GPIO, Tailscale, and NVMe boot support."
LICENSE = "MIT"

inherit core-image

# ---------------------------------------------------------------------------
# Common packages (all machines)
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append = " \
    qtbase \
    qtwayland \
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
    rpi-eeprom \
    raspi-utils \
    kart-eeprom-setup \
    kart-ab-tools \
"

# ---------------------------------------------------------------------------
# QEMU specific packages
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append:qemuarm64 = " \
    kernel-modules \
"

# ---------------------------------------------------------------------------
# i.MX8M Mini specific packages (imx8mm-lpddr4-evk scaffold)
# CAN は SoC 非内蔵のため RPi5 と同じく MCP2515 (SPI) を使う。
# rpi-eeprom / kart-ab-tools / kart-eeprom-setup は RPi 専用なので含めない。
# オーバーライドは素の mx8mm ではなく mx8mm-generic-bsp であること
# (meta-freescale の machine-overrides-extender が変換する。素の mx8mm は
# OVERRIDES に無く、append が黙って捨てられる)。
# 詳細は docs/imx8mm-migration-design.md。
# ---------------------------------------------------------------------------
IMAGE_INSTALL:append:mx8mm-generic-bsp = " \
    can-utils \
    can-setup \
    kernel-modules \
"

# ---------------------------------------------------------------------------
# Image tweaks
# ---------------------------------------------------------------------------
IMAGE_FEATURES += "read-only-rootfs"
IMAGE_ROOTFS_EXTRA_SPACE = "0"

# Ensure systemd is used
IMAGE_INSTALL:append = " systemd-serialgetty"

ROOTFS_POSTPROCESS_COMMAND += "create_data_mount;order_timesyncd_after_network;mask_journal_catalog_update;delay_resolved_start;generate_ssh_host_keys;configure_wait_online_any;"

# ---------------------------------------------------------------------------
# Create /data mount point and fstab entry for persistent data partition
# ---------------------------------------------------------------------------
create_data_mount() {
    install -d ${IMAGE_ROOTFS}/data
    echo "LABEL=data  /data  ext4  defaults,nofail  0  2" >> ${IMAGE_ROOTFS}${sysconfdir}/fstab

    # /boot is mounted by kart-boot-mount.service (A/B: the active slot's boot
    # partition BOOTA/BOOTB is chosen from the kernel cmdline), not by fstab.
    install -d ${IMAGE_ROOTFS}/boot

    # Ensure /data and /data/log are world-writable at every boot
    install -d ${IMAGE_ROOTFS}${sysconfdir}/tmpfiles.d
    cat > ${IMAGE_ROOTFS}${sysconfdir}/tmpfiles.d/data-partition.conf << 'EOF'
d /data           0777 root root -
d /data/log       0777 root root -
d /data/tailscale 0700 root root -
EOF
}

# ---------------------------------------------------------------------------
# RTC-less board: order systemd-timesyncd after network-online so its first NTP
# query has connectivity. By default timesyncd starts very early
# (Before=sysinit.target); with no network yet it fails and then waits a full
# ~32s poll before retrying, leaving the clock at the build epoch (~2025) and
# breaking TLS (e.g. tailscale control cert "not yet valid") for ~40s.
# Clearing Before= also keeps timesyncd off the sysinit critical path.
# ---------------------------------------------------------------------------
order_timesyncd_after_network() {
    # Move timesyncd's activation from sysinit.target (early, pre-network) to
    # network-online.target so its first NTP query has connectivity and syncs in
    # a few seconds.
    #
    # The upstream unit has Before=sysinit.target; adding After=network-online
    # on top of that creates an ordering cycle (sysinit -> ... -> network-pre ->
    # iptables -> basic -> sysinit) and systemd deletes timesyncd's job to break
    # it (verified via journal on target). systemd drop-ins CANNOT reset
    # dependency lists ("Before=" empty assignment is a no-op — same lesson as
    # weston-init.bbappend), so edit the shipped unit in place instead.
    sed -i '/^Before=/s/ *sysinit\.target//' \
        ${IMAGE_ROOTFS}/usr/lib/systemd/system/systemd-timesyncd.service

    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-timesyncd.service
    rm -f ${IMAGE_ROOTFS}/usr/lib/systemd/system/sysinit.target.wants/systemd-timesyncd.service

    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/network-online.target.wants
    ln -sf /usr/lib/systemd/system/systemd-timesyncd.service \
        ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/network-online.target.wants/systemd-timesyncd.service

    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-timesyncd.service.d
    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-timesyncd.service.d/after-network.conf << 'EOF'
[Unit]
After=network-online.target
Wants=network-online.target
EOF
}

# The sysinit.target.wants symlink removed above gets recreated by
# systemd_preset_all, which image.bbclass :append's to IMAGE_PREPROCESS_COMMAND
# (runs during do_image, after every ROOTFS_POSTPROCESS hook). The surviving
# link forms an ordering cycle at boot:
#   iptables -> basic -> sysinit -> timesyncd -> network-online -> networkd
#   -> network-pre -> iptables  (systemd then skips units to break it)
# Use :append here too: recipe appends are parsed after the class ones, so this
# runs after systemd_preset_all and the removal finally sticks.
remove_timesyncd_sysinit_pull() {
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-timesyncd.service
    rm -f ${IMAGE_ROOTFS}/usr/lib/systemd/system/sysinit.target.wants/systemd-timesyncd.service
}
IMAGE_PREPROCESS_COMMAND:append = " remove_timesyncd_sysinit_pull;"

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
# kmm.service is Type=notify and reports READY on first window expose,
# so "kmm active" really means the GUI is on screen.
After=kmm.service

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

# ---------------------------------------------------------------------------
# A/B (tryboot) support
# ---------------------------------------------------------------------------
# Slot selector: a tiny FAT image holding only autoboot.txt; the *-ab.wks
# layouts rawcopy it into partition 1. boot_partition 2 = slot A (BOOTA),
# 3 = slot B (BOOTB). `reboot '0 tryboot'` boots the [tryboot] section once;
# kart-ab-commit makes it permanent by swapping the two sections.
do_image_wic[depends] += "dosfstools-native:do_populate_sysroot mtools-native:do_populate_sysroot"

generate_autoboot_image() {
    # RPi5 tryboot 専用のスロットセレクタ。他マシン (qemu / imx8mm) の wic は
    # autoboot.vfat を参照しないので生成しない。
    if [ "${MACHINE}" != "raspberrypi5" ]; then
        return
    fi
    cat > ${WORKDIR}/autoboot.txt << 'EOF'
[all]
tryboot_a_b=1
boot_partition=2
[tryboot]
boot_partition=3
EOF
    rm -f ${DEPLOY_DIR_IMAGE}/autoboot.vfat
    dd if=/dev/zero of=${DEPLOY_DIR_IMAGE}/autoboot.vfat bs=1024 count=1024
    mkfs.vfat -n AUTOBOOT ${DEPLOY_DIR_IMAGE}/autoboot.vfat
    mcopy -i ${DEPLOY_DIR_IMAGE}/autoboot.vfat ${WORKDIR}/autoboot.txt ::autoboot.txt
}
do_image_wic[prefuncs] += "generate_autoboot_image"

# Mount the ACTIVE slot's boot partition on /boot (cmdline root=...p5 -> BOOTA,
# p6 -> BOOTB). fstab cannot express "the active slot", hence a oneshot unit.
# Also enable the hardware watchdog so a hung tryboot kernel resets the board
# and the firmware falls back to the previous slot.
install_ab_boot_support() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/kart-boot-mount.service << 'EOF'
[Unit]
Description=Mount active A/B boot partition on /boot
# tailscale-autoconnect reads /boot/tailscale.authkey
Before=tailscale-autoconnect.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'if grep -q "root=[^ ]*p6" /proc/cmdline; then L=BOOTB; else L=BOOTA; fi; mount LABEL=$L /boot'
ExecStop=/bin/umount /boot

[Install]
WantedBy=multi-user.target
EOF
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/multi-user.target.wants
    ln -sf ../kart-boot-mount.service \
        ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/multi-user.target.wants/kart-boot-mount.service

    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system.conf.d
    cat > ${IMAGE_ROOTFS}${sysconfdir}/systemd/system.conf.d/10-watchdog.conf << 'EOF'
[Manager]
RuntimeWatchdogSec=15
RebootWatchdogSec=60
EOF
}
# tryboot ベースの A/B は RPi5 専用 (kart-boot-mount は BOOTA/BOOTB ラベルと
# cmdline の p5/p6 判定に依存)。i.MX では U-Boot bootcount で作り直す予定。
ROOTFS_POSTPROCESS_COMMAND:append:raspberrypi5 = " install_ab_boot_support;"

# Weston/Wayland configuration
REQUIRED_DISTRO_FEATURES = "wayland systemd"
