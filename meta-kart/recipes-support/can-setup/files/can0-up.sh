#!/bin/sh
# Bring up CAN0 interface with configurable bitrate.
# Configuration is read from /etc/default/can0

set -e

BITRATE="${BITRATE:-500000}"
IFACE="${IFACE:-can0}"
RESTART_MS="${RESTART_MS:-100}"

/sbin/ip link set "${IFACE}" type can bitrate "${BITRATE}" restart-ms "${RESTART_MS}"
/sbin/ip link set "${IFACE}" up

echo "${IFACE}: up at ${BITRATE} bps (restart-ms=${RESTART_MS})"
