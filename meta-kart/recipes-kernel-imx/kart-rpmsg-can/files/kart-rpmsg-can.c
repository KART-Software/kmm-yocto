// SPDX-License-Identifier: GPL-2.0-only
/*
 * kart-rpmsg-can — Cortex-M4 CAN ゲートウェイを SocketCAN の candev として見せる
 *
 * M4 側ファーム (data-logger-imx8mm-cortex-m4 apps/can-gw、テスト用は
 * m4/can-sim) が rpmsg チャネル "kart-can" を NS 告知すると本ドライバが
 * bind し、rpcan0 を CAN デバイスとして登録する。以後 SocketCAN と
 * `ip link`/netlink がそのまま使える。
 *
 * candev 化 (旧: 生 netdev):
 *  - alloc_candev/register_candev で ARPHRD_CAN + can_priv を持つ本物の
 *    CAN デバイスになる (`ip -d link show rpcan0` が can 型を表示)。
 *  - 実タイミング (tq/brp) は M4 の CAN コントローラ (MCP2518FD) が持つので、
 *    Linux 側は bitrate_const で許可ビットレートを列挙するだけ。netlink で
 *    設定された bitrate / ctrlmode は open 時に M4 へ制御メッセージで転送する。
 *  - デフォルト 500k を probe で入れておくので、明示 bitrate 無しの
 *    `ip link set rpcan0 up` でも上がる。
 *
 * ワイヤ形式 (M4 の can-gw / can-sim と共通):
 *  - データフレーム = 16B: { __le32 id; u8 dlc; u8 pad[3]; u8 data[8] }
 *    id は Linux canid_t 慣例 (bit31=EFF, bit30=RTR)。
 *  - 制御メッセージ = 8B: { u8 magic=0xC7; u8 cmd; u8 flags; u8 rsvd; __le32 arg }
 *    16B フレームと長さで区別。Linux→M4 が bitrate/mode/start/stop を伝え、
 *    M4→Linux が CAN 状態変化を伝える (実ゲートウェイが対応。sim は制御を
 *    無視し peer 学習のみ行うので互換)。16B 未満/不一致は両側とも無視。
 */
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/can.h>
#include <linux/can/dev.h>
#include <linux/can/error.h>
#include <linux/can/skb.h>
#include <linux/rpmsg.h>

struct kart_can_wire {
	__le32 id;
	u8 dlc;
	u8 pad[3];
	u8 data[8];
} __packed;

#define KART_CAN_CTRL_MAGIC	0xC7
enum {
	KART_CAN_CMD_SET_BITRATE = 1,	/* Linux→M4: arg = bitrate [bps] */
	KART_CAN_CMD_SET_MODE    = 2,	/* Linux→M4: flags = ctrlmode ビット */
	KART_CAN_CMD_START       = 3,	/* Linux→M4: CAN 起動 (ip link up) */
	KART_CAN_CMD_STOP        = 4,	/* Linux→M4: CAN 停止 (ip link down) */
	KART_CAN_EVT_STATE       = 5,	/* M4→Linux: arg = enum can_state */
};

struct kart_can_ctrl {
	u8 magic;
	u8 cmd;
	u8 flags;	/* SET_MODE: bit0=listen-only bit1=loopback */
	u8 rsvd;
	__le32 arg;
} __packed;

#define KART_CAN_MODE_LISTENONLY	BIT(0)
#define KART_CAN_MODE_LOOPBACK		BIT(1)

struct kart_can_priv {
	struct can_priv can;		/* 先頭必須 (netdev_priv → can_priv) */
	struct rpmsg_device *rpdev;
};

/* 実タイミングは M4 側。Linux は許可ビットレートを列挙するだけ */
static const u32 kart_can_bitrates[] = {
	125000, 250000, 500000, 1000000,
};

static int kart_can_ctrl_send(struct kart_can_priv *priv, u8 cmd, u8 flags,
			      u32 arg)
{
	struct kart_can_ctrl c = {
		.magic = KART_CAN_CTRL_MAGIC,
		.cmd = cmd,
		.flags = flags,
		.arg = cpu_to_le32(arg),
	};

	/* atomic 文脈から呼ばれ得る (ndo_stop 等)。ブロックしない */
	return rpmsg_trysend(priv->rpdev->ept, &c, sizeof(c));
}

static int kart_can_open(struct net_device *ndev)
{
	struct kart_can_priv *priv = netdev_priv(ndev);
	u8 mode = 0;
	int err;

	err = open_candev(ndev);	/* bittiming 検証・状態遷移 */
	if (err)
		return err;

	if (priv->can.ctrlmode & CAN_CTRLMODE_LISTENONLY)
		mode |= KART_CAN_MODE_LISTENONLY;
	if (priv->can.ctrlmode & CAN_CTRLMODE_LOOPBACK)
		mode |= KART_CAN_MODE_LOOPBACK;

	/* M4 へ設定を転送 (最初の制御メッセージで M4 は返信先 ept も学習する)。
	 * sim は制御を無視して streaming を始めるだけなので互換 */
	kart_can_ctrl_send(priv, KART_CAN_CMD_SET_BITRATE, 0,
			   priv->can.bittiming.bitrate);
	kart_can_ctrl_send(priv, KART_CAN_CMD_SET_MODE, mode, 0);
	kart_can_ctrl_send(priv, KART_CAN_CMD_START, 0, 0);

	priv->can.state = CAN_STATE_ERROR_ACTIVE;
	netif_start_queue(ndev);
	return 0;
}

static int kart_can_stop(struct net_device *ndev)
{
	struct kart_can_priv *priv = netdev_priv(ndev);

	netif_stop_queue(ndev);
	kart_can_ctrl_send(priv, KART_CAN_CMD_STOP, 0, 0);
	priv->can.state = CAN_STATE_STOPPED;
	close_candev(ndev);
	return 0;
}

/* bus-off 後の再起動 (ip link set rpcan0 type can restart / 自動 restart-ms) */
static int kart_can_set_mode(struct net_device *ndev, enum can_mode mode)
{
	struct kart_can_priv *priv = netdev_priv(ndev);

	switch (mode) {
	case CAN_MODE_START:
		kart_can_ctrl_send(priv, KART_CAN_CMD_START, 0, 0);
		priv->can.state = CAN_STATE_ERROR_ACTIVE;
		netif_wake_queue(ndev);
		return 0;
	default:
		return -EOPNOTSUPP;
	}
}

static netdev_tx_t kart_can_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct kart_can_priv *priv = netdev_priv(ndev);
	struct can_frame *cf = (struct can_frame *)skb->data;
	struct kart_can_wire w = {};
	int ret;

	if (can_dropped_invalid_skb(ndev, skb))
		return NETDEV_TX_OK;

	w.id = cpu_to_le32(cf->can_id);
	w.dlc = cf->len;
	memcpy(w.data, cf->data, cf->len);

	/* xmit はアトミック文脈 — ブロックしない trysend。vring 枯渇
	 * (M4 停止中など) は輻輳ではなくリンク断とみなしドロップ。
	 * 送信フレームの他ソケットへのローカル配布 (echo) は af_can が行う */
	ret = rpmsg_trysend(priv->rpdev->ept, &w, sizeof(w));
	if (ret) {
		ndev->stats.tx_dropped++;
	} else {
		ndev->stats.tx_packets++;
		ndev->stats.tx_bytes += cf->len;
	}
	consume_skb(skb);
	return NETDEV_TX_OK;
}

static const struct net_device_ops kart_can_netdev_ops = {
	.ndo_open = kart_can_open,
	.ndo_stop = kart_can_stop,
	.ndo_start_xmit = kart_can_xmit,
};

/* M4 からのデータフレーム (16B) を SocketCAN へ注入 */
static void kart_can_rx_frame(struct net_device *ndev,
			      const struct kart_can_wire *w)
{
	struct can_frame *cf;
	struct sk_buff *skb;

	if (!netif_running(ndev)) {
		ndev->stats.rx_dropped++;
		return;
	}

	skb = alloc_can_skb(ndev, &cf);
	if (!skb) {
		ndev->stats.rx_dropped++;
		return;
	}

	cf->can_id = le32_to_cpu(w->id);
	cf->len = min_t(u8, w->dlc, CAN_MAX_DLEN);
	memcpy(cf->data, w->data, cf->len);

	ndev->stats.rx_packets++;
	ndev->stats.rx_bytes += cf->len;
	netif_rx(skb);
}

/* M4 からの制御イベント (8B) — 今は CAN 状態変化のみ */
static void kart_can_rx_ctrl(struct net_device *ndev,
			     const struct kart_can_ctrl *c)
{
	struct kart_can_priv *priv = netdev_priv(ndev);
	u32 arg = le32_to_cpu(c->arg);

	if (c->magic != KART_CAN_CTRL_MAGIC)
		return;

	if (c->cmd == KART_CAN_EVT_STATE && arg <= CAN_STATE_BUS_OFF) {
		enum can_state new_state = arg;

		if (new_state != priv->can.state) {
			priv->can.state = new_state;
			if (new_state == CAN_STATE_BUS_OFF)
				can_bus_off(ndev);
		}
	}
}

static int kart_rpmsg_can_cb(struct rpmsg_device *rpdev, void *data, int len,
			     void *priv, u32 src)
{
	struct net_device *ndev = dev_get_drvdata(&rpdev->dev);

	if (len == sizeof(struct kart_can_wire))
		kart_can_rx_frame(ndev, data);
	else if (len == sizeof(struct kart_can_ctrl))
		kart_can_rx_ctrl(ndev, data);
	/* それ以外 (ハンドシェイク等) は無視 */
	return 0;
}

static int kart_rpmsg_can_probe(struct rpmsg_device *rpdev)
{
	struct net_device *ndev;
	struct kart_can_priv *priv;
	int ret;

	ndev = alloc_candev(sizeof(*priv), 1);
	if (!ndev)
		return -ENOMEM;

	priv = netdev_priv(ndev);
	priv->rpdev = rpdev;
	priv->can.clock.freq = 40000000;	/* MCP2518FD 40MHz (公称) */
	priv->can.bitrate_const = kart_can_bitrates;
	priv->can.bitrate_const_cnt = ARRAY_SIZE(kart_can_bitrates);
	priv->can.ctrlmode_supported =
		CAN_CTRLMODE_LISTENONLY | CAN_CTRLMODE_LOOPBACK;
	priv->can.do_set_mode = kart_can_set_mode;
	/* 明示 bitrate 無しの `ip link up` でも上がるようデフォルトを入れる */
	priv->can.bittiming.bitrate = 500000;

	ndev->netdev_ops = &kart_can_netdev_ops;
	/* IFF_ECHO は立てない → 送信フレームの他ソケットへのローカル配布は
	 * af_can が行う (echo skb を自前管理しない) */

	dev_set_drvdata(&rpdev->dev, ndev);
	SET_NETDEV_DEV(ndev, &rpdev->dev);

	ret = register_candev(ndev);
	if (ret) {
		free_candev(ndev);
		return ret;
	}

	netdev_info(ndev, "kart-can channel bound (remote ept 0x%x)\n",
		    rpdev->dst);
	return 0;
}

static void kart_rpmsg_can_remove(struct rpmsg_device *rpdev)
{
	struct net_device *ndev = dev_get_drvdata(&rpdev->dev);

	unregister_candev(ndev);
	free_candev(ndev);
}

static const struct rpmsg_device_id kart_rpmsg_can_id_table[] = {
	{ .name = "kart-can" },
	{},
};
MODULE_DEVICE_TABLE(rpmsg, kart_rpmsg_can_id_table);

static struct rpmsg_driver kart_rpmsg_can_driver = {
	.probe = kart_rpmsg_can_probe,
	.remove = kart_rpmsg_can_remove,
	.callback = kart_rpmsg_can_cb,
	.id_table = kart_rpmsg_can_id_table,
	.drv = {
		.name = "kart-rpmsg-can",
	},
};
module_rpmsg_driver(kart_rpmsg_can_driver);

MODULE_DESCRIPTION("CAN candev backed by rpmsg (kart Cortex-M4 gateway)");
MODULE_LICENSE("GPL");
