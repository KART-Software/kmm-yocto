/* SPDX-License-Identifier: MIT
 *
 * Minimal reproduction: i.MX8MM Cortex-M4 + active rpmsg/MU session +
 * a read access to GPIO3 (AIPS1 peripheral) causes an immediate,
 * silent SoC-wide hard reset (SRSR shows only ipp_reset_b; no panic on
 * the A53 console, no fault on the M4).
 *
 * Build variants (see Makefile):
 *   repro.elf         - PERIPH_READ=1: after the rpmsg link is up, the
 *                       M4 reads GPIO3_DR (0x30220000) in a loop.
 *                       => SoC hard-resets within milliseconds.
 *   repro_control.elf - PERIPH_READ=0: identical, but the loop reads the
 *                       System Counter (SCTR, 0x306C0008) instead.
 *                       => runs indefinitely; heartbeat frames keep
 *                       arriving on the Linux side.
 *
 * The same failure occurs with ECSPI2 (0x30830000) data reads, with
 * Zephyr (CONFIG_IPM + OpenAMP) as well as with this bare-metal
 * rpmsg-lite stack, with the peripheral's RDC PDAP at the default 0xFF
 * or explicitly set to domain-1-only (0x0C), with all relevant clocks
 * enabled and clk-imx8mm.mcore_booted=1. WRITE accesses to the same
 * peripherals never trigger the reset, and reads of SCTR / UART4 / MU /
 * DDR are always safe. Without an active rpmsg/virtio session (that is,
 * without real MU doorbell traffic from Linux) all of these reads are
 * safe, too. See README.md for the full experiment matrix.
 *
 * Breadcrumbs are written to TCMU (M4 0x20000100 = A53 0x800100) so the
 * progress can be inspected from Linux with devmem after the reset.
 */
#include <stdint.h>
#include "rpmsg_lite.h"

#define REG32(a) (*(volatile unsigned int *)(a))

/* System Counter (safe-to-read reference; same counter as the A53
 * generic timer, 8 MHz) */
#define SCTR_CNTCV_LO 0x306C0008u
#define SCTR_HZ       8000000u

/* The peripheral read that kills the SoC while the MU session is up */
#define GPIO3_DR      0x30220000u

/* Breadcrumbs, readable from Linux: devmem 0x800100 / 0x800104 / ... */
#define DBG ((volatile unsigned int *)0x20000100)
/* DBG[0] state: 1=init 2=link-up 3=ept created
 * DBG[1] rpmsg datagrams received (peer hello)
 * DBG[2] heartbeat frames sent
 * DBG[5] low 32 bits of the loop counter (proves the loop is running)
 */

#define SHMEM_BASE     0xB8000000u
#define LOCAL_EPT_ADDR 30u

static volatile uint32_t peer_addr;
static volatile int peer_known;

static int32_t rx_cb(void *payload, uint32_t payload_len, uint32_t src,
		     void *priv)
{
	(void)payload;
	(void)payload_len;
	(void)priv;
	peer_addr = src;
	peer_known = 1;
	DBG[1]++;
	return RL_RELEASE;
}

int main(void)
{
	struct rpmsg_lite_instance *rl;
	struct rpmsg_lite_endpoint *ept;
	uint32_t n = 0;

	DBG[0] = 1;
	rl = rpmsg_lite_remote_init((void *)SHMEM_BASE,
				    RL_PLATFORM_IMX8MM_M4_USER_LINK_ID,
				    RL_NO_FLAGS);
	if (!rl) {
		DBG[0] = 0xDEAD;
		for (;;)
			;
	}

	/* Waits for the Linux virtio_rpmsg driver: from here on there is a
	 * live MU/virtio session (Linux kicks the MU on channel setup and
	 * on every buffer exchange). */
	rpmsg_lite_wait_for_link_up(rl, RL_BLOCK);
	DBG[0] = 2;
	ept = rpmsg_lite_create_ept(rl, LOCAL_EPT_ADDR, rx_cb, 0);
	DBG[0] = 3;

	for (;;) {
#if PERIPH_READ
		/* This single read access is the trigger. */
		(void)REG32(GPIO3_DR);
#else
		/* Control: SCTR read at the same rate is always safe. */
		(void)REG32(SCTR_CNTCV_LO);
#endif
		n++;
		DBG[5] = n;

		/* Roughly once a second, send a heartbeat so MU doorbell
		 * traffic keeps flowing in both directions (if a peer has
		 * talked to us). */
		if ((n & 0xFFFFF) == 0 && peer_known) {
			static const char hb[16] = "heartbeat";
			if (rpmsg_lite_send(rl, ept, peer_addr, (char *)hb,
					    sizeof(hb),
					    RL_DONT_BLOCK) == RL_SUCCESS)
				DBG[2]++;
		}
	}
}
