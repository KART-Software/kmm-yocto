FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://weston.ini \
                   file://weston.service \
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

FILES:${PN} += "${sysconfdir}/xdg/weston/weston.ini \
                ${systemd_system_unitdir}/weston.service \
                ${systemd_system_unitdir}/weston.socket \
                ${systemd_system_unitdir}/multi-user.target.wants/weston.service \
               "
