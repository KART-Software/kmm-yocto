SUMMARY = "Pre-generated SSH host keys for the kart image"
DESCRIPTION = "Installs pre-generated host keys so sshdgenkeys does not spend \
~2s generating them on first boot, and masks sshdgenkeys.service entirely. \
Note: all images share the same host keys; for per-device unique keys drop \
this package and accept the first-boot cost."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://ssh_host_rsa_key \
    file://ssh_host_rsa_key.pub \
    file://ssh_host_ecdsa_key \
    file://ssh_host_ecdsa_key.pub \
    file://ssh_host_ed25519_key \
    file://ssh_host_ed25519_key.pub \
"

do_install() {
    install -d ${D}${sysconfdir}/ssh
    for keyfile in ssh_host_rsa_key ssh_host_ecdsa_key ssh_host_ed25519_key; do
        install -m 0600 ${WORKDIR}/${keyfile} ${D}${sysconfdir}/ssh/${keyfile}
        install -m 0644 ${WORKDIR}/${keyfile}.pub ${D}${sysconfdir}/ssh/${keyfile}.pub
    done

    # 鍵が既にあるので生成サービスは mask して起動時のチェックごと省く
    install -d ${D}${sysconfdir}/systemd/system
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/sshdgenkeys.service
}

FILES:${PN} = " \
    ${sysconfdir}/ssh \
    ${sysconfdir}/systemd/system/sshdgenkeys.service \
"
