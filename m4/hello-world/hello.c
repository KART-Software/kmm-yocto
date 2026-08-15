/* SPDX-License-Identifier: MIT
 *
 * hello.c — XPI-iMX8MM Cortex-M4 ベアメタル hello world (SDK 非依存)
 *
 * 全部入り 1 ファイル: ベクタテーブル + スタートアップ + UART4 直叩き。
 * remoteproc (/sys/class/remoteproc/remoteproc0) から起動する前提。
 * ELF ローダが TCML/TCMU へ配置と .bss ゼロ化まで面倒を見るので、
 * スタートアップは main を呼ぶだけでよい。
 *
 * UART4 = J64 (M4 デバッグコンソール、115200 8N1)。RDC により M4 ドメイン
 * 割当済みで A53/Linux は触らない (docs/imx8mm-xpi-bringup 参照)。
 *
 * レジスタ値の出典 (全て実ソースから採取):
 *  - CCM: linux clk-imx8mm.c — uart4 root = base+0xb080 (mux0=osc_24m),
 *    gate = base+0x44c0
 *  - IOMUX: imx8mm-pinfunc.h — UART4_RXD mux 0x24C conf 0x4B4,
 *    UART4_TXD mux 0x250 conf 0x4B8, RX daisy 0x50C val 2 (DCE)
 *  - UART IP: i.MX 系共通 (imx.c serial driver と RM)
 */

#define REG32(a) (*(volatile unsigned int *)(a))

/* ---- CCM (クロック) ---- */
#define CCM_UART4_ROOT   REG32(0x3038B080) /* target root: bit28=EN, 26:24=mux */
#define CCM_CCGR_UART4     REG32(0x303844C0) /* gate 読み出し用 */
#define CCM_CCGR_UART4_SET REG32(0x303844C4) /* gate SET: 直書きはドメイン
	アクセス制御で無視される (実測: 書いても 0 のまま)。SET 経由が正解 */

/* ---- IOMUXC (ピンマルチ) ---- */
#define MUX_UART4_RXD    REG32(0x3033024C) /* ALT0 = UART4_DCE_RX */
#define MUX_UART4_TXD    REG32(0x30330250) /* ALT0 = UART4_DCE_TX */
#define CONF_UART4_RXD   REG32(0x303304B4)
#define CONF_UART4_TXD   REG32(0x303304B8)
#define SEL_UART4_RXD    REG32(0x3033050C) /* input daisy: 2 = UART4_RXD pad */

/* ---- UART4 ---- */
#define UART4_BASE 0x30A60000
#define UTXD  REG32(UART4_BASE + 0x40)
#define UCR1  REG32(UART4_BASE + 0x80)
#define UCR2  REG32(UART4_BASE + 0x84)
#define UCR3  REG32(UART4_BASE + 0x88)
#define UFCR  REG32(UART4_BASE + 0x90)
#define UBIR  REG32(UART4_BASE + 0xA4)
#define UBMR  REG32(UART4_BASE + 0xA8)
#define UTS   REG32(UART4_BASE + 0xB4)

#define UTS_TXFULL (1u << 4)

/* デバッグ用ブレッドクラム: TCMU 先頭付近に進行状況を書く。
 * A53 から devmem 0x00800100.. で読める (UART が死んでいても状況が分かる) */
#define DBG ((volatile unsigned int *)0x20000100)

static void uart4_init(void)
{
	/* クロック: sys_pll1_80m を選択して root を有効化、ゲートを開く。
	 * CCGR は「書いた側のドメインの SETTING フィールドにしか書けない」
	 * (CCM の権限制御)。M4 からの実効フィールドは bits[5:4] で、値は
	 * SDK デモが残した実測 0x30 をリプレイ (0x3 を書いても無言で棄却
	 * される — 実測で確認)。 */
	CCM_UART4_ROOT = (1u << 28) | (1u << 24);   /* EN | mux1 = sys_pll1_80m */
	CCM_CCGR_UART4_SET = 0x30;                  /* SETTING2 = run/wait */
	DBG[1] = CCM_UART4_ROOT;
	DBG[2] = CCM_CCGR_UART4;

	/* ピン: UART4_RXD/TXD パッドはリセット既定が ALT0=UART4 (実測 0)。
	 * RX の入力セレクタだけ明示。conf は SDK 実効値 0x16 */
	MUX_UART4_RXD = 0;
	MUX_UART4_TXD = 0;
	SEL_UART4_RXD = 2;
	CONF_UART4_RXD = 0x16;
	CONF_UART4_TXD = 0x16;

	/* UART: ソフトリセット (完了ポーリング) → 8N1 115200 (80MHz) */
	UCR2 = 0;                       /* SRST=0: リセット要求 */
	{
		unsigned int t = 0;
		while (!(UCR2 & 1) && ++t < 100000)
			;
		DBG[6] = t;             /* リセット完了までの回数 (タイムアウト検出) */
	}
	UCR1 = 0x0001;                  /* UARTEN */
	UCR2 = 0x4027;                  /* IRTS | WS(8bit) | TXEN | RXEN | !SRST */
	UCR3 = 0x0704;                  /* RXDMUXSEL ほか (SDK 実効値) */
	UFCR = 0x0A81;                  /* TXTL=2, RFDIV=/1, RXTL=1 */
	UBIR = 0x47;                    /* 115200 = 80M * 72/(16*3125) */
	UBMR = 0xC34;
	DBG[3] = UTS;
	DBG[4] = UCR2;
}

static void uart4_putc(char c)
{
	while (UTS & UTS_TXFULL)
		;
	UTXD = (unsigned char)c;
}

static void uart4_puts(const char *s)
{
	for (; *s; s++) {
		if (*s == '\n')
			uart4_putc('\r');
		uart4_putc(*s);
	}
}

static void uart4_put_dec(unsigned int v)
{
	char buf[10];
	int i = 0;

	do {
		buf[i++] = '0' + v % 10;
		v /= 10;
	} while (v);
	while (i)
		uart4_putc(buf[--i]);
}

static void main_loop(void)
{
	unsigned int tick = 0;

	DBG[0] = 0x11111111;            /* phase: 開始 */
	uart4_init();
	DBG[0] = 0x22222222;            /* phase: uart 初期化済み */
	uart4_puts("\nkart M4: hello from hand-written bare metal!\n");
	DBG[0] = 0x33333333;            /* phase: バナー送信完了 (TXFULL 待ちで固まればここに来ない) */

	for (;;) {
		/* M4 root は 200MHz (SPL 既定)。ざっくり 1 秒ディレイ */
		for (volatile unsigned int i = 0; i < 20000000u; i++)
			;
		tick++;
		DBG[5] = tick;
		uart4_puts("tick ");
		uart4_put_dec(tick);
		uart4_puts("\n");
	}
}

/* ---- スタートアップ & ベクタテーブル ---- */

void Reset_Handler(void)
{
	main_loop();
	for (;;)
		;
}

static void Default_Handler(void)
{
	for (;;)
		;
}

extern unsigned int _estack; /* リンカスクリプトが TCMU 上端に置く */

__attribute__((section(".vectors"), used))
void (* const vector_table[])(void) = {
	(void (*)(void))&_estack, /* 0: 初期 SP */
	Reset_Handler,            /* 1: リセット */
	Default_Handler,          /* 2: NMI */
	Default_Handler,          /* 3: HardFault */
};
