SUMMARY = "Kart Machine Manager GUI application"
DESCRIPTION = "PyQt6-based kiosk GUI for kart machine management with CAN bus support"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://kart-machine-manager.service \
"

# Set KART_APP_SRC to embed app source into the image at build time.
# e.g. in kas local_conf_header:
#   KART_APP_SRC = "/path/to/kart-machine-manager"
# When unset, /opt/kart is created empty (deploy later via sync-app.sh).
KART_APP_SRC ?= ""

inherit systemd

DEPENDS += "${@'python3-native' if d.getVar('KART_APP_SRC') else ''}"

RDEPENDS:${PN} = " \
    python3-core \
    python3-pyqt6 \
    python3-can \
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
    fi

    # systemd service
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/kart-machine-manager.service ${D}${systemd_system_unitdir}/kart-machine-manager.service
}

SYSTEMD_SERVICE:${PN} = "kart-machine-manager.service"
SYSTEMD_AUTO_ENABLE = "enable"

FILES:${PN} = " \
    /opt/kart \
    ${systemd_system_unitdir}/kart-machine-manager.service \
"
