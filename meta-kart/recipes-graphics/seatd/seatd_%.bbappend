# seatd の systemd unit を自前で決定的にインストールする。
#
# 罠 (2026-09-03 実測): poky の seatd レシピは unit を自分では入れず、
# upstream meson が「sysroot に systemd.pc が見えたときだけ」contrib の
# seatd.service を入れる。PACKAGECONFIG[systemd] はビルド依存を足さないので、
# unit の有無が sstate の巡り合わせで変わる — 7 月のビルドには入り、
# 今日の再ビルドでは消えた (weston は Requires=seatd なので、消えた
# イメージでは GUI が丸ごと死ぬ)。
#
# ついでに GUI 特急レーン版 (After=sysinit → journald.socket、
# files/seatd.service のコメント参照) に差し替える。
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += " file://seatd.service"

do_install:append() {
    install -Dm 0644 ${WORKDIR}/seatd.service \
        ${D}${systemd_system_unitdir}/seatd.service
}

FILES:${PN} += "${systemd_system_unitdir}/seatd.service"
