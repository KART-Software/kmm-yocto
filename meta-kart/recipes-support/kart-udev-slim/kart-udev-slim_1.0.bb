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
"

do_install() {
    install -d ${D}${systemd_system_unitdir}/systemd-random-seed.service.d
    install -m 0644 ${WORKDIR}/random-seed-credit.conf \
        ${D}${systemd_system_unitdir}/systemd-random-seed.service.d/random-seed-credit.conf
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/systemd-random-seed.service.d/random-seed-credit.conf \
"