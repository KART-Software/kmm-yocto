# var-volatile-lib.service から systemd-random-seed.service への順序 (Before=) と
# WantedBy= を外す。upstream は「seed は /var/lib 配下」を理由にこの辺を張るが、
# 本イメージの seed 実体は /data/random-seed (symlink は rootfs 上) で /var/lib の
# volatile overlay を待つ必要がない。むしろこの辺があると var-volatile.mount の
# ジョブが udev coldplug のイベント洪水で遅れる boot (PID1 の run queue 飢餓) で
# seed credit が weston/kmm の getrandom() より後ろに回り、GUI が +0.4s 遅れる。
# systemd-random-seed 側は kart-udev-slim が /etc に置く丸ごと差し替え unit が
# After=kart-data-mount.service で直結する (docs/imx8mp-debix-bringup/30-boot-time.md)。
# drop-in では依存を消せないので upstream の do_compile の後で sed で剥がす。
do_compile:append() {
    if [ -e var-volatile-lib.service ]; then
        sed -i -e "/^Before=/s/ systemd-random-seed.service//" \
               -e "/^WantedBy=/s/ systemd-random-seed.service//" \
               var-volatile-lib.service
    fi
}
