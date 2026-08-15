/* SPDX-License-Identifier: MIT
 *
 * main.c — CAN フレームシミュレータ (bare metal, rpmsg ストリーム)
 *
 * kmm の MockCanSource と同じ合成フレーム (ID 0x5F0-0x5F4, u16 BE 詰め) を
 * 33ms ごとに rpmsg で流す。実 CAN (MCP2518FD) 移管前の全チェーン検証用。
 *
 * プロトコル: Linux 側 (kmm RpmsgCanSource) が任意のデータグラムを送って
 * くる ("hi") と、その送信元アドレスに向けてストリーム開始。
 * ワイヤ形式 16B: [u32le id][u8 dlc][3B pad][8B data] — canbus.cpp と共有。
 *
 * ペーシングは System Counter (SCTR, 8MHz — A53 の generic timer と同一の
 * カウンタ)。将来のレイテンシ計測でもこのカウンタ値をタイムスタンプに使う。
 */
#include <stdint.h>
#include "rpmsg_lite.h"

#define REG32(a) (*(volatile unsigned int *)(a))

/* ---- System Counter (読み出し専用窓口) ---- */
#define SCTR_CNTCV_LO REG32(0x306C0008)
#define SCTR_CNTCV_HI REG32(0x306C000C)
#define SCTR_HZ 8000000u

static uint64_t sctr_now(void)
{
	uint32_t hi, lo;

	do {
		hi = SCTR_CNTCV_HI;
		lo = SCTR_CNTCV_LO;
	} while (hi != SCTR_CNTCV_HI);
	return ((uint64_t)hi << 32) | lo;
}

/* ---- ブレッドクラム (devmem 0x800100..) ---- */
#define DBG ((volatile unsigned int *)0x20000100)

/* ---- rpmsg ---- */
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
	peer_addr = src;   /* "hi" の送信元へストリームを向ける */
	peer_known = 1;
	DBG[1]++;          /* hello 受信回数 */
	return RL_RELEASE;
}

/* kmm canbus.cpp の RpmsgCanWire と同一レイアウト */
struct wire {
	uint32_t id;
	uint8_t dlc;
	uint8_t pad[3];
	uint8_t data[8];
};

static void put_u16be(struct wire *w, int slot, uint32_t v)
{
	w->data[slot * 2] = (uint8_t)(v >> 8);
	w->data[slot * 2 + 1] = (uint8_t)v;
}

static void send_frame(struct rpmsg_lite_instance *rl,
		       struct rpmsg_lite_endpoint *ept, struct wire *w)
{
	/* Linux 側が止まっていても詰まらないよう非ブロック送信で捨てる */
	if (rpmsg_lite_send(rl, ept, peer_addr, (char *)w, sizeof(*w),
			    RL_DONT_BLOCK) == RL_SUCCESS)
		DBG[2]++;  /* 送信フレーム数 */
	else
		DBG[3]++;  /* ドロップ数 */
}

int main(void)
{
	struct rpmsg_lite_instance *rl;
	struct rpmsg_lite_endpoint *ept;
	uint64_t next;
	uint32_t t = 0; /* ms 相当 (33ms 刻みで加算) — Mock の t と同じ役割 */

	DBG[0] = 1;
	rl = rpmsg_lite_remote_init((void *)SHMEM_BASE,
				    RL_PLATFORM_IMX8MM_M4_USER_LINK_ID,
				    RL_NO_FLAGS);
	if (!rl) {
		DBG[0] = 0xDEAD;
		for (;;)
			;
	}
	rpmsg_lite_wait_for_link_up(rl, RL_BLOCK);
	DBG[0] = 2;
	ept = rpmsg_lite_create_ept(rl, LOCAL_EPT_ADDR, rx_cb, 0);
	DBG[0] = 3;

	next = sctr_now();
	for (;;) {
		struct wire w;
		uint32_t i;

		/* 33ms 待ち (SCTR ベース) */
		next += SCTR_HZ * 33 / 1000;
		while (sctr_now() < next)
			;
		t += 33;
		DBG[4] = t;

		if (!peer_known)
			continue;

		/* MockCanSource::generateBatch と同じ式 */
		for (i = 0; i < 8; i++)
			w.pad[i % 3] = 0; /* pad clear (慣習) */

		w.id = 0x5F0; w.dlc = 8;
		put_u16be(&w, 0, t % 10000);        /* rpm */
		put_u16be(&w, 1, t % 1000);         /* throttle *10 */
		put_u16be(&w, 2, t % 1400);         /* engineTemp *10 */
		put_u16be(&w, 3, t % 1600);         /* oilTemp *10 */
		send_frame(rl, ept, &w);

		w.id = 0x5F1; w.dlc = 8;
		put_u16be(&w, 0, t % 1200);         /* oilPressure *10 */
		put_u16be(&w, 1, t % 5000);         /* gearVoltage *1000 */
		put_u16be(&w, 2, (t % 13000) / 10); /* battery *100 */
		put_u16be(&w, 3, 700 + t % 600);    /* lambda *1000 */
		send_frame(rl, ept, &w);

		w.id = 0x5F2; w.dlc = 8;
		put_u16be(&w, 0, (t % 10000) / 10); /* manifold *10 */
		put_u16be(&w, 1, t % 3000);         /* fuelPressure *10 */
		put_u16be(&w, 2, t % 6000);         /* brakeFront *10 */
		put_u16be(&w, 3, 6000 - t % 6000);  /* brakeRear *10 */
		send_frame(rl, ept, &w);

		w.id = 0x5F3; w.dlc = 8;
		put_u16be(&w, 0, ((t % 10000) / 5000) ? 1 : 0); /* fan */
		put_u16be(&w, 1, ((t % 8000) / 4000) ? 2 : 1);  /* ist up/down */
		put_u16be(&w, 2, t % 5000);         /* inputRpm */
		put_u16be(&w, 3, t % 4500);         /* outputRpm */
		send_frame(rl, ept, &w);

		w.id = 0x5F4; w.dlc = 8;
		put_u16be(&w, 0, t % 1200);         /* oilTemp2 *10 */
		put_u16be(&w, 1, t % 1200);         /* oilTemp3 *10 */
		put_u16be(&w, 2, t % 1200);         /* coolant *10 */
		put_u16be(&w, 3, 0);
		send_frame(rl, ept, &w);
	}
}
