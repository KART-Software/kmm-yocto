/* SPDX-License-Identifier: MIT
 *
 * main.c — rpmsg echo (bare metal, SDK 非依存)
 *
 * Linux 側 (virtio_rpmsg + rpmsg_tty) と rpmsg-lite で通信する最小構成。
 * チャネル名 "rpmsg-tty" を name service で announce すると、mainline の
 * rpmsg_tty ドライバが自動 bind して Linux に /dev/ttyRPMSG0 が生える。
 * そこに write した文字列を M4 がエコーバックし、J64 (UART4) にもログを吐く。
 *
 * UART4 のレジスタ値出典は hello-world/hello.c と 04-pitfalls #25 参照。
 */
#include <stdint.h>
#include "rpmsg_lite.h"
#include "rpmsg_ns.h"

#define REG32(a) (*(volatile unsigned int *)(a))

/* ---- UART4 (hello-world から移植) ---- */
#define CCM_UART4_ROOT     REG32(0x3038B080)
#define CCM_CCGR_UART4_SET REG32(0x303844C4)
#define CCM_CCGR_MU_SET    REG32(0x30384214) /* MU ゲート (clk-imx8mm: 0x4210) */
#define SEL_UART4_RXD      REG32(0x3033050C)
#define UTXD REG32(0x30A60040)
#define UCR1 REG32(0x30A60080)
#define UCR2 REG32(0x30A60084)
#define UCR3 REG32(0x30A60088)
#define UFCR REG32(0x30A60090)
#define UBIR REG32(0x30A600A4)
#define UBMR REG32(0x30A600A8)
#define UTS  REG32(0x30A600B4)

/* TCMU ブレッドクラム (devmem 0x800100.. で A53 から読める) */
#define DBG ((volatile unsigned int *)0x20000100)

static void uart4_init(void)
{
	CCM_UART4_ROOT = (1u << 28) | (1u << 24); /* EN | sys_pll1_80m */
	CCM_CCGR_UART4_SET = 0x30;                /* M4 実効フィールド (pitfalls #25) */
	SEL_UART4_RXD = 2;
	UCR2 = 0;
	{
		unsigned int t = 0;
		while (!(UCR2 & 1) && ++t < 100000)
			;
	}
	UCR1 = 0x0001;
	UCR2 = 0x4027;
	UCR3 = 0x0704;
	UFCR = 0x0A81;
	UBIR = 0x47;   /* 115200 @ 80MHz */
	UBMR = 0xC34;
}

static void uart4_puts(const char *s)
{
	for (; *s; s++) {
		if (*s == '\n') {
			while (UTS & (1u << 4))
				;
			UTXD = '\r';
		}
		while (UTS & (1u << 4))
			;
		UTXD = (unsigned char)*s;
	}
}

/* ---- rpmsg echo 本体 ----
 * env_bm (ベアメタル環境) はキュー API 未実装なのでコールバック方式:
 * 受信 ISR コンテキストでバッファに写して旗を立て、main ループで
 * ログ出力とエコー送信を行う */
#define SHMEM_BASE     0xB8000000u
#define LOCAL_EPT_ADDR 30u

static char msg_buf[512];
static volatile uint32_t msg_len;
static volatile uint32_t msg_src;
static volatile int msg_ready;

static int32_t rx_cb(void *payload, uint32_t payload_len, uint32_t src,
		     void *priv)
{
	(void)priv;
	if (payload_len >= sizeof(msg_buf))
		payload_len = sizeof(msg_buf) - 1;
	if (!msg_ready) { /* 処理中の取りこぼしは捨てる (echo デモなので) */
		const char *p = payload;
		for (uint32_t i = 0; i < payload_len; i++)
			msg_buf[i] = p[i];
		msg_len = payload_len;
		msg_src = src;
		msg_ready = 1;
		DBG[1]++; /* rx カウント */
	}
	return RL_RELEASE;
}

int main(void)
{
	struct rpmsg_lite_instance *rl;
	struct rpmsg_lite_endpoint *ept;

	uart4_init();
	CCM_CCGR_MU_SET = 0x30; /* MU クロック (Linux 側も握っているが自衛) */
	DBG[0] = 1; /* phase: started */
	uart4_puts("\nkart M4: rpmsg echo starting\n");

	rl = rpmsg_lite_remote_init((void *)SHMEM_BASE,
				    RL_PLATFORM_IMX8MM_M4_USER_LINK_ID,
				    RL_NO_FLAGS);
	if (!rl) {
		uart4_puts("rpmsg init FAILED\n");
		for (;;)
			;
	}
	uart4_puts("waiting for link (Linux 側の vdev 初期化待ち)...\n");
	rpmsg_lite_wait_for_link_up(rl, RL_BLOCK);
	DBG[0] = 2; /* phase: link up */
	uart4_puts("link up\n");

	ept = rpmsg_lite_create_ept(rl, LOCAL_EPT_ADDR, rx_cb, 0);
	/* "rpmsg-tty" を名乗ると mainline rpmsg_tty が bind → /dev/ttyRPMSG0 */
	rpmsg_ns_announce(rl, ept, "rpmsg-tty", RL_NS_CREATE);
	DBG[0] = 3; /* phase: announced */
	uart4_puts("announced rpmsg-tty; echo ready\n");

	for (;;) {
		while (!msg_ready)
			__asm volatile("wfi");
		msg_buf[msg_len] = 0;
		uart4_puts("rx: ");
		uart4_puts(msg_buf);
		uart4_puts("\n");
		{
			int32_t rc = rpmsg_lite_send(rl, ept, msg_src, msg_buf,
						     msg_len, RL_BLOCK);
			DBG[2] = 0x1000 + (uint32_t)(-rc); /* send rc */
			DBG[3]++; /* echo 済み件数 */
			uart4_puts(rc == RL_SUCCESS ? "echoed\n" : "send FAILED\n");
		}
		msg_ready = 0;
	}
}
