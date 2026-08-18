#!/bin/sh
# Auto-connect to Tailscale on first boot using an auth key injected onto the
# boot partition. Injection paths: flash.sh (inject_tailscale_key, RPi5),
# ota-update.sh --authkey (inactive-slot update), or manual placement per
# docs/imx8mm-xpi-bringup/06-emmc-flash.md (netboot dd / U-Boot ums).
# tailscaled state persists on /data/tailscale, so the key is only needed
# once: it is deleted after a successful login, and the service's
# ConditionPathExists then keeps it from running on subsequent boots.
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
# --accept-dns=false: tailnet の DNS 設定 (MagicDNS) を OS に適用しない。
# tailscaled が resolv.conf を書き換えるパス自体が走らなくなるので、
# read-only rootfs での「resolv.conf バックアップ作成失敗」(毎ブート実測)
# が根絶され、resolved の起動タイミングにも依存しなくなる。板から
# tailnet 名で他ノードを引く用途は無い (接続は常にこちらから IP 指定)。
if tailscale up --authkey="$(cat "$KEY_FILE")" --hostname="$(hostname)" --ssh --accept-dns=false; then
    rm -f "$KEY_FILE"
    echo "tailscale-autoconnect: connected; auth key removed from boot partition"
else
    echo "tailscale-autoconnect: 'tailscale up' failed; auth key kept for retry" >&2
    exit 1
fi
