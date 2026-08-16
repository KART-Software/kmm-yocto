// SPDX-License-Identifier: GPL-2.0-only
/*
 * kart-rpmsg-can — Cortex-M4 CAN ゲートウェイを CAN netdev として見せる
 *
 * M4 側ファーム (data-logger-imx8mm-cortex-m4 apps/can-gw) が rpmsg
 * チャネル "kart-can" を NS 告知すると本ドライバが bind し、rpcan0 を
 * 登録する。以後 SocketCAN がそのまま使える (candump/kmm 無修正)。
 *
 * - vcan 型のプレーン netdev (candev ではない)。ビットレート等の
 *   netlink 設定は持たない — 物理側の設定は M4 ファームが持つ
 * - IFF_ECHO は立てない → 送信フレームのローカル配布 (他ソケットへの
 *   ループバック) は af_can が行う
 * - ワイヤ形式 16B は M4 側 can-gw / m4/can-sim と共通:
 *     { __le32 id; u8 dlc; u8 pad[3]; u8 data[8] }
 *   id は Linux canid_t の慣例 (bit31=EFF, bit30=RTR, 実 ID は下位ビット)
 * - probe 時に 2 バイトの "hi" を送る → M4 が返信先アドレスを学習する
 *   (rpmsg の NS 告知はリモート→ホスト片方向で、ホスト側 ept アドレスを
 *   リモートは知らないため。16B 未満のメッセージは両側とも無視する約束)
 */
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/if_arp.h>
#include <linux/can.h>
#include <linux/can/skb.h>
#include <linux/rpmsg.h>

struct kart_can_wire {
	__le32 id;
	u8 dlc;
	u8 pad[3];
	u8 data[8];
} __packed;

struct kart_can_priv {
	struct rpmsg_device *rpdev;
};

static int kart_can_open(struct net_device *ndev)
{
	netif_start_queue(ndev);
	return 0;
}

static int kart_can_stop(struct net_device *ndev)
{
	netif_stop_queue(ndev);
	return 0;
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

	/* xmit はアトミック文脈 — ブロックしない trysend。vring バッファ
	 * 枯渇 (M4 停止中など) は輻輳ではなくリンク断とみなしドロップ */
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

static void kart_can_setup(struct net_device *ndev)
{
	ndev->type = ARPHRD_CAN;
	ndev->mtu = CAN_MTU;	/* classic CAN のみ (ワイヤ形式が 8B 固定) */
	ndev->hard_header_len = 0;
	ndev->addr_len = 0;
	ndev->tx_queue_len = 0;
	ndev->flags = IFF_NOARP;
	ndev->netdev_ops = &kart_can_netdev_ops;
	ndev->needs_free_netdev = true;
}

static int kart_rpmsg_can_cb(struct rpmsg_device *rpdev, void *data, int len,
			     void *priv, u32 src)
{
	struct net_device *ndev = dev_get_drvdata(&rpdev->dev);
	struct kart_can_wire *w = data;
	struct can_frame *cf;
	struct sk_buff *skb;

	if (len != sizeof(*w))	/* ハンドシェイク等 — フレームではない */
		return 0;

	if (!netif_running(ndev)) {
		ndev->stats.rx_dropped++;
		return 0;
	}

	skb = alloc_can_skb(ndev, &cf);
	if (!skb) {
		ndev->stats.rx_dropped++;
		return 0;
	}

	cf->can_id = le32_to_cpu(w->id);
	cf->len = min_t(u8, w->dlc, CAN_MAX_DLEN);
	memcpy(cf->data, w->data, cf->len);

	ndev->stats.rx_packets++;
	ndev->stats.rx_bytes += cf->len;
	netif_rx(skb);
	return 0;
}

static int kart_rpmsg_can_probe(struct rpmsg_device *rpdev)
{
	struct net_device *ndev;
	struct kart_can_priv *priv;
	int ret;

	ndev = alloc_netdev(sizeof(*priv), "rpcan%d", NET_NAME_ENUM,
			    kart_can_setup);
	if (!ndev)
		return -ENOMEM;

	priv = netdev_priv(ndev);
	priv->rpdev = rpdev;
	dev_set_drvdata(&rpdev->dev, ndev);
	SET_NETDEV_DEV(ndev, &rpdev->dev);

	ret = register_netdev(ndev);
	if (ret) {
		free_netdev(ndev);
		return ret;
	}

	/* M4 に返信先アドレスを教える (中身は見ない、src だけ学習される) */
	rpmsg_send(rpdev->ept, "hi", 2);

	netdev_info(ndev, "kart-can channel bound (remote ept 0x%x)\n",
		    rpdev->dst);
	return 0;
}

static void kart_rpmsg_can_remove(struct rpmsg_device *rpdev)
{
	struct net_device *ndev = dev_get_drvdata(&rpdev->dev);

	unregister_netdev(ndev);	/* needs_free_netdev が解放する */
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

MODULE_DESCRIPTION("CAN netdev backed by rpmsg (kart Cortex-M4 gateway)");
MODULE_LICENSE("GPL");
