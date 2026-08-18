/* SPDX-License-Identifier: MIT
 *
 * rsc_table.c — remoteproc リソーステーブル (SDK 非依存の自前定義)。
 *
 * mainline imx_rproc は ELF の .resource_table セクションを読んで
 * vdev (virtio-rpmsg) と vring の配置を知る。ここの da は
 * imx8mm-xpi-kart.dts の reserved-memory (vdev0vring0/1) と一致必須。
 * 構造体レイアウトは linux include/linux/remoteproc.h の fw_rsc_* と同一
 * (NXP デモ rsc_table.c と同値)。
 */
#include <stdint.h>

#define RSC_VDEV            3
#define VIRTIO_ID_RPMSG     7
#define RSC_VDEV_FEATURE_NS (1u << 0) /* name service announce を使う */

#define VDEV0_VRING_BASE 0xB8000000u
#define VRING_SIZE       0x8000u
#define VRING_ALIGN      0x1000u
#define RL_BUFFER_COUNT  256u

struct fw_rsc_vdev_vring {
	uint32_t da;
	uint32_t align;
	uint32_t num;
	uint32_t notifyid;
	uint32_t reserved;
} __attribute__((packed));

struct remote_resource_table {
	uint32_t version;
	uint32_t num;
	uint32_t reserved[2];
	uint32_t offset[1];
	/* vdev エントリ (type を先頭に含む展開形) */
	uint32_t type;
	uint32_t id;
	uint32_t notifyid;
	uint32_t dfeatures;
	uint32_t gfeatures;
	uint32_t config_len;
	uint8_t status;
	uint8_t num_of_vrings;
	uint8_t rsvd[2];
	struct fw_rsc_vdev_vring vring0;
	struct fw_rsc_vdev_vring vring1;
} __attribute__((packed));

__attribute__((section(".resource_table"), used))
const struct remote_resource_table resources = {
	.version = 1,
	.num = 1,
	.reserved = {0, 0},
	.offset = {
		__builtin_offsetof(struct remote_resource_table, type),
	},
	.type = RSC_VDEV,
	.id = VIRTIO_ID_RPMSG,
	.notifyid = 0,
	.dfeatures = RSC_VDEV_FEATURE_NS,
	.gfeatures = 0,
	.config_len = 0,
	.status = 0,
	.num_of_vrings = 2,
	.rsvd = {0, 0},
	.vring0 = {VDEV0_VRING_BASE, VRING_ALIGN, RL_BUFFER_COUNT, 0, 0},
	.vring1 = {VDEV0_VRING_BASE + VRING_SIZE, VRING_ALIGN, RL_BUFFER_COUNT, 1, 0},
};
