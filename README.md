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
| CAN | The CAN controller is **handed to the Cortex-M (M4/M7)**; `can-gw` (Zephyr) on the M-core links over rpmsg to the `rpmsg-can` kernel module and exposes **`rpmsgcan0`** (SocketCAN) |
| A/B OTA | Write to the inactive slot over SSH (Tailscale OK) → boot once on trial → commit. On failure U-Boot auto-falls back to the old slot |
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
| eMMC | `/dev/mmcblk2` | A/B: imx-boot A=32KiB / B=4MiB, env 7MiB, BOOTA/B · rootA/B · data |
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

## Prerequisites

- **Ubuntu 22.04 or newer** (WSL2 included), Docker, kas-container
- Enough disk space (50GB+ recommended for the first build)
- **NXP `uuu`** (mfgtools) for flashing hardware. Used for first-time flashing
  over SDP and for bootloader recovery
- **Agreement to the NXP EULA** is required (the DDR-training FW in `imx-boot`
  = firmware-imx is distributed under EULA). `ACCEPT_FSL_EULA = "1"` is already
  set in `kas/imx8mm.yml` / `kas/imx8mp.yml`

```bash
sudo apt install -y docker.io e2fsprogs uuu    # uuu from apt or an mfgtools release
pipx install kas                               # or: uv tool install kas
sudo usermod -aG docker,dialout,plugdev $USER  # re-login required
```

---

## Build

### build.sh (development images)

```bash
./scripts/build.sh imx8mp --emmc      # DEBIX Infinity (i.MX8MP) eMMC A/B ← latest
./scripts/build.sh imx8mp             # DEBIX single slot (for a carried-in SD)
./scripts/build.sh imx8mm --emmc      # XPI-iMX8MM eMMC A/B
./scripts/build.sh imx8mm --netboot   # XPI TFTP/NFS netboot (DTS/driver trials)
./scripts/build.sh imx8mm             # XPI plain EVK SD carry-in (single slot)
```

`imx8mm`/`imx8mp` are development images (with debug-tweaks). `--emmc` selects
the eMMC A/B WKS (without it you get the machine-default single slot).

### Falcon + splash + M-core (direct kas invocation)

`build.sh` only goes as far as a plain dev image. Falcon / splash / M-core CAN
are composed by invoking kas directly (`:` merges YAMLs left to right —
**overlay order = application order**). **Export the cache variables first**:

```bash
export DL_DIR=$PWD/downloads SSTATE_DIR=$PWD/sstate-cache

# DEBIX (8MP): dev + eMMC A/B + Falcon + splash + M7 CAN
kas-container build \
  kas/imx8mp-dev.yml:kas/imx-emmc-ab.yml:kas/imx8mp-falcon.yml:kas/imx8mp-splash.yml:kas/imx8mp-m7.yml

# XPI (8MM) production (Tailscale SSH only, no debug-tweaks) + eMMC A/B + Falcon + splash + M4 CAN
kas-container build \
  kas/imx8mm-prod.yml:kas/imx8mm-emmc-ab.yml:kas/imx8mm-falcon.yml:kas/imx8mm-splash.yml:kas/imx8mm-m4.yml
```

> Without exporting `DL_DIR`/`SSTATE_DIR`, `base.yml`'s weak defaults resolve
> against the container's `TOPDIR=/build`, and bitbake aborts with
> `Failed to create a file in SSTATE_DIR: Permission denied`. The caches are
> placed as siblings of `build/`, so `rm -rf build` does not remove them.
> (kas 5.x forwards the in-project DL_DIR as `/work/downloads`.)

> **8MP has no prod variant equivalent to `imx8mm-prod.yml` yet.** The bench
> runs on `imx8mp-dev.yml` (debug-tweaks). Creating a debug-tweaks-off variant
> for shipping is future work.

Artifacts land in `build/tmp/deploy/images/{imx8mp-debix,imx8mm-xpi}/*.wic.bz2`.

### kas composition files

| File | Type | Contents |
|------|------|----------|
| `base.yml` | base | upstream repos, distro features, DL/SSTATE, rm_work |
| `imx8mp.yml` / `imx8mm.yml` | machine | machine + meta-freescale + NXP EULA |
| `imx8mp-dev.yml` | combo | base + imx8mp + debug-tweaks |
| `imx8mm-dev.yml` / `imx8mm-prod.yml` | combo | base + imx8mm (prod has no debug-tweaks) |
| `imx-emmc-ab.yml` | fragment | eMMC A/B WKS selection **shared by 8MM/8MP** (the WKS itself is the machine's `EMMC_AB_WKS`) |
| `imx8mm-emmc-ab.yml` | fragment | the older 8MM-only A/B WKS |
| `imx8mp-falcon.yml` / `imx8mm-falcon.yml` | overlay | SPL-direct kernel boot (`falcon.itb`) |
| `imx8mp-splash.yml` / `imx8mm-splash.yml` | overlay | SPL splash + seamless handoff (**place after falcon**) |
| `imx8mp-m7.yml` / `imx8mm-m4.yml` | overlay | M-core CAN gateway (`rpmsgcan0`) + falcon integration (BL31 starts the M-core) |
| `imx8mm-netboot.yml` | overlay | TFTP/NFS root (for bring-up) |
| `rpi5*.yml` / `boot-*.yml` / `qemu*.yml` / `sdk.yml` | legacy/aux | RPi5 · QEMU · Qt SDK |

The app (the C++ kart-machine-manager) is **always included in the image**. The
recipe (`meta-kart/recipes-app/kmm/kmm_2.0.bb`) fetches it from GitHub at a
pinned `SRCREV` and cross-builds it. Updating the app = bump `SRCREV` and
rebuild.

> **`.env` (secret config) is not baked into images.** `kmm.service` reads
> `/data/kmm.env` (a persistent partition that survives OTA). Place it once per
> device: `scp .env root@<host>:/data/kmm.env`. Images are therefore safe to
> publish as Releases. On M-core builds, include `CAN_INTERFACE=rpmsgcan0`.

---

## How boot works (Falcon Mode)

The relay is **BootROM → SPL (Falcon) → ATF/BL31 (+ M-core start) → kernel →
systemd/weston/kmm**. U-Boot proper appears only during an OTA trial and during
recovery.

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
- **A/B is two-layered**:
  - **rootfs/boot A/B**: BOOTA/B (p1/p2) · rootA/B (p5/p6) · data (p7, shared).
    OTA writes the inactive slot and boots once on trial with
    `upgrade_available=1`
  - **U-Boot (imx-boot) A/B**: the BootROM auto-falls back to slot B when slot
    A's IVT is invalid (8MM=SIT table, 8MP=fuse default offset). Managed by the
    `uboot-*` tools
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

The CAN controller is **handed off to the Cortex-M coprocessor**. The CAN gateway
firmware (`can-gw`, Zephyr) on the M-core links over rpmsg to the kernel's
`rpmsg-can` module and exposes the netdev **`rpmsgcan0`** (ordinary SocketCAN).

- 8MM = **M4** owns the MCP2515 (ECSPI2); 8MP = **M7** owns FlexCAN1
- The M firmware lives in a separate repo,
  [data-logger-zephyr](https://github.com/KART-Software/data-logger-zephyr)
  (`apps/can-gw`, branching 8MM/8MP with SoC guards)
- **Falcon integration**: `m7-fw.img` (8MP) / `m4-fw.img` (8MM) is placed on the
  boot partition; the SPL verifies it → stages it in DDR, and BL31 starts the
  M-core's root clock + places it in ITCM + boots it. Linux then attaches to the
  running M-core via `remoteproc`
- The dev iteration is: drop the ELF into `/lib/firmware` and start it from
  `/sys/class/remoteproc/remoteproc0` (while running, stop → start to swap)
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

## First-time flashing (new board → standalone boot)

### DEBIX (8MP)

The DIP can be **switched over a USB relay** (`bootsel.py` in the
`debix-boot-switch` skill). Either write the bootloader + partitions with `uuu`
(DIP=001), or stream to eMMC from the `sd` (DIP=011) U-Boot. The procedure is in
[fastboot-runbook.md](docs/imx8mp-debix-bringup/fastboot-runbook.md) and the
`debix-boot-switch` skill.

```bash
S=.claude/skills/debix-boot-switch/bootsel.py
python3 $S uuu && python3 scripts/dp100.py cycle --off-time 3   # drop to SDP and run uuu
python3 $S emmc && python3 scripts/dp100.py cycle               # back to normal boot
```

### XPI (8MM)

Set the physical DIP **S1** to Serial Download and power on → the BootROM appears
as a USB SDP device → write with `uuu`. The runbook is in
[06-emmc-flash.md](docs/imx8mm-xpi-bringup/06-emmc-flash.md). When S1 can't be
touched, deliberately corrupt the A/B IVT from running Linux to drop to SDP
(`xpi-remote-sdp` skill).

> **The Falcon imx-boot cannot be RAM-booted with UUU** (it does not accept the
> SDPV handshake). The UUU path uses a stashed stock imx-boot, exposes eMMC with
> `ums`, and dd's to it.

### Updating the bootloader (imx-boot)

It cannot be delivered by OTA (fixed eMMC location). On a running device use
`uboot-update <flash.bin>` (A=new / B=previous, read-back verified; on a power
cut the ROM auto-falls back to the previous version).

---

## OTA updates (A/B, over SSH)

A running device can be updated (whole OS) over SSH (Tailscale OK). `ota-update.sh`
auto-detects the platform from the image's partition layout and the device's
`ab-status`:

```bash
./scripts/ota-update.sh --host <host> --yes \
  build/tmp/deploy/images/imx8mp-debix/kart-image-imx8mp-debix-emmc.wic.bz2
```

Flow: write to the inactive slot (rootfs=dd, boot=file copy) → boot **once** on
trial with `upgrade_available=1` → health check → **commit to make it official**.
If the new slot fails to boot, U-Boot's `altbootcmd` auto-falls back to the old
slot (until you commit, the old slot = the safe side). **To bring both slots in
sync, run twice** (1st = inactive slot; after commit, the 2nd = the other one).

You can also inject a Tailscale auth key into the new slot's boot FAT for initial
join: `--authkey <keyfile>` (auto-deleted on the device after a successful
connection).

Device-side commands:

```bash
ab-status      # current slot
ab-commit      # manually commit the trial-booted slot
uboot-status   # imx-boot A/B boot source and state
uboot-update   # A/B update of imx-boot
uboot-rollback # roll imx-boot back to the previous version
```

---

## About Tailscale

**On prod images Tailscale is the only remote-access channel** (root password
locked, serial cannot log in). Dev images (debug-tweaks) have an empty root
password and allow LAN SSH too.

It auto-joins with an auth key on first boot:

1. Place `tailscale.authkey` on the boot partition (at flash time, or injected
   via `ota-update.sh --authkey`)
2. `tailscale-autoconnect.service` starts gated on the key's presence
   (`ConditionPathExists`)
3. It runs `tailscale up --authkey=… --ssh --accept-dns=false`. `--ssh` enables
   Tailscale SSH
4. On success the key is deleted (not left in the image) and the auth state is
   persisted to `/data/tailscale` — no re-auth even across OTA

> `--accept-dns=false`: MagicDNS is not applied to the OS. The path where
> tailscaled rewrites resolv.conf never runs, eliminating write failures on the
> read-only rootfs.

Issue auth keys in the
[Tailscale admin console](https://login.tailscale.com/admin/settings/keys)
(a reusable key is recommended). The tailnet ACL must permit SSH.

---

## Serial / bench operations

- **DEBIX**: power = `scripts/dp100.py` (DP100, `/dev/dp100`), boot mode = USB
  relay (`bootsel.py` in `debix-boot-switch`, `/dev/usbrelay`), A53 console =
  FTDI `/dev/ttyUSB0` (115200 8N1), display validation = `lcd-validation`
  (AprilTag + camera)
- **XPI**: use the stable udev names (`/dev/kart-a53-console`, etc.). Power,
  camera validation, and UUU are in `imx8mm-xpi-bench`; serial/M4 debugging is in
  the `xpi-serial-debug` skill

(Each skill's procedures and measured values are collected under
`.claude/skills/`.)

---

## Updating the app

**Official**: push kart-machine-manager → update the recipe's `SRCREV` →
rebuild → OTA.

**Dev iteration** (no rebuild): cross-build with the Qt6 SDK and swap just the
binary.

```bash
source <SDK>/environment-setup-*        # the SDK is bundled in Releases by release.sh (bitbake meta-toolchain-qt6)
cmake -B build-app ../kart-machine-manager/app-cpp && cmake --build build-app -j
ssh root@<host> 'mount -o remount,rw /'
scp build-app/kmm root@<host>:/usr/bin/kmm
ssh root@<host> 'mount -o remount,ro / ; systemctl restart kmm'
```

To build into the image from local sources, use the externalsrc wiring
(`local/kas-kmm-externalsrc.yml`, outside the repo).

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
│   ├── recipes-support/ab-tools/ # A/B and U-Boot A/B management tools, fw_env.config
│   └── wic/                      # imx8mp-emmc-ab.wks, imx8mm-emmc-ab.wks, rpi5*.wks
├── m4/                           # M4 bare-metal skeletons and diagnostic ELFs (clk-test, etc.)
├── learning/                     # teaching material for M-core / low-level boot
├── docs/                         # bring-up logs (below)
└── scripts/                      # build/flash/ota/release helpers
```

---

## Documentation

### DEBIX (i.MX8MP) — [docs/imx8mp-debix-bringup/](docs/imx8mp-debix-bringup/)

| File | Contents |
|------|----------|
| 00-plan | migration plan and measured log (factory-image check → machine formalization) |
| 01-m7 | Cortex-M7 startup · can-gw · falcon integration (CAN1 root clock, etc.) |
| 02-dts-delta | DTS delta vs. the EVK |
| 03-first-boot | first-boot U-Boot fixes (DDR 4GB · HDMI · USB) |
| 04-falcon | Falcon mode · dead-man · fallback proper · power-cut sweep |
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

Custom code inside the meta-kart layer: MIT. Each upstream layer follows its own
license. Qt6 (qtbase/qtwayland): LGPL v3 / GPL — verify before distributing a
product. The DDR-training FW in `imx-boot` (firmware-imx) is distributed under
the **NXP EULA** (agreed via `ACCEPT_FSL_EULA=1`).
