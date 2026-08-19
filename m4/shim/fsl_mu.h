/* SPDX-License-Identifier: MIT
 *
 * fsl_mu.h — rpmsg-lite が呼ぶ SDK MU API の最小シム。
 * ビット配置は SDK/linux と同一: SR/CR とも TE3-0=bits23-20, RF3-0=bits27-24。
 * rpmsg-lite 側は「(1<<27)>>ch = チャネル ch の RF/RIE」前提で書かれている。
 */
#ifndef FSL_MU_H_
#define FSL_MU_H_

#include "fsl_device_registers.h"

static inline void MU_Init(MU_Type *base)
{
	/* 割込は rpmsg-lite 側が明示的に有効化するので、ここでは全部落とす */
	base->CR = 0;
}

static inline void MU_EnableInterrupts(MU_Type *base, uint32_t mask)
{
	base->CR |= mask;
}

static inline void MU_DisableInterrupts(MU_Type *base, uint32_t mask)
{
	base->CR &= ~mask;
}

static inline uint32_t MU_GetStatusFlags(MU_Type *base)
{
	return base->SR;
}

static inline void MU_SendMsg(MU_Type *base, uint32_t ch, uint32_t msg)
{
	while (!(base->SR & ((1u << 23) >> ch)))
		; /* TX 空き待ち */
	base->TR[ch] = msg;
}

static inline uint32_t MU_ReceiveMsgNonBlocking(MU_Type *base, uint32_t ch)
{
	return base->RR[ch];
}

#endif
