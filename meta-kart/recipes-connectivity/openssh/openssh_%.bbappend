# SSH のホスト鍵は機体ごとに /data/ssh に作る (i.MX の製品機)。イメージにも Git にも鍵を入れない。
#
# - 読み取り専用の rootfs で /etc/ssh に鍵が無いと、poky の read_only_rootfs_hook は sshd を
#   sshd_config_readonly (HostKey が /var/run/ssh/...) で動かす。その HostKey を /data/ssh/ に向ける。
#   /data は A/B で共有する永続領域なので、Linux の更新でも鍵は変わらない
# - 鍵は poky の sshdgenkeys.service (sshd_check_keys) が、HostKey の場所に無いものだけ作る。
#   drop-in で、3 つとも揃っている起動では走らせない (2 回目以降は起動時間に影響しない)。
#   初回の生成 (RSA が重い) は GUI の表示より後に回す
# - /data が使えないと鍵が作れず、LAN の SSH には入れない (シリアルと Tailscale SSH は別)
# - /data の無い構成 (RPi5、QEMU) には当てない。poky の既定どおり、起動のたびに /var/run/ssh に作る
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:imx-generic-bsp = " file://sshdgenkeys-data.conf"

do_install:append:imx-generic-bsp() {
    sed -i 's#^HostKey /var/run/ssh/#HostKey /data/ssh/#' ${D}${sysconfdir}/ssh/sshd_config_readonly
    grep -q '^HostKey /data/ssh/ssh_host_ed25519_key$' ${D}${sysconfdir}/ssh/sshd_config_readonly || \
        bbfatal "sshd_config_readonly の HostKey を /data/ssh に向けられなかった"
    install -d ${D}${systemd_system_unitdir}/sshdgenkeys.service.d
    install -m 0644 ${WORKDIR}/sshdgenkeys-data.conf \
        ${D}${systemd_system_unitdir}/sshdgenkeys.service.d/data.conf
}
