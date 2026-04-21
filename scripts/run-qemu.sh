#!/bin/bash
# Run QEMU for kart-image (qemuarm64).
#
# Usage:
#   ./scripts/run-qemu.sh [--nographic] [--vnc [PORT]] [--slirp] [--display TYPE] [IMAGE_DIR]
#
# IMAGE_DIR: directory containing Image and *.ext4.
#            Defaults to build/tmp/deploy/images/qemuarm64/
#
# Network (default: tap0 with static IP):
#   Host 192.168.7.1, Guest 192.168.7.2
#   ssh root@192.168.7.2 (debug-tweaks: no password)
#
# Options:
#   --nographic       Serial console on stdio, no display window
#   --vnc [PORT]      VNC server on PORT (default: 5901). Connect:
#                       ssh -L PORT:localhost:PORT user@<host>
#                       vncviewer localhost:PORT
#   --slirp           User-mode networking (no sudo, no tap)
#                       ssh -p 2222 root@localhost
#   --display TYPE    QEMU display type: gtk (default), sdl, ...
#   -h, --help        Show this help

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPT_NOGRAPHIC=0
OPT_VNC=0
OPT_VNC_PORT=5901
OPT_SLIRP=0
OPT_DISPLAY="gtk,show-cursor=on"
IMAGE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nographic)   OPT_NOGRAPHIC=1 ;;
        --vnc)
            OPT_VNC=1
            if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                OPT_VNC_PORT="$2"; shift
            fi
            ;;
        --slirp)       OPT_SLIRP=1 ;;
        --display)     OPT_DISPLAY="$2"; shift ;;
        --display=*)   OPT_DISPLAY="${1#--display=}" ;;
        -h|--help)
            sed -n '2,/^set -e/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
        *)  IMAGE_DIR="$1" ;;
    esac
    shift
done

IMAGE_DIR="${IMAGE_DIR:-${PROJECT_DIR}/build/tmp/deploy/images/qemuarm64}"

KERNEL="${IMAGE_DIR}/Image"
ROOTFS=$(ls "${IMAGE_DIR}"/kart-image-qemuarm64.rootfs.ext4 2>/dev/null || \
         ls "${IMAGE_DIR}"/kart-image-qemuarm64.rootfs-*.ext4 2>/dev/null | tail -1)

if [[ ! -f "${KERNEL}" ]]; then
    echo "ERROR: kernel not found: ${KERNEL}" >&2
    echo "  Run: kas-container build kas/qemu-dev.yml" >&2
    exit 1
fi
if [[ -z "${ROOTFS}" || ! -f "${ROOTFS}" ]]; then
    echo "ERROR: rootfs (.ext4) not found in ${IMAGE_DIR}" >&2
    echo "  Run: kas-container build kas/qemu-dev.yml" >&2
    exit 1
fi

# --- Data partition (persistent, /dev/vdb → /data) ---
DATA_IMG="${IMAGE_DIR}/data.ext4"
if [[ ! -f "${DATA_IMG}" ]]; then
    echo "Creating data partition image: ${DATA_IMG} (128M)"
    dd if=/dev/zero of="${DATA_IMG}" bs=1M count=128
    mkfs.ext4 -L data -q "${DATA_IMG}"
fi

QEMU="qemu-system-aarch64"
if ! command -v "${QEMU}" &>/dev/null; then
    echo "ERROR: ${QEMU} not found. Install qemu-system-arm." >&2
    exit 1
fi

# --- Cleanup on exit (Ctrl+C, poweroff, kill, etc.) ---
TAP_CREATED=0
cleanup() {
    if [[ "${TAP_CREATED}" -eq 1 ]] && ip link show tap0 &>/dev/null; then
        echo ""
        echo "Removing tap0..."
        sudo ip link set tap0 down
        sudo ip tuntap del tap0 mode tap
    fi
}
trap cleanup EXIT

# --- Network ---
NET_ARGS=()
KERNEL_NET=""
if [[ "${OPT_SLIRP}" -eq 1 ]]; then
    NET_ARGS=(
        -device virtio-net-pci,netdev=net0,mac=52:54:00:12:35:02
        -netdev "user,id=net0,hostfwd=tcp::2222-:22"
    )
    KERNEL_NET="ip=dhcp"
else
    # Create tap0 if not present
    if ! ip link show tap0 &>/dev/null; then
        echo "Creating tap0 (requires sudo)..."
        sudo ip tuntap add tap0 mode tap
        sudo ip addr add 192.168.7.1/24 dev tap0
        sudo ip link set tap0 up
        TAP_CREATED=1
    fi
    NET_ARGS=(
        -device virtio-net-pci,netdev=net0,mac=52:54:00:12:35:02
        -netdev tap,id=net0,ifname=tap0,script=no,downscript=no
    )
    KERNEL_NET="ip=192.168.7.2::192.168.7.1:255.255.255.0::eth0:off:8.8.8.8 net.ifnames=0"
fi

# --- Display ---
DISPLAY_ARGS=()
SERIAL_ARGS=()
if [[ "${OPT_VNC}" -eq 1 ]]; then
    VNC_DISPLAY=$(( OPT_VNC_PORT - 5900 ))
    DISPLAY_ARGS=(-device virtio-gpu-pci
                  -device qemu-xhci -device usb-tablet -device usb-kbd
                  -display "vnc=127.0.0.1:${VNC_DISPLAY}")
    SERIAL_ARGS=(-serial mon:vc -serial null)
elif [[ "${OPT_NOGRAPHIC}" -eq 1 ]]; then
    DISPLAY_ARGS=(-nographic)
    SERIAL_ARGS=(-serial mon:stdio -serial null)
else
    DISPLAY_ARGS=(-device virtio-gpu-pci
                  -device qemu-xhci -device usb-tablet -device usb-kbd
                  -display "${OPT_DISPLAY}")
    SERIAL_ARGS=(-serial mon:vc -serial null)
fi

echo "kernel  : ${KERNEL}"
echo "rootfs  : ${ROOTFS}"
echo "data    : ${DATA_IMG}"
if [[ "${OPT_SLIRP}" -eq 1 ]]; then
    echo "network : slirp (ssh -p 2222 root@localhost)"
elif [[ "${OPT_VNC}" -eq 1 ]]; then
    echo "network : tap0 (ssh root@192.168.7.2)"
    echo "display : VNC port ${OPT_VNC_PORT} (localhost only)"
    echo ""
    echo "  Connect from your local machine:"
    echo "    ssh -L ${OPT_VNC_PORT}:localhost:${OPT_VNC_PORT} $(whoami)@$(hostname)"
    echo "    vncviewer localhost:${OPT_VNC_PORT}"
else
    echo "network : tap0 (ssh root@192.168.7.2)"
    echo "display : $([ "${OPT_NOGRAPHIC}" -eq 1 ] && echo nographic || echo "${OPT_DISPLAY}")"
fi
echo ""

"${QEMU}" \
    -machine virt \
    -cpu cortex-a57 \
    -smp 4 \
    -m 2048 \
    -kernel "${KERNEL}" \
    -append "root=/dev/vda rw ${KERNEL_NET} console=ttyAMA0 console=hvc0 swiotlb=0" \
    -drive id=disk0,file="${ROOTFS}",if=none,format=raw \
    -device virtio-blk-pci,drive=disk0 \
    -drive id=disk1,file="${DATA_IMG}",if=none,format=raw \
    -device virtio-blk-pci,drive=disk1 \
    "${NET_ARGS[@]}" \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-pci,rng=rng0 \
    "${DISPLAY_ARGS[@]}" \
    "${SERIAL_ARGS[@]}"
