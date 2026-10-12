# kmm-yocto — Yocto build (i.MX8M / XPI-iMX8MM · DEBIX-iMX8MP)

**English** | [日本語](README.ja.md)

A project that builds embedded Linux images for NXP i.MX8M-family SBCs with
Yocto (scarthgap) + kas-container. It ships a custom SPL / U-Boot / kernel and
runs a C++/Qt6 kiosk GUI (`kmm`) on Wayland/Weston. Features **Falcon Mode**
(SPL boots the kernel directly), a **CAN gateway via a Cortex-M coprocessor**,
A/B OTA, an SPL splash, Tailscale, and a read-only rootfs.

There are currently two production targets — both i.MX8M boards sharing the same
design (Falcon, M-core CAN, A/B OTA, redundant env, splash, Tailscale):

| | **XPI-iMX8MM** | **DEBIX Infinity (i.MX8MP)** ← latest |
|---|---|---|
| SoC | i.MX8M **Mini** Quad A53 @1.8GHz + **Cortex-M4** | i.MX8M **Plus** Quad Lite A53 + **Cortex-M7** |
| Board | Geniatech XPI-iMX8MM (RPi-compatible form factor) | Polyhex DEBIX Infinity (EMB-IMX8MP-06) |
| RAM | 2GB LPDDR4 (measured; higher than the 1GB spec sheet) | 4GB LPDDR4 (falcon /memory is 3GB+1GB) |
| Display | MIPI-DSI → **LT9611** → HDMI | **lcdif3 → Samsung HDMI PHY**; TFP401 LCD gets EDID via firmware |
| CAN | **MCP2515** (ECSPI2) owned by M4 → rpmsg | **FlexCAN1** owned by M7 → rpmsg |
| Kernel | linux-fslc **6.12** (mainline-based) | linux-fslc-imx **6.6** (NXP BSP-based) |
| BSP | u-boot-fslc + mainline ATF | u-boot-imx + imx-atf (`IMX_DEFAULT_BSP=nxp`) |
| U-Boot A/B | ROM **SIT**-table fallback | ROM **fuse** default-offset (4MiB) fallback |
| env | single copy | **2-copy redundant** (`CONFIG_SYS_REDUNDAND_ENVIRONMENT`) |
| Power→GUI | ≈4.9s | **≈2.93s** (σ0.04) |
| Boot-mode switch | physical DIP **S1** (eMMC / Serial) | DIP driven remotely over a **USB relay** (`debix-boot-switch` skill) |
| bring-up log | [docs/imx8mm-xpi-bringup/](docs/imx8mm-xpi-bringup/) | [docs/imx8mp-debix-bringup/](docs/imx8mp-debix-bringup/) |
| hardware diagram | [hardware.png](docs/imx8mm-xpi-bringup/hardware.png) | [hardware.png](docs/imx8mp-debix-bringup/hardware.png) |

> **The predecessor was the Raspberry Pi 5.** The RPi5 build system
> (`kas/rpi5*.yml`, EEPROM/NVMe procedures) is kept but is no longer a
> production target. For the exact state back then see the tag
> [`rpi5-final`](https://github.com/KART-Software/kmm-yocto/tree/rpi5-final);
> documentation is under [docs/archive/](docs/archive/).

Shared design principles:

| Item | Details |
|------|---------|
| Yocto | scarthgap (5.0), built with kas-container (Docker) |
| Boot | **Falcon Mode** (SPL boots `falcon.itb` = ATF+kernel+DTB directly, skipping U-Boot proper) + SPL splash (zero-blackout handoff) |
| Dead-man | falcon fires only when `boot_os=yes`; the SPL writes it back to `no` when it fires → a crash or power cut auto-falls back to proper next time. On Linux, `falcon-rearm.service` replenishes `yes` |
| CAN | The CAN controller is **handed to the Cortex-M (M4/M7)**; the CAN gateway of the M-core firmware (`main-app`, Zephyr) links over rpmsg to the `rpmsg-can` kernel module and exposes **`rpmsgcan0`** (SocketCAN) |
| A/B OTA | Linux, the M-core firmware and the SPL each have their own A/B, all handled by the `ab` command. Linux: write the inactive slot over SSH (Tailscale OK) → boot once on trial → commit. If the trial fails, the SPL (8MP) or U-Boot (8MM) falls back to the old slot |
| GUI | Wayland + Weston 13 (poky, kiosk) + C++/Qt6 Widgets (`kmm`). 8MP uses no GPU (pixman compositing) |
| init / net | systemd / systemd-networkd, read-only rootfs (persistence on `/data`) |
| Remote | Tailscale SSH (the only channel on prod) |

---

## Hardware

### DEBIX Infinity (i.MX8MP) — latest target

| Item | Value | Notes |
|------|-------|-------|
| SoC | i.MX8M Plus **Quad Lite** A53 + Cortex-M7 | VPU/NPU are fused out, disabled in DTS |
| RAM | 4GB LPDDR4 (Micron MT53E1G32D2NP) | Custom timing table (Model A 3732MTS + 16Gb die-density port) |
| eMMC | `/dev/mmcblk2` | A/B: imx-boot A=32KiB / B=4MiB, env 7MiB, BOOTA/B (p1/p2) · MCORE (p3, M-core firmware A/B) · rootA/B (p5/p6) · data (p7) |
| Display | HDMI (lcdif3 → Samsung HDMI PHY → DW-HDMI) | TFP401 LCD (800x480@33.75MHz) gets EDID via firmware + `drm.edid_firmware` |
| CAN | FlexCAN1 owned by M7 → `rpmsgcan0`. FlexCAN2 = `can0` (unused spare) | J2 Pin31/33 → isolated transceiver |
| Boot mode | DIP (001=UUU / 010=eMMC / 011=SD) | bit2/bit3 driven remotely by a USB relay (`debix-boot-switch`) |

Primary sources and the DTS delta vs. the EVK are in
[02-dts-delta.md](docs/imx8mp-debix-bringup/02-dts-delta.md); the first-boot
U-Boot fixes (DDR/HDMI/USB) are in
[03-first-boot.md](docs/imx8mp-debix-bringup/03-first-boot.md). Bench equipment
(DP100 power, USB relay, serial, camera validation) is covered by the
`debix-boot-switch` / `lcd-validation` skills.

### XPI-iMX8MM

| Item | Value | Notes |
|------|-------|-------|
| SoC | i.MX8M Mini Quad A53 @1.8GHz + Cortex-M4 | |
| RAM | 2GB LPDDR4 | Measured on hardware (higher than the 1GB spec sheet) |
| eMMC | Samsung 8GB (`8GTF4R`), HS400 ES | `/dev/mmcblk2` |
| Display | MIPI-DSI → LT9611 (I2C4 @0x3b) → HDMI | A different chip from the EVK's ADV7535 |
| CAN | MCP2515 (ECSPI2) owned by M4 | Via the 40-pin header |
| Boot mode | physical DIP **S1** (eMMC / Serial Download) | Not software-switchable (`xpi-remote-sdp` works around it) |

Primary hardware sources are in
[docs/imx8mm-xpi-bringup/01-hardware.md](docs/imx8mm-xpi-bringup/01-hardware.md);
bench operations are covered by the `imx8mm-xpi-bench` / `xpi-serial-debug`
skills.

---

## Getting started

Step-by-step guides are in [docs/usage/](docs/usage/README.md) (written in Japanese),
in the order you need them:

| Step | Guide |
|---|---|
| Set up the PC and build images | [01-build.md](docs/usage/01-build.md) |
| First flash of a new board's eMMC | [02-first-flash.md](docs/usage/02-first-flash.md) |
| Per-device setup: `kmm.env`, M-core firmware, Tailscale | [03-provisioning.md](docs/usage/03-provisioning.md) |
| A/B updates of Linux, the M-core firmware and the SPL | [04-ab-updates.md](docs/usage/04-ab-updates.md) |
| App (`kmm`) updates and quick iteration | [05-app.md](docs/usage/05-app.md) |
| M-core firmware: try and install | [06-mcore-firmware.md](docs/usage/06-mcore-firmware.md) |
| Bench: power, boot mode, serial, camera | [07-bench.md](docs/usage/07-bench.md) |
| When a device does not boot | [08-recovery.md](docs/usage/08-recovery.md) |

Building the DEBIX product composition and updating a running device looks like this
(export the cache variables first, or bitbake cannot write its caches):

```bash
export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache
kas-container build \
  kas/imx8mp-dev.yml:kas/imx-emmc-ab.yml:kas/imx8mp-falcon.yml:kas/imx8mp-splash.yml:kas/imx8mp-m7.yml
./scripts/ab.sh --host <device> linux try build/tmp/deploy/images/imx8mp-debix/kart-image-imx8mp-debix-emmc.wic.bz2
./scripts/ab.sh --host <device> linux commit
```

- **Remote access**: prod images are reachable only over Tailscale SSH (the root
  password is locked). Dev images (debug-tweaks) allow LAN SSH as root with an empty
  password. The serial console logs in as root on every image, prod included:
  anyone with physical access to the board is treated as root by design
- **Secrets are not baked into images**: `kmm.service` reads `/data/kmm.env`, a
  persistent partition that survives updates. Place it once per device
- **8MP has no prod variant yet**: the bench runs the dev composition (debug-tweaks)

---

## How boot works (Falcon Mode)

The relay is **BootROM → SPL (Falcon) → ATF/BL31 (+ M-core start) → kernel →
systemd/weston/kmm**. U-Boot proper appears only during recovery (the dead-man
fallback, or a slot whose `falcon.itb` cannot be loaded). On the 8MP an OTA trial
also boots through falcon; on the 8MM (older SPL) the trial goes through U-Boot
proper.

- **Falcon Mode**: the SPL reads `falcon.itb` (ATF+kernel+DTB) straight from the
  eMMC FAT and jumps to it. On the 8MP, BL31 starts the M7 before entering the
  A53 kernel
- **SPL splash**: the SPL drives the display chain directly to show the logo and
  hands off to the kernel with zero blackout
  ([06-splash.md](docs/imx8mp-debix-bringup/06-splash.md))
- **Dead-man**: falcon fires only when `boot_os=yes` and the SPL writes it back
  to `no` when it fires. On Linux, `falcon-rearm.service` replenishes `yes` once
  boot is proven successful (moved to right after seed, dead-man window ≈2.05s).
  A crash or a power cut during the dead-man window auto-recovers to proper next
  boot
- **Three independent A/B sets**, all handled by the `ab` command
  ([04-ab-updates.md](docs/usage/04-ab-updates.md)):
  - **Linux**: BOOTA/B (p1/p2) · rootA/B (p5/p6) · data (p7, shared). An update
    writes the inactive slot and boots it once on trial with
    `upgrade_available=1`. On the 8MP the SPL picks the slot from the env and
    counts the tries
  - **M-core firmware (8MP)**: `mcore-a.img` / `mcore-b.img` on p3 (MCORE),
    independent of Linux
  - **SPL (imx-boot)**: A/B copies outside the partitions. The BootROM boots
    slot B only when slot A's IVT is invalid (8MM=SIT table, 8MP=fuse default
    offset). Managed with `ab spl`
- **Redundant env (8MP)**: env is kept in two copies (0x700000 / 0x704000) and
  saves always go to the unused copy. Even a power cut during a dead-man write
  leaves the other copy intact, so A/B state is unharmed
  ([open-issues #13](docs/imx8mp-debix-bringup/open-issues.md))

DEBIX power→GUI is about **2.93s** (σ0.04, N=10). The per-stage breakdown and the
full optimization log are in
[30-boot-time.md](docs/imx8mp-debix-bringup/30-boot-time.md). XPI is about 4.9s
([09-boot-sequence.md](docs/imx8mm-xpi-bringup/09-boot-sequence.md)).

---

## Cortex-M CAN gateway

The CAN controller is **handed off to the Cortex-M coprocessor**. The M-core firmware
(`main-app`, Zephyr) has a CAN gateway function that links over rpmsg to the kernel's
`rpmsg-can` module and exposes the netdev **`rpmsgcan0`** (ordinary SocketCAN).

- 8MM = **M4** owns the MCP2515 (ECSPI2); 8MP = **M7** owns FlexCAN1
- The M firmware lives in a separate repo,
  [data-logger-zephyr](https://github.com/KART-Software/data-logger-zephyr)
  (`apps/main-app`, branching 8MM/8MP with SoC guards). It is split into a base
  (rpmsg, keepalive) and functions (CAN gateway); the older `apps/can-gw` only had the gateway
- **Keepalive**: the M-core sends a heartbeat every second on the rpmsg channel
  `mcore-keepalive`; the `mcore-keepalive` kernel module shows it under
  `/sys/bus/rpmsg/devices/*.mcore-keepalive.*/state` and logs when it is lost or back.
  `ab mcore update` commits a new firmware only when this keepalive keeps arriving
- **Falcon integration**: the SPL verifies the M-core firmware → stages it in DDR,
  and BL31 starts the M-core's root clock + places it in ITCM + boots it. Linux then
  attaches to the running M-core via `remoteproc`
- **The M-core firmware has its own A/B, independent of Linux** (8MP): partition p3
  holds `mcore-a.img` / `mcore-b.img`, and the env variables `mcore_slot` /
  `mcore_try` select one. It is placed by hand with `ab mcore update` and is not
  part of the Linux image, so a Linux update never changes it. A freshly flashed
  eMMC has none, and Linux runs fine without it.
  XPI (8MM) still reads `m4-fw.img` from the boot partition (its SPL does not have
  the A/B change yet)
- To try a new firmware (back on reboot) or install it, use data-logger-zephyr's
  `scripts/try.sh` / `scripts/install.sh`
  ([06-mcore-firmware.md](docs/usage/06-mcore-firmware.md))
- kmm selects the interface to read from via `CAN_INTERFACE=rpmsgcan0` in
  `/data/kmm.env`
- The mechanics and rules (clock routing, RDC/CCGR, MU read/ACK) are in
  [01-m7.md](docs/imx8mp-debix-bringup/01-m7.md) (8MP) /
  [10-cortex-m4.md](docs/imx8mm-xpi-bringup/10-cortex-m4.md) (8MM) and
  `learning/`

```bash
candump rpmsgcan0
cansend rpmsgcan0 123#DEADBEEF
```

---

## Project layout

```
kmm-yocto/
├── kas/                          # build composition (fragments merged with :)
│   ├── base.yml                  # shared (repos, distro features, DL/SSTATE)
│   ├── imx8mp.yml / imx8mm.yml   # machine + meta-freescale + EULA
│   ├── imx8mp-dev.yml            # 8MP dev image
│   ├── imx8mm-dev.yml / -prod.yml
│   ├── imx-emmc-ab.yml           # shared 8MM/8MP eMMC A/B WKS selection
│   ├── imx8m{p,m}-falcon.yml     # SPL-direct kernel boot
│   ├── imx8m{p,m}-splash.yml     # SPL splash
│   ├── imx8mp-m7.yml / imx8mm-m4.yml   # M-core CAN gateway + falcon integration
│   └── rpi5*.yml / boot-*.yml / qemu*.yml / sdk.yml   # legacy RPi5 / QEMU / SDK
├── meta-kart/                    # product BitBake layer
│   ├── conf/machine/             # imx8mp-debix.conf, imx8mm-xpi.conf
│   ├── recipes-core/images/kart-image.bb
│   ├── recipes-bsp-imx/          # SPL/U-Boot/ATF patches, falcon-itb, env, ab-tools glue
│   ├── recipes-kernel-imx/       # kernel config · DTS · rpmsg-can (candev)
│   ├── recipes-app/kmm/          # C++/Qt6 GUI (kmm_2.0.bb)
│   ├── recipes-graphics/weston/  # kiosk config (weston 13)
│   ├── recipes-connectivity/tailscale/
│   ├── recipes-support/ab-tools/ # the ab command (Linux / M-core / SPL A/B), fw_env.config
│   └── wic/                      # imx8mp-emmc-ab.wks, imx8mm-emmc-ab.wks, rpi5*.wks
├── m4/                           # M4 bare-metal skeletons and diagnostic ELFs (clk-test, etc.)
├── learning/                     # teaching material for M-core / low-level boot
├── docs/                         # usage guides and bring-up logs (below)
└── scripts/                      # build / flash / A/B (ab.sh) helpers
```

---

## Documentation

### Usage — [docs/usage/](docs/usage/README.md)

Build, first flash, per-device setup, A/B updates, app and M-core firmware updates,
bench operations and recovery (see "Getting started" above).

### DEBIX (i.MX8MP) — [docs/imx8mp-debix-bringup/](docs/imx8mp-debix-bringup/)

| File | Contents |
|------|----------|
| 00-plan | migration plan and measured log (factory-image check → machine formalization) |
| 01-m7 | Cortex-M7 startup · can-gw · falcon integration (CAN1 root clock, etc.) |
| 02-dts-delta | DTS delta vs. the EVK |
| 03-first-boot | first-boot U-Boot fixes (DDR 4GB · HDMI · USB) |
| 04-falcon | Falcon mode · dead-man · fallback proper · power-cut sweep · A/B and slot selection |
| 06-splash | SPL splash · dark-boot root cause and fix (weston 13) |
| 07-emmc-boot-rom | eMMC boot ROM / fast-boot investigation (on hold) |
| 08-dark-boot | history of the dark-boot investigation |
| 30-boot-time | ongoing boot-time reduction log (power→GUI 2.93s) |
| open-issues | open items and interim on-device state |

### XPI (i.MX8MM) — [docs/imx8mm-xpi-bringup/](docs/imx8mm-xpi-bringup/)

01-hardware / 02-debug-setup / 03-boot-flow / 04-pitfalls / 06-emmc-flash /
08-falcon / 09-boot-sequence / 10-cortex-m4 / 11-splash-optimization.

Teaching material for the low-level concepts (ARM boot / privilege levels / ATF,
RDC, rpmsg/MU, SPL) is in [learning/](learning/README.md). Migration design
decisions are in
[docs/imx8mm-migration-design.md](docs/imx8mm-migration-design.md). The RPi5 era
is under [docs/archive/](docs/archive/).

---

## Layer composition

| Layer | Branch | Purpose |
|-------|--------|---------|
| poky (meta, meta-poky) | scarthgap | Yocto core layers |
| meta-openembedded | scarthgap | additional packages |
| meta-freescale | scarthgap | i.MX BSP (SPL/U-Boot/kernel base, firmware-imx) |
| meta-qt6 | 6.x | Qt6 |
| meta-kart | local | product-specific recipes |

---

## License

This repository is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE),
with an [additional permission](ADDITIONAL-PERMISSION.md) for Student Formula teams
and education.

Copyright 2026 Ryomei Osaki

You may, for example:

- use it for personal hobby projects, academic research, or teaching and learning
- use and modify it in a Student Formula team, and share your changes with other
  Student Formula teams, regardless of sponsorship or prize money

You may not, for example:

- use it for commercial purposes, such as building it into a product or service
- make changes for commercial purposes, or use changed versions for commercial purposes
- let sponsors or other companies use it for their own business

This summary is for convenience only. The terms in [LICENSE](LICENSE) and
[ADDITIONAL-PERMISSION.md](ADDITIONAL-PERMISSION.md) govern.

### Files under other licenses

The following files are not covered by the license above and keep their original
licenses:

- U-Boot patches (`*.patch`) and `debix-lpddr4_timing.c` in
  `meta-kart/recipes-bsp-imx/u-boot/files/`: GPL-2.0-or-later.
  `debix-lpddr4_timing.c` is Copyright NXP.
- Linux kernel patches and device trees in `meta-kart/recipes-kernel-imx/linux/files/`:
  GPL-2.0, or the license stated in each file.
- The rpmsg-can and mcore-keepalive kernel modules in `meta-kart/recipes-kernel-imx/rpmsg-can/` and
  `meta-kart/recipes-kernel-imx/mcore-keepalive/`: GPL-2.0-only.
- Arm Trusted Firmware patches in `meta-kart/recipes-bsp-imx/imx-atf/files/`: BSD-3-Clause.
- Weston patches, `weston.service` and `weston-early.service` in
  `meta-kart/recipes-graphics/weston/files/`: MIT, as derived from Weston and poky's
  weston-init.
- `meta-kart/recipes-graphics/seatd/files/seatd.service`: MIT, as derived from the
  seatd unit.
- `meta-kart/recipes-connectivity/tailscale/files/tailscaled.service`: BSD-3-Clause,
  as derived from the Tailscale unit.
- `meta-kart/recipes-support/udev-slim/files/systemd-random-seed.service`:
  LGPL-2.1-or-later, as derived from the systemd unit.
- `m4/*/rpmsg_config.h`: BSD-3-Clause, Copyright Mentor Graphics, Xilinx, Freescale
  and NXP.
- `m4-fw.bin` and `m7-fw.bin` in `meta-kart/recipes-bsp-imx/falcon-itb/files/`:
  firmware built from data-logger-zephyr, which includes components of Zephyr
  (Apache-2.0) and the NXP HAL (BSD-3-Clause).
- The team logo in `logo/` and `meta-kart/recipes-bsp-imx/u-boot/files/spl_splash_logo.h`
  belongs to KART and is not covered by this license. Any use requires the team's
  permission.

The upstream layers that kas checks out next to this repository (poky,
meta-openembedded, meta-qt6 and the BSP layers) follow their own licenses.

Built images contain third-party software under its own licenses. This includes GPL
and LGPL components such as Qt6 (qtbase and qtwayland), and the DDR training firmware
in `imx-boot` (firmware-imx), which is distributed under the **NXP EULA** (agreed via
`ACCEPT_FSL_EULA=1`). The build writes the full list to `build/tmp/deploy/licenses/`.
