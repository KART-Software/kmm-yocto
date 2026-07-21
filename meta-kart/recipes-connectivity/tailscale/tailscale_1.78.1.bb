SUMMARY = "Tailscale VPN client"
DESCRIPTION = "Tailscale mesh VPN built on WireGuard - prebuilt ARM64 binary"
HOMEPAGE = "https://tailscale.com"
LICENSE = "BSD-3-Clause"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/BSD-3-Clause;md5=550794465ba0ec5312d6919e203a55f9"

TAILSCALE_ARCH = "arm64"
SRC_URI = "https://pkgs.tailscale.com/stable/tailscale_${PV}_${TAILSCALE_ARCH}.tgz;downloadfilename=tailscale_${PV}_${TAILSCALE_ARCH}.tgz"
SRC_URI[sha256sum] = "8eb0ae11ac2f80beac379722b37651e6ef328d098fec0425ca2786c1c8f087e3"

SRC_URI:append = " file://tailscaled.service file://tailscale-autoconnect.service file://tailscale-autoconnect.sh"

inherit systemd

RDEPENDS:${PN} = "iptables iproute2 ca-certificates"

INSANE_SKIP:${PN} = "already-stripped ldflags"
INHIBIT_PACKAGE_STRIP = "1"
INHIBIT_SYSROOT_STRIP = "1"
INHIBIT_PACKAGE_DEBUG_SPLIT = "1"

S = "${WORKDIR}/tailscale_${PV}_${TAILSCALE_ARCH}"

do_install() {
    # Binaries
    install -d ${D}${sbindir}
    install -m 0755 ${S}/tailscaled ${D}${sbindir}/tailscaled

    install -d ${D}${bindir}
    install -m 0755 ${S}/tailscale ${D}${bindir}/tailscale

    # State directory
    install -d ${D}${localstatedir}/lib/tailscale

    # systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/tailscaled.service ${D}${systemd_system_unitdir}/tailscaled.service

    # First-boot auto-connect (auth key injected onto boot partition post-flash)
    install -m 0755 ${WORKDIR}/tailscale-autoconnect.sh ${D}${sbindir}/tailscale-autoconnect.sh
    install -m 0644 ${WORKDIR}/tailscale-autoconnect.service ${D}${systemd_system_unitdir}/tailscale-autoconnect.service
}

SYSTEMD_SERVICE:${PN} = "tailscaled.service tailscale-autoconnect.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    ${sbindir}/tailscaled \
    ${sbindir}/tailscale-autoconnect.sh \
    ${bindir}/tailscale \
    ${localstatedir}/lib/tailscale \
    ${systemd_system_unitdir}/tailscaled.service \
    ${systemd_system_unitdir}/tailscale-autoconnect.service \
"

COMPATIBLE_HOST = "aarch64.*-linux"
