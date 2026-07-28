# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Yocto (scarthgap / 5.0) build, driven by **kas-container** (Docker), that produces a Raspberry Pi 5 embedded Linux image. The image runs a C++/Qt6 Widgets kiosk GUI (`kart-machine-manager`, built from the app repo's `app-cpp/`) on Wayland/Weston, with CAN bus, GPIO, Tailscale, and NVMe boot. systemd init, systemd-networkd networking, read-only rootfs.

The custom work lives in two places:
- `kas/` — build composition (which layers, machine, distro features, boot layout)
- `meta-kart/` — the product BitBake layer (image recipe, app/service recipes, kernel config fragments, WIC layouts)

Everything else at the top level (`poky/`, `meta-openembedded/`, `meta-raspberrypi/`, `meta-qt6/`) is an upstream layer checkout — do not edit. `kart-machine-manager/` is a **separate git repo** (the GUI app) cloned alongside; it has its own README/AGENTS.md and its own tooling (uv, pytest, ruff, mypy). Run app-level commands inside that repo, not here.

`build/`, `downloads/`, `sstate-cache/` are build artifacts/caches (gitignored).

## Build

Use the `scripts/build.sh` wrapper — it maps a target to the right kas YAML composition:

```bash
./scripts/build.sh prod --nvme              # production RPi5, NVMe boot
./scripts/build.sh prod --sdcard            # production, SD boot
./scripts/build.sh dev --sdcard             # dev (debug-tweaks), SD boot
./scripts/build.sh qemu                     # QEMU dev image
```

- `prod`/`dev` **require** `--sdcard` or `--nvme` (no default boot layout).
- The GUI app is **always built into the image**: the recipe fetches the app repo at a pinned `SRCREV` and cross-compiles `app-cpp/` (the old `--with-app` / `kas/app-embed.yml` mechanism is gone).
- Secrets are NOT baked into images: kmm.service reads `/data/kmm.env` (persistent partition, survives OTA). Provision once per device (`scp .env root@<host>:/data/kmm.env`). App-embedded images are therefore safe to publish as releases.

Direct kas invocation (the `:` operator merges YAMLs left-to-right):

```bash
kas-container build kas/rpi5-prod.yml:kas/boot-nvme.yml
kas-container build kas/local-dev.yml:kas/boot-sdcard.yml
kas-container build kas/qemu-dev.yml
```

Outputs land in `build/tmp/deploy/images/{raspberrypi5,qemuarm64}/`.

## kas composition model

There is no single monolithic config — configs are composed from fragments. Understand this before changing build behavior:

| File | Role |
|------|------|
| `base.yml` | upstream repos, distro features, systemd init, `DL_DIR`/`SSTATE_DIR`, `rm_work` |
| `rpi5.yml` | machine `raspberrypi5`, BSP repo, SPI/CAN/GPU/PCIe/UART, kernel cmdline |
| `qemu.yml` | machine `qemuarm64`, ext4 fstype, virtio-gpu |
| `boot-sdcard.yml` / `boot-nvme.yml` | **WKS selection only** (which `.wks` partition layout) |
| `sdk.yml` | overlay for `bitbake meta-toolchain-qt6` — trims the Qt SDK to qtbase only (the app needs Widgets/Gui/Network/Core) |
| `rpi5-prod.yml` | `includes: base + rpi5`, `target: kart-image` |
| `local-dev.yml` | `includes: base + rpi5` + `debug-tweaks` + dev tools |
| `qemu-dev.yml` | `includes: base + qemu` + debug-tweaks |

`*-prod.yml` and `*-dev.yml` deliberately omit the boot layout, so they are **not buildable alone** — always append a `boot-*.yml`. (The `build.sh` wrapper enforces this.)

**App version pinning:** the app recipe (`recipes-app/kart-machine-manager/kart-machine-manager_2.0.bb`) pins a single `SRCREV`. Bumping the app = update `SRCREV` (and the `branch=` parameter if the app branch changed).

## meta-kart layer

Priority 10 (above meta-openembedded), depends on `core qt6-layer`, compatible with scarthgap only. Recipes are grouped by `recipes-<category>/`:

- `recipes-core/images/kart-image.bb` — the image. Defines package set, `read-only-rootfs`, and a chain of `ROOTFS_POSTPROCESS_COMMAND` functions worth knowing about: create the persistent `/data` ext4 mount (`LABEL=data`, plus tmpfiles for `/data/log` and `/data/tailscale`), install pre-generated SSH host keys (and mask `sshdgenkeys`), and **delay `systemd-timesyncd`/`systemd-resolved`** via timers gated on `kmm.service` so they don't slow boot before the GUI appears (kmm is `Type=notify` and reports READY at first window expose, so "kmm active" = GUI on screen). These are all boot-time optimizations — edit carefully.
- `recipes-app/kart-machine-manager/` — cross-compiles the C++ app (`app-cpp/`, qt6-cmake) from GitHub at a pinned `SRCREV` into `/usr/bin/kmm`. One systemd unit: **`kmm.service`** (`After=weston.service`, `Type=notify`, shows the GUI immediately — the old kmmd daemon + kmm-start notifier split existed only to hide PyQt6 import time). On QEMU a drop-in sets `DEBUG=TRUE` (built-in mock CAN).
- `recipes-graphics/weston/` — Weston kiosk config (`weston.ini`). The bbappend **replaces `weston.service` wholesale and masks `weston.socket`** to disable socket-activation, then wires weston into `multi-user.target` directly.
- `recipes-kernel/linux/` — config fragments `can.cfg`, `nvme.cfg`, `usb-net.cfg`, `slim.cfg` for the RPi kernel.
- `recipes-support/can-setup/` — `can0-up.service` brings up SocketCAN; bitrate configured via `/etc/default/can0`.
- `recipes-connectivity/tailscale/` — prebuilt Tailscale binary recipe (plus first-boot auto-connect via an auth key injected onto the boot partition).
- `wic/*-ab.wks` — **A/B (tryboot) disk layouts**: p1 AUTOBOOT (slot selector, generated at build), p2/p3 BOOTA/B, p5/p6 rootA/B, p7 shared data. OS updates go over SSH via `scripts/ota-update.sh` (writes the inactive slot, one-shot tryboot, interactive commit via `kart-ab-commit`; firmware auto-falls-back on boot failure). Slot roots are `--fixed-size` so dd between slots always fits; boot slots are updated by file copy (not dd) to preserve the BOOTA/BOOTB labels.

**`BBFILES_DYNAMIC` (in `conf/layer.conf`):** `recipes-kernel/` is excluded from the normal `BBFILES` glob and loaded only when `meta-raspberrypi` is present. This keeps RPi kernel bbappends out of QEMU builds.

## QEMU, flashing, deploy

```bash
./scripts/run-qemu.sh --vnc          # boot QEMU image, VNC on :5901
./scripts/run-qemu.sh --nographic    # serial console only
ssh root@192.168.7.2                  # into running QEMU (TAP, debug-tweaks)

sudo ./scripts/flash.sh -sdcard /dev/sdX   # bmaptool-preferred write (-sdcard/-nvme required)
sudo ./scripts/flash.sh -nvme /dev/nvme0n1
./scripts/remote-flash.sh -sdcard user@host /dev/sdX  # writer attached to another machine

./scripts/release.sh -nvme v1.0.0    # build + upload images AND the Qt SDK installer to GitHub Release (needs GITHUB_TOKEN; --no-sdk to skip)
# sync-app.sh is legacy (Python-era images); C++ app updates go via SRCREV bump + OTA,
# or scp a cross-built binary to /usr/bin/kmm for quick iteration
```

`run-qemu.sh` calls the **host's** `qemu-system-aarch64`, not the one inside the build tree.

## Gotchas

- **The `kart` user is created by `weston-init.bbappend`** (the app recipe only references it via `User=kart`). Its uid is dynamically assigned at build time — and deliberately irrelevant: the wayland socket lives in weston.service's fixed `RuntimeDirectory` (`/run/wayland`), so no unit file ever needs the uid.
- QEMU images are `ext4`; real-hardware images are `.wic`/`.wic.bz2` — they are not interchangeable.
- First build needs ~50GB free.
- **Don't assume GNU coreutils in device-side script snippets** — stick to POSIX/busybox syntax (`head -n 1` not `head -1`; plain `dd of=... bs=...` without `conv=`/`status=`). coreutils is only present as a side effect of rpi-eeprom's RDEPENDS, and both patterns broke when it briefly disappeared.
- `read-only-rootfs` is enabled — anything that must persist at runtime goes on the `/data` partition (label `data`), not the rootfs.
- BitBake variables are `UPPERCASE_SNAKE_CASE`; bbappends use `%` for version-independence and `FILESEXTRAPATHS:prepend := "${THISDIR}/files:"` to add files.
- **systemd drop-ins cannot reset dependency lists** (`Before=`/`After=`/`Requires=` — an empty assignment is a no-op). To remove an ordering edge, replace the unit wholesale (weston-init.bbappend) or `sed` the shipped unit in image postprocess (timesyncd in `kart-image.bb`). Getting this wrong causes silent ordering cycles — check `journalctl -b | grep -i "ordering cycle"` after unit changes.
- **`systemd_preset_all` runs during `do_image`** (image.bbclass appends it to `IMAGE_PREPROCESS_COMMAND`), recreating enable symlinks after every `ROOTFS_POSTPROCESS_COMMAND` hook. To delete a preset-created link, use a recipe-level `IMAGE_PREPROCESS_COMMAND:append` (parsed after the class append, so it runs last).
- **Editing `ROOTFS_POSTPROCESS_COMMAND` functions sometimes does not retrigger `do_rootfs`** — the "rebuilt" image is silently stale. Always compare the deployed image's timestamp against the build time; force with `kas-container shell <config> -c "bitbake -C rootfs kart-image"`. Verify image contents without flashing via `bunzip2 -kc *.wic.bz2 > x.wic`, `dd` out the rootfs partition, then `debugfs -R 'cat <path>' p2.img`.
