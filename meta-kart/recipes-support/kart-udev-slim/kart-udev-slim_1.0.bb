SUMMARY = "Boot-time entropy seeding for the udev-slimmed image"
DESCRIPTION = "systemd-random-seed に SYSTEMD_RANDOM_SEED_CREDIT=1 を与え、\
/data の seed で CRNG を即時初期化する。udev ルール/hwdb の削減は \
kart-image.bb の slim_udev_rules が行う。\
経緯: 二段 coldplug (GUI クリティカルなサブシステム先行) も実測したが、\
GUI 短縮は誤差程度 (-46ms) でばらつきが 10 倍になり、モジュールドライバとの \
デッドロック事故 (docs/imx8mm-xpi-bringup/04-pitfalls.md #21) も踏んだため撤収。\
ルール削減 + seed credit + CAN ビルトイン化だけを残した。"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://random-seed-credit.conf \
    file://logind-defer.conf \
    file://dbus-defer.conf \
    file://cpu-weight-gui.conf \
    file://cpu-weight-noise.conf \
    file://noise-defer.conf \
"

# 起動時 CPU 配分: GUI チェーンを優遇し、ノイズ系を絞る (conf のコメント参照)
KART_CPU_GUI_UNITS = "seatd.service weston.service kmm.service can0-up.service"
KART_CPU_NOISE_UNITS = "tailscaled.service systemd-networkd.service \
    iptables.service ip6tables.service busybox-syslog.service busybox-klogd.service"
# GUI 表示後へ退避するノイズ (noise-defer.conf)。networkd は退避せず
# weight 抑制のみ (DHCP/tailscale 到達の遅延を 1 段に留める)
KART_NOISE_DEFER_UNITS = "busybox-syslog.service busybox-klogd.service \
    iptables.service ip6tables.service"

do_install() {
    install -d ${D}${systemd_system_unitdir}/systemd-random-seed.service.d
    install -m 0644 ${WORKDIR}/random-seed-credit.conf \
        ${D}${systemd_system_unitdir}/systemd-random-seed.service.d/random-seed-credit.conf
    # 起動嵐 (basic 直後のスタート集中) からの非クリティカル退避:
    # logind (256ms) と dbus (513ms) を GUI 表示後へ (各 conf のコメント参照)
    install -d ${D}${systemd_system_unitdir}/systemd-logind.service.d
    install -m 0644 ${WORKDIR}/logind-defer.conf \
        ${D}${systemd_system_unitdir}/systemd-logind.service.d/logind-defer.conf
    install -d ${D}${systemd_system_unitdir}/dbus.service.d
    install -m 0644 ${WORKDIR}/dbus-defer.conf \
        ${D}${systemd_system_unitdir}/dbus.service.d/dbus-defer.conf
    # StartupCPUWeight ドロップイン (GUI 優遇 / ノイズ抑制)
    for u in ${KART_CPU_GUI_UNITS}; do
        install -d ${D}${systemd_system_unitdir}/$u.d
        install -m 0644 ${WORKDIR}/cpu-weight-gui.conf \
            ${D}${systemd_system_unitdir}/$u.d/cpu-weight.conf
    done
    for u in ${KART_CPU_NOISE_UNITS}; do
        install -d ${D}${systemd_system_unitdir}/$u.d
        install -m 0644 ${WORKDIR}/cpu-weight-noise.conf \
            ${D}${systemd_system_unitdir}/$u.d/cpu-weight.conf
    done
    for u in ${KART_NOISE_DEFER_UNITS}; do
        install -d ${D}${systemd_system_unitdir}/$u.d
        install -m 0644 ${WORKDIR}/noise-defer.conf \
            ${D}${systemd_system_unitdir}/$u.d/noise-defer.conf
    done
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/systemd-random-seed.service.d/random-seed-credit.conf \
    ${systemd_system_unitdir}/systemd-logind.service.d/logind-defer.conf \
    ${systemd_system_unitdir}/dbus.service.d/dbus-defer.conf \
    ${systemd_system_unitdir}/*.service.d/cpu-weight.conf \
    ${systemd_system_unitdir}/*.service.d/noise-defer.conf \
"
