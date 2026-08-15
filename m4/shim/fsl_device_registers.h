/* SPDX-License-Identifier: MIT
 *
 * fsl_device_registers.h — rpmsg-lite の imx8mm ポートが要求する SDK
 * ヘッダの最小シム。本物の MCUXpresso SDK は使わない (10-cortex-m4.md)。
 * MU_M4_IRQn=97 は MIMX8MM6_cm4.h (NXP 公式) から採取した実値。
 */
#ifndef FSL_DEVICE_REGISTERS_H_
#define FSL_DEVICE_REGISTERS_H_

#include <stdint.h>

typedef int IRQn_Type;
#define MU_M4_IRQn 97
#define NUMBER_OF_INT_VECTORS (128)

/* ---- CMSIS 最小実装 (NVIC + バリア) ---- */
#define NVIC_ISER ((volatile uint32_t *)0xE000E100)
#define NVIC_ICER ((volatile uint32_t *)0xE000E180)
#define NVIC_IPR  ((volatile uint8_t *)0xE000E400)

static inline void NVIC_EnableIRQ(IRQn_Type irq)
{
	NVIC_ISER[irq >> 5] = 1u << (irq & 31);
}

static inline void NVIC_DisableIRQ(IRQn_Type irq)
{
	NVIC_ICER[irq >> 5] = 1u << (irq & 31);
}

static inline void NVIC_SetPriority(IRQn_Type irq, uint32_t prio)
{
	NVIC_IPR[irq] = (uint8_t)(prio << 4); /* 8MM M4 は 4bit 優先度 */
}

static inline void __NOP(void) { __asm volatile("nop"); }
static inline void __DSB(void) { __asm volatile("dsb" ::: "memory"); }
static inline void __ISB(void) { __asm volatile("isb" ::: "memory"); }
static inline void __disable_irq(void) { __asm volatile("cpsid i" ::: "memory"); }
static inline void __enable_irq(void) { __asm volatile("cpsie i" ::: "memory"); }

/* SCB (platform_in_isr が ICSR の VECTACTIVE を見る) */
typedef struct {
	volatile uint32_t CPUID;
	volatile uint32_t ICSR;
} SCB_Type;
#define SCB ((SCB_Type *)0xE000ED00)
#define SCB_ICSR_VECTACTIVE_Msk (0x1FFu)

/* rpmsg-lite の platform_time_delay が参照 (M4 root 実測 200MHz) */
#define SystemCoreClock (200000000u)
static inline void SystemCoreClockUpdate(void) {}

/* ---- MU (Messaging Unit) B 側 ----
 * レジスタ配置は i.MX6SX 以降の MU 共通 (linux drivers/mailbox/imx-mailbox.c
 * と同一): TR0-3 +0x00, RR0-3 +0x10, SR +0x20, CR +0x24 */
typedef struct {
	volatile uint32_t TR[4];
	volatile uint32_t RR[4];
	volatile uint32_t SR;
	volatile uint32_t CR;
} MU_Type;

#define MUB ((MU_Type *)0x30AB0000)

#endif
