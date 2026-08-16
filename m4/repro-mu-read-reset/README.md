# i.MX8MM: M4 peripheral READ during an active rpmsg/MU session hard-resets the SoC

Minimal reproduction for an issue where the **Cortex-M4 reading a GPIO/ECSPI
register while an rpmsg (virtio/MU) session with Linux is active causes an
immediate, silent, SoC-wide hard reset** on i.MX8M Mini.

## Environment

- SoC: i.MX8MM (Cortex-A53 rev 1.0 + Cortex-M4), custom board (Geniatech
  XPI-iMX8MM) — same behavior expected on EVK (untested there)
- A53: Linux 6.12.20 (linux-fslc), `imx_rproc` remoteproc (SMC method),
  DT with vdev0vring0/1 + rsc-table + vdevbuffer reserved-memory
  (NXP `imx8mm-evk-rpmsg.dts` layout)
- **Also reproduces identically on the NXP vendor kernel,
  linux-fslc-imx lf-6.6.101** (control case runs indefinitely, the
  GPIO-read case resets the SoC within seconds), with that kernel's
  thermal management and watchdog fully operational.
- M4 firmware: bare-metal + rpmsg-lite v5.4.1 (this directory). The same
  failure reproduces with Zephyr 4.3 (`CONFIG_IPM` + OpenAMP
  `openamp_rsc_table` port).
- M4 loaded and started via Linux remoteproc (`/sys/class/remoteproc`),
  ATF SIP (`IMX_SIP_SRC_M4_START`).

## Symptom

The instant the M4 executes a **read** of `GPIO3_DR` (0x30220000) — or any
GPIO bank data register, or ECSPI2 registers (0x30830000) — while the
rpmsg link with Linux is up, the whole SoC resets:

- A53 console shows **no panic**; output jumps straight to U-Boot SPL
- M4 reaches the read (breadcrumbs in TCMU prove progress), no M4 fault
  handler runs (a spinning `k_sys_fatal_error_handler` in the Zephyr
  variant is never entered)
- `SRC_SRSR` after reboot = 0x00000001 (`ipp_reset_b` only; no WDOG bits)

## Experiment matrix (all verified on hardware)

| Stack | rpmsg session active | M4 read target | RDC PDAP of target | Result |
|---|---|---|---|---|
| rpmsg-lite (bare metal) | yes | SCTR (0x306C0008) | default | OK (hours) |
| rpmsg-lite (bare metal) | yes | GPIO3_DR | 0xFF (default) | **reset** |
| rpmsg-lite (bare metal) | yes | GPIO3_DR | 0x0C (D1 only) | **reset** |
| Zephyr, `CONFIG_IPM` only (no rsc table -> no session) | no | GPIO3_DR | 0xFF | **reset** |
| Zephyr, `CONFIG_IPM` only (no session) | no | GPIO3_DR | 0x0C | OK (>10^6 reads) |
| Zephyr + OpenAMP (session) | yes | GPIO / ECSPI2 | 0xFF or 0x0C | **reset** |
| Zephyr, no IPM at all | n/a | GPIO / ECSPI2 (full MCP2515 CAN driver) | 0xFF | OK (hours) |

Additional facts:

- **Writes** to the same GPIO/ECSPI registers never trigger the reset
  (>10^6 writes with active MU config, survives).
- Reads of **SCTR, UART4, MU, DDR** are always safe (UART4 is polled
  continuously by the console driver in all passing cases).
- GPIO/ECSPI clocks are on (`clk_summary` verified), power domains on.
  Tested with and without `clk-imx8mm.mcore_booted=1` — no difference.
- RDC: M4 is domain 1 (`MDA[1]=1`), target PDAPs checked/varied via
  `devmem` from Linux (domain 0). RDC assignment does not change the
  outcome when the session is active. (Note: RDC writes issued by the
  M4 itself are silently ignored; all RDC state was set and verified
  from the A53 side.)
- Not a low-power / bus-scaling artifact: disabling the deep cpuidle
  state (`cpu-pd-wait`) at runtime on all A53 cores does not prevent the
  reset, and the kernel has no devfreq/busfreq scaling compiled in
  (no `/sys/class/devfreq` devices), so no dynamic NoC/DDR frequency
  transitions are occurring.
- Not a watchdog artifact: all failing rows were (re-)validated on boots
  with the watchdog driver loaded and serviced; the resets occur within
  seconds of the M4 reaching the peripheral read, far from any watchdog
  timeout.
- We did not find any MCUXpresso SDK example that combines rpmsg with
  ECSPI/GPIO on the M4 (the ECSPI/GPIO driver examples all carry
  `empty_rsc_table.c`, the rpmsg examples touch only UART/MU/DDR).

## Linux-side requirements

Kernel-only; **no userspace component is needed**. The rpmsg session is
established automatically by the kernel when the remoteproc is started
(virtio_rpmsg probes from the vdev in the resource table, writes
DRIVER_OK and kicks the MU — that *is* the "active session").

1. Device tree: `vdev0vring0/1` + `rsc-table` + `vdevbuffer`
   reserved-memory and an `imx8mm-cm4` remoteproc node. In this repo:
   `meta-kart/recipes-kernel-imx/linux/files/imx8mm-xpi-kart.dts`
   (same layout as NXP's stock `imx8mm-evk-rpmsg.dts`, which works
   as-is on the EVK).
2. Kernel config: `CONFIG_IMX_REMOTEPROC=y`, `CONFIG_RPMSG_VIRTIO=y`
   (this repo: `meta-kart/recipes-kernel-imx/linux/files/m4-remoteproc.cfg`).

`clk-imx8mm.mcore_booted=1` is *not* required for the reproduction
(verified with and without).

## Build

```sh
# once: fetch rpmsg-lite next to this directory
git clone --depth 1 --branch v5.4.1 \
    https://github.com/nxp-mcuxpresso/rpmsg-lite ../lib/rpmsg-lite
# needs arm-none-eabi-gcc (apt install gcc-arm-none-eabi)
make          # -> repro.elf + repro_control.elf
```

## Run (on the target, via Linux remoteproc)

```sh
# copy both ELFs to /lib/firmware, then:
echo stop > /sys/class/remoteproc/remoteproc0/state 2>/dev/null

# 1) control case: identical firmware, but the loop reads SCTR
echo repro_control.elf > /sys/class/remoteproc/remoteproc0/firmware
echo start > /sys/class/remoteproc/remoteproc0/state
sleep 3
devmem 0x800100 32   # DBG[0] = 3 (ept created)
devmem 0x800114 32   # DBG[5] = loop counter, keeps growing; system stable
echo stop > /sys/class/remoteproc/remoteproc0/state

# 2) failing case: the loop reads GPIO3_DR instead
echo repro.elf > /sys/class/remoteproc/remoteproc0/firmware
echo start > /sys/class/remoteproc/remoteproc0/state
# => the whole SoC hard-resets within milliseconds of the link coming up
#    (no panic on the console; U-Boot SPL banner appears)
```

The breadcrumb block (M4 0x20000100 = A53 0x800100) can be inspected with
`devmem` at any time; `DBG[0]`=state, `DBG[5]`=loop count.

## Question

Is this a known limitation/erratum (M4 AIPS read transactions colliding
with MU doorbell activity)? Is there a required RDC / AIPSTZ / NoC / CCM
configuration for the M4 to access GPIO/ECSPI while rpmsg is active that
we are missing? The SDK ships no example combining the two.
