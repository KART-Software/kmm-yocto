/* SPDX-License-Identifier: MIT
 *
 * startup.c — ベクタテーブル (割込あり版) + リセットハンドラ。
 * MU_M4_IRQn=97 に rpmsg-lite の MU_M4_IRQHandler を配線する。
 * ELF ローダが .bss ゼロ化までやるので Reset は main を呼ぶだけ。
 */
#include <stdint.h>

extern uint32_t _estack;
extern int main(void);
extern int32_t MU_M4_IRQHandler(void); /* rpmsg-lite platform 層 */

void Reset_Handler(void)
{
	main();
	for (;;)
		;
}

static void Default_Handler(void)
{
	for (;;)
		;
}

static void MU_IRQ_Wrapper(void)
{
	(void)MU_M4_IRQHandler();
}

#define MU_VEC (16 + 97)

/* 16 例外 + 128 IRQ。MU (16+97) だけ実装、他は無限ループ */
__attribute__((section(".vectors"), used))
void (* const vector_table[16 + 128])(void) = {
	[0] = (void (*)(void))&_estack,
	[1] = Reset_Handler,
	[2 ... MU_VEC - 1] = Default_Handler,
	[MU_VEC] = MU_IRQ_Wrapper,
	[MU_VEC + 1 ... 16 + 127] = Default_Handler,
};
