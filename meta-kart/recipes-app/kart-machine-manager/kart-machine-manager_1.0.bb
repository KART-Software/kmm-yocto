SUMMARY = "Kart Machine Manager GUI application"
DESCRIPTION = "PyQt6-based kiosk GUI for kart machine management with CAN bus support"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# NOTE: .env is NOT part of the image. kmmd.service reads /data/kmm.env from
# the persistent data partition, so app-embedded images are safe to publish.
SRC_URI = " \
    file://kmmd.service \
    file://kmm-start.service \
"

# QEMU has no CAN hardware; ship a drop-in that runs the app in mock (DEBUG) mode.
SRC_URI:append:qemuarm64 = " file://kmmd-debug.conf"

# Set KART_APP_SRC to embed app source into the image at build time.
# e.g. in kas local_conf_header:
#   KART_APP_SRC = "/path/to/kart-machine-manager"
# When unset, /opt/kart is created empty (deploy later via sync-app.sh).
KART_APP_SRC ?= ""

# Changing this value invalidates BitBake sstate cache automatically.
KART_APP_REVISION ?= ""
do_install[vardeps] += "KART_APP_REVISION"

inherit systemd

DEPENDS += "${@'python3-native' if d.getVar('KART_APP_SRC') else ''}"

# python3-can removed: the app ships its own socketcan implementation
# (src/canbus, stdlib socket.AF_CAN). python3-netclient provides the socket
# module it uses.
RDEPENDS:${PN} = " \
    python3-core \
    python3-pyqt6 \
    python3-netclient \
    python3-dotenv \
    python3-requests \
    python3-json \
    python3-logging \
"

do_install() {
    # Create directory structure
    install -d ${D}/opt/kart

    # Embed app source if KART_APP_SRC is set
    if [ -n "${KART_APP_SRC}" ] && [ -d "${KART_APP_SRC}" ]; then
        cp -a ${KART_APP_SRC}/. ${D}/opt/kart/kart-machine-manager/
        # Fix ownership (cp -a preserves host uid/gid)
        chown -R root:root ${D}/opt/kart/kart-machine-manager/
        # Remove dev artifacts
        find ${D}/opt/kart/kart-machine-manager/ \
            \( -name '.git' -o -name '.venv' -o -name '.ruff_cache' \
               -o -name 'uv.lock' -o -name '.python-version' \
               -o -name '.gitignore' -o -name 'ruff.toml' \
               -o -name 'run_debug.sh' \) -exec rm -rf {} + 2>/dev/null || true
        # Precompile .pyc
        ${STAGING_BINDIR_NATIVE}/python3-native/python3 \
            -c "import compileall; compileall.compile_dir('${D}/opt/kart/kart-machine-manager/', quiet=2, force=True)"
        # Strip any .env that came with the app checkout (secrets stay on /data)
        rm -f ${D}/opt/kart/kart-machine-manager/app/.env
    fi

    # systemd services
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kmmd.service ${D}${systemd_system_unitdir}/kmmd.service
    install -m 0644 ${WORKDIR}/kmm-start.service ${D}${systemd_system_unitdir}/kmm-start.service
}

# QEMU-only: drop-in enabling mock CAN (DEBUG=TRUE) since there is no can0.
do_install:append:qemuarm64() {
    install -d ${D}${systemd_system_unitdir}/kmmd.service.d
    install -m 0644 ${WORKDIR}/kmmd-debug.conf \
        ${D}${systemd_system_unitdir}/kmmd.service.d/debug.conf
}

SYSTEMD_SERVICE:${PN} = "kmmd.service kmm-start.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    /opt/kart \
    ${systemd_system_unitdir}/kmmd.service \
    ${systemd_system_unitdir}/kmm-start.service \
"

FILES:${PN}:append:qemuarm64 = " ${systemd_system_unitdir}/kmmd.service.d/debug.conf"
