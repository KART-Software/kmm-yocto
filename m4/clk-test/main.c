/* SPDX-License-Identifier: MIT
 *
 * clk-test — M4 から ECSPI2 クロックを立てて触れるかのブレッドクラム実験。
 *
 * 背景: Linux DT で ecspi2 を disabled にした (M4 譲渡)。CCGR の domain1
 * フィールドは Linux (domain0) から書けない (実測)。M4 自身で CCGR を書き、
 * ECSPI2 レジスタ read が生還するかを段階マーカーで確定する。
 *
 * ブレッドクラム (A53 から devmem 0x800100 で読む。SoC リセット後も残る):
 *   DBG[0]: 0xA1=起動 0xA2=CCM read 生還 0xA3=ECSPI read 生還 (ループ加算)
 *   DBG[1]: CCGR(0x30384080) の読み値 — M4 write が domain1 に効いたか
 *   DBG[2]: ECSPI2_STATREG の読み値
 *   DBG[3]: ループ回数
 *
 * rpmsg 無し・rsc_table のみ (remoteproc がロードできる最小構成)。
 */
#include <stdint.h>

#define REG32(a) (*(volatile unsigned int *)(a))
#define DBG ((volatile unsigned int *)0x20000100)

/* startup.c のベクタが参照する (rpmsg-lite 由来)。本実験では未使用 */
int MU_M4_IRQHandler(void)
{
	return 0;
}

#define CCM_CCGR_ECSPI2      0x30384080u
#define CCM_CCGR_ECSPI2_SET  0x30384084u
#define ECSPI2_STATREG       0x30830018u	/* CONREG=0x08, STATREG=0x18 */

int main(void)
{
	uint32_t i;

	DBG[0] = 0xA1;			/* 起動した */

	/* CCGR write (posted — MU バグの教訓では write は安全) */
	REG32(CCM_CCGR_ECSPI2_SET) = 0x3333;

	DBG[1] = REG32(CCM_CCGR_ECSPI2);	/* CCM read — 効いたか */
	DBG[0] = 0xA2;			/* CCM read 生還 */

	DBG[2] = REG32(ECSPI2_STATREG);	/* ★ここが本丸: ECSPI2 read */
	DBG[0] = 0xA3;			/* ECSPI read 生還! */

	for (i = 0;; i++) {
		DBG[3] = i;
		DBG[2] = REG32(ECSPI2_STATREG);	/* 連続 read 耐久 */
	}
	return 0;
}
