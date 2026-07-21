#!/bin/sh
# Auto-connect to Tailscale on first boot using an auth key injected onto the
# boot partition (see scripts/inject-authkey.sh). tailscaled state persists on
# /data/tailscale, so the key is only needed once: it is deleted after a
# successful login, and the service's ConditionPathExists then keeps it from
# running on subsequent boots.
set -u

KEY_FILE=/boot/tailscale.authkey
SOCK=/run/tailscale/tailscaled.sock

[ -f "$KEY_FILE" ] || exit 0

# tailscaled is Type=simple: unit "started" does not mean the socket is ready.
# Wait (up to ~30s) for the control socket to appear.
i=0
while [ ! -S "$SOCK" ]; do
    i=$((i + 1))
    [ "$i" -ge 30 ] && break
    sleep 1
done

# Already connected (e.g. state restored from /data)? Drop the key and stop.
if tailscale status --json 2>/dev/null | grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
    rm -f "$KEY_FILE"
    exit 0
fi

# --ssh enables Tailscale SSH so the node is reachable over the tailnet even on
# prod images that have no local login (the tailnet ACL must permit SSH).
if tailscale up --authkey="$(cat "$KEY_FILE")" --hostname="$(hostname)" --ssh; then
    rm -f "$KEY_FILE"
    echo "tailscale-autoconnect: connected; auth key removed from boot partition"
else
    echo "tailscale-autoconnect: 'tailscale up' failed; auth key kept for retry" >&2
    exit 1
fi
