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
    kart-data-mount \
    kart-systemd-tuning \
    kart-ssh-hostkeys \
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
# i.MX8M Mini specific packages (machine imx8mm-xpi)
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
    kart-ab-tools \
    libubootenv-bin \
    kart-edid-firmware \
    kart-udev-slim \
"

# udev ダイエット (mx8mm のみ、RPi5 は据え置き):
# 固定ハードのキオスクに無縁なルールと hwdb (10MB、キーボード/マウス量産品の
# 互換 quirk 集) を rootfs から落とす。coldplug 全デバイス × 全ルールの積が
# 縮み、kart-udev-slim の二段トリガーと合わせて GUI までの udev 区間を削る。
# 消してよい根拠 (このシステムに消費者がいない) は
# docs/imx8mm-xpi-bringup/05-next-steps.md の起動時間の項を参照。
slim_udev_rules() {
    for f in 60-autosuspend 60-block 60-cdrom_id 60-dmi-id 60-fido-id \
             60-infiniband 60-persistent-alsa 60-persistent-input \
             60-persistent-storage-mtd 60-persistent-storage-tape \
             60-persistent-storage 60-persistent-v4l 60-sensor 60-serial \
             64-btrfs 70-camera 70-joystick 70-memory 70-power-switch \
             75-probe_mtd 78-sound-card 90-alsa-restore 90-iocost; do
        rm -f ${IMAGE_ROOTFS}${nonarch_base_libdir}/udev/rules.d/$f.rules
    done
    rm -f ${IMAGE_ROOTFS}${nonarch_base_libdir}/udev/hwdb.bin
    rm -rf ${IMAGE_ROOTFS}${nonarch_base_libdir}/udev/hwdb.d
    # 乱数 seed を /data へ (kart-udev-slim の random-seed-credit.conf とペア。
    # coldplug 遅延でデバイス登録由来のエントロピーが減るため、seed credit で
    # CRNG を即時初期化しないと weston の EGL 初期化が getrandom() で止まる)
    ln -sf /data/random-seed ${IMAGE_ROOTFS}${localstatedir}/lib/systemd/random-seed
}
ROOTFS_POSTPROCESS_COMMAND:append:mx8mm-generic-bsp = " slim_udev_rules;"

# wic が rawcopy する seed 済み U-Boot env (A/B 変数入り)
KART_WIC_EXTRA_DEPENDS = ""
KART_WIC_EXTRA_DEPENDS:mx8mm-generic-bsp = "kart-uboot-env:do_deploy"
do_image_wic[depends] += "${KART_WIC_EXTRA_DEPENDS}"

# ---------------------------------------------------------------------------
# Image tweaks
# ---------------------------------------------------------------------------
IMAGE_FEATURES += "read-only-rootfs"
IMAGE_ROOTFS_EXTRA_SPACE = "0"

# Ensure systemd is used
IMAGE_INSTALL:append = " systemd-serialgetty"

ROOTFS_POSTPROCESS_COMMAND += "create_data_mount;order_timesyncd_after_network;mask_journal_catalog_update;netboot_mask_networkd;"

# ---------------------------------------------------------------------------
# netboot (NFS root) 専用: systemd-networkd スタックを丸ごと mask する。
# カーネルが ip= で上げた eth0 を networkd が掌握し直す際に一度落とすため、
# NFS root (= /) が読めなくなり boot が 16 秒地点で全停止する
# (docs/imx8mm-xpi-bringup/04-pitfalls.md 「16 秒の壁」)。
# ローカル root の実機イメージでは networkd が必要なので、
# kas/imx8mm-netboot.yml が KART_NETBOOT = "1" を立てたときだけ有効。
# mask (/dev/null への symlink) は systemd_preset_all が作る wants リンクより
# 優先されるので、ROOTFS_POSTPROCESS で入れて問題ない。
# ---------------------------------------------------------------------------
netboot_mask_networkd() {
    [ "${KART_NETBOOT}" = "1" ] || return 0
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    for unit in systemd-networkd.service systemd-networkd.socket \
                systemd-networkd-wait-online.service; do
        ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/$unit
    done
}

# ---------------------------------------------------------------------------
# Create /data mount point and fstab entry for persistent data partition
# ---------------------------------------------------------------------------
create_data_mount() {
    install -d ${IMAGE_ROOTFS}/data
    # /data のマウント自体は kart-data-mount レシピ (recipes-support/) の
    # systemd サービスが行う。fstab の LABEL=data 方式は udev の blkid
    # スキャン待ち (~1.3s) + fsck (+164ms) を伴うため廃止した。

    # /boot is mounted by kart-boot-mount.service (A/B: the active slot's boot
    # partition BOOTA/BOOTB is chosen from the kernel cmdline), not by fstab.
    install -d ${IMAGE_ROOTFS}/boot
    # /data 配下の tmpfiles 定義は kart-data-mount レシピが持つ
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

    # resolved にも同じ preset 再作成問題がある: (遅延起動 timer は
    # kart-systemd-tuning レシピが持つが) preset が作る
    # sysinit.target.wants リンクを systemd_preset_all が復活させ、resolved が
    # sysinit の critical path に居座る (i.MX 実測で +450ms、sysinit 到達を
    # ~0.5s 遅らせていた。resolved の遅延起動は timer が担うので wants は不要)
    rm -f ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/sysinit.target.wants/systemd-resolved.service
    rm -f ${IMAGE_ROOTFS}/usr/lib/systemd/system/sysinit.target.wants/systemd-resolved.service
}
IMAGE_PREPROCESS_COMMAND:append = " remove_timesyncd_sysinit_pull;"

mask_journal_catalog_update() {
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/systemd-journal-catalog-update.service
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
    # A/B レイアウト (…-ab.wks) のときだけ。シングルスロット構成
    # (imx8mm の SD 持ち込みイメージ等) に入れると BOOTA ラベルが無く
    # 起動時に必ず失敗ユニットになる。
    case "${WKS_FILE}" in
        *-ab.wks) ;;
        *) return ;;
    esac
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
# kart-boot-mount (cmdline の p5/p6 で BOOTA/BOOTB ラベルを選んでマウント) と
# watchdog 設定は RPi5 (tryboot) と i.MX (U-Boot bootcount) の両 A/B レイアウトで
# 共通に機能する — root=p5/p6・ラベル名を両レイアウトで揃えてあるため。
ROOTFS_POSTPROCESS_COMMAND:append:raspberrypi5 = " install_ab_boot_support;"
ROOTFS_POSTPROCESS_COMMAND:append:mx8mm-generic-bsp = " install_ab_boot_support;"

# Weston/Wayland configuration
REQUIRED_DISTRO_FEATURES = "wayland systemd"
