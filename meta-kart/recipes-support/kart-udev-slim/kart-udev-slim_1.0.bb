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
"

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
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/systemd-random-seed.service.d/random-seed-credit.conf \
    ${systemd_system_unitdir}/systemd-logind.service.d/logind-defer.conf \
    ${systemd_system_unitdir}/dbus.service.d/dbus-defer.conf \
"
