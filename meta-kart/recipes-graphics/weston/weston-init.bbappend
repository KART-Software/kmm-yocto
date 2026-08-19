FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://weston.ini \
                   file://weston.service \
                  "
SRC_URI:append:mx8mm-generic-bsp = " file://mesa-cache.conf \
                                     file://mesa-cache-tmpfiles.conf \
                                     file://weston-early.service \
                                    "

# Create kart user (video, input, render, tty groups for display access)
# weston user is still created by the original weston-init recipe
USERADD_PARAM:${PN}:append = " ; -m -d /home/kart -s /bin/sh -G video,input,render,tty kart"

do_install:append() {
    install -d ${D}${sysconfdir}/xdg/weston
    install -m 0644 ${WORKDIR}/weston.ini ${D}${sysconfdir}/xdg/weston/weston.ini

    # Replace weston.service entirely (drop-in cannot reset [Unit] Requires)
    install -m 0644 ${WORKDIR}/weston.service ${D}${systemd_system_unitdir}/weston.service

    # Mask weston.socket to prevent socket-activation
    ln -sf /dev/null ${D}${systemd_system_unitdir}/weston.socket

    # Ensure weston starts under multi-user.target (default target)
    install -d ${D}${systemd_system_unitdir}/multi-user.target.wants
    ln -sf ../weston.service ${D}${systemd_system_unitdir}/multi-user.target.wants/weston.service

    # Remove drop-in directory if present from previous builds
    rm -rf ${D}${systemd_system_unitdir}/weston.service.d
}

# Mesa シェーダキャッシュを /data へ (mx8mm のみ。中身は mesa-cache.conf 参照)。
# 素の do_install:append が weston.service.d を rm -rf しているが、override 付き
# append はその後に実行されるため、この drop-in は生き残る
do_install:append:mx8mm-generic-bsp() {
    install -d ${D}${systemd_system_unitdir}/weston.service.d
    install -m 0644 ${WORKDIR}/mesa-cache.conf \
        ${D}${systemd_system_unitdir}/weston.service.d/mesa-cache.conf
    install -d ${D}${nonarch_libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/mesa-cache-tmpfiles.conf \
        ${D}${nonarch_libdir}/tmpfiles.d/weston-mesa-cache.conf
    # mx8mm は早期起動変種で weston.service を上書き (中身のコメント参照)
    install -m 0644 ${WORKDIR}/weston-early.service \
        ${D}${systemd_system_unitdir}/weston.service
}

FILES:${PN} += "${sysconfdir}/xdg/weston/weston.ini \
                ${systemd_system_unitdir}/weston.service \
                ${systemd_system_unitdir}/weston.socket \
                ${systemd_system_unitdir}/multi-user.target.wants/weston.service \
               "
FILES:${PN}:append:mx8mm-generic-bsp = " \
    ${systemd_system_unitdir}/weston.service.d/mesa-cache.conf \
    ${nonarch_libdir}/tmpfiles.d/weston-mesa-cache.conf \
"
