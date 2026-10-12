// SPDX-License-Identifier: GPL-2.0-only
/*
 * mcore-keepalive — M コア (data-logger-zephyr の main-app) のキープアライブを受けて、
 * M コアが動いているかを /sys に出す (kmm-yocto issue #19)。
 *
 * M コアは rpmsg チャネル "mcore-keepalive" を告知し、1 秒ごとに 16 バイト (LE) を送る:
 *   u32 magic = 0x414B434D ("MCKA")  u16 proto = 1  u16 len = 16
 *   u32 uptime_ms (M コアが起動してからの時間)  u32 seq (送るたびに 1 増える)
 * M コアは Linux 側の宛先を知らないので、bind した時点で 1 通 ("hi") 送って覚えさせる。
 *
 * /sys/bus/rpmsg/devices/<dev>/ に出すもの:
 *   state           waiting (bind 後まだ 1 通も来ない) / alive / lost (timeout_ms 届かない)
 *   seq, uptime_ms  最後に受けたメッセージの値
 *   received        受けた正しいメッセージの数
 *   seq_gaps        seq が 1 ずつ増えなかった回数
 *   restarts        uptime_ms が減った (M コアが起動し直した) 回数
 *   bad             形が合わないメッセージの数
 *   last_rx_ms_ago  最後に受けてからの時間 (まだ無ければ -1)
 * 状態の切り替わり (届いた、途切れた、戻った、bind 後 timeout_ms 届かない) は
 * カーネルのログに 1 回ずつ出す。見るのは M コアが動いているかだけで、CAN などの
 * 機能の状態は含めない。
 */
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/rpmsg.h>
#include <linux/slab.h>
#include <linux/spinlock.h>
#include <linux/timer.h>

#define MCKA_MAGIC	0x414B434Du	/* "MCKA" (LE) */
#define MCKA_PROTO	1

struct mcka_msg {
	__le32 magic;
	__le16 proto;
	__le16 len;
	__le32 uptime_ms;
	__le32 seq;
} __packed;

enum mcka_state { MCKA_WAITING, MCKA_ALIVE, MCKA_LOST };

static const char * const mcka_state_names[] = {
	[MCKA_WAITING] = "waiting",
	[MCKA_ALIVE] = "alive",
	[MCKA_LOST] = "lost",
};

static unsigned int timeout_ms = 3000;
module_param(timeout_ms, uint, 0644);
MODULE_PARM_DESC(timeout_ms, "No keepalive for this long means the M-core is lost (default 3000)");

struct mcka_priv {
	struct rpmsg_device *rpdev;
	struct timer_list timer;
	spinlock_t lock;
	enum mcka_state state;
	bool warned_waiting;
	u32 seq;
	u32 uptime_ms;
	u64 received;
	u64 seq_gaps;
	u64 restarts;
	u64 bad;
	unsigned long last_rx;	/* jiffies */
	unsigned long bound;	/* jiffies */
};

static void mcka_timeout(struct timer_list *t)
{
	struct mcka_priv *p = from_timer(p, t, timer);
	unsigned long limit = msecs_to_jiffies(timeout_ms);
	unsigned long flags;
	enum { NONE, LOST, WAITING } ev = NONE;
	u32 seq = 0;

	spin_lock_irqsave(&p->lock, flags);
	if (p->state == MCKA_ALIVE) {
		/* 受信と入れ違いで古い期限が切れた場合は何もしない */
		if (time_after_eq(jiffies, p->last_rx + limit)) {
			p->state = MCKA_LOST;
			seq = p->seq;
			ev = LOST;
		}
	} else if (p->state == MCKA_WAITING && !p->warned_waiting) {
		p->warned_waiting = true;
		ev = WAITING;
	}
	spin_unlock_irqrestore(&p->lock, flags);

	if (ev == LOST)
		dev_warn(&p->rpdev->dev, "keepalive lost: nothing for %u ms (last seq %u)\n",
			 timeout_ms, seq);
	else if (ev == WAITING)
		dev_warn(&p->rpdev->dev, "no keepalive within %u ms after bind\n", timeout_ms);
}

static int mcka_cb(struct rpmsg_device *rpdev, void *data, int len, void *priv, u32 src)
{
	struct mcka_priv *p = dev_get_drvdata(&rpdev->dev);
	const struct mcka_msg *m = data;
	enum mcka_state prev;
	bool restarted = false;
	u32 seq, up, prev_up = 0;
	unsigned long flags;

	if (len != sizeof(*m) || le32_to_cpu(m->magic) != MCKA_MAGIC ||
	    le16_to_cpu(m->proto) != MCKA_PROTO || le16_to_cpu(m->len) != sizeof(*m)) {
		spin_lock_irqsave(&p->lock, flags);
		p->bad++;
		spin_unlock_irqrestore(&p->lock, flags);
		dev_warn_ratelimited(&rpdev->dev, "bad keepalive message (len %d)\n", len);
		return 0;
	}
	seq = le32_to_cpu(m->seq);
	up = le32_to_cpu(m->uptime_ms);

	spin_lock_irqsave(&p->lock, flags);
	prev = p->state;
	if (p->received) {
		if (up < p->uptime_ms) {
			p->restarts++;
			restarted = true;
			prev_up = p->uptime_ms;
		} else if (seq != p->seq + 1) {
			p->seq_gaps++;
		}
	}
	p->seq = seq;
	p->uptime_ms = up;
	p->received++;
	p->last_rx = jiffies;
	p->state = MCKA_ALIVE;
	mod_timer(&p->timer, p->last_rx + msecs_to_jiffies(timeout_ms));
	spin_unlock_irqrestore(&p->lock, flags);

	if (prev == MCKA_WAITING)
		dev_info(&rpdev->dev, "keepalive alive (seq %u, uptime %u ms)\n", seq, up);
	else if (prev == MCKA_LOST)
		dev_warn(&rpdev->dev, "keepalive back (seq %u, uptime %u ms)\n", seq, up);
	if (restarted)
		dev_warn(&rpdev->dev, "M-core restarted (uptime %u -> %u ms)\n", prev_up, up);
	return 0;
}

/* ---- /sys ---- */

#define MCKA_SHOW(name, fmt, expr)						\
static ssize_t name##_show(struct device *dev, struct device_attribute *attr,	\
			   char *buf)						\
{										\
	struct mcka_priv *p = dev_get_drvdata(dev);				\
	unsigned long flags;							\
	ssize_t n;								\
										\
	spin_lock_irqsave(&p->lock, flags);					\
	n = sysfs_emit(buf, fmt "\n", expr);					\
	spin_unlock_irqrestore(&p->lock, flags);				\
	return n;								\
}										\
static DEVICE_ATTR_RO(name)

MCKA_SHOW(state, "%s", mcka_state_names[p->state]);
MCKA_SHOW(seq, "%u", p->seq);
MCKA_SHOW(uptime_ms, "%u", p->uptime_ms);
MCKA_SHOW(received, "%llu", p->received);
MCKA_SHOW(seq_gaps, "%llu", p->seq_gaps);
MCKA_SHOW(restarts, "%llu", p->restarts);
MCKA_SHOW(bad, "%llu", p->bad);
MCKA_SHOW(last_rx_ms_ago, "%lld",
	  p->received ? (long long)jiffies_to_msecs(jiffies - p->last_rx) : -1LL);

static struct attribute *mcka_attrs[] = {
	&dev_attr_state.attr,
	&dev_attr_seq.attr,
	&dev_attr_uptime_ms.attr,
	&dev_attr_received.attr,
	&dev_attr_seq_gaps.attr,
	&dev_attr_restarts.attr,
	&dev_attr_bad.attr,
	&dev_attr_last_rx_ms_ago.attr,
	NULL,
};
ATTRIBUTE_GROUPS(mcka);

/* ---- bind ---- */

static int mcka_probe(struct rpmsg_device *rpdev)
{
	struct mcka_priv *p;
	int ret;

	p = devm_kzalloc(&rpdev->dev, sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;

	p->rpdev = rpdev;
	spin_lock_init(&p->lock);
	p->state = MCKA_WAITING;
	p->bound = jiffies;
	timer_setup(&p->timer, mcka_timeout, 0);
	dev_set_drvdata(&rpdev->dev, p);

	/* M コアは受けた送り元へ送るので、まず 1 通送って宛先を覚えさせる */
	ret = rpmsg_send(rpdev->ept, "hi", 2);
	if (ret)
		dev_warn(&rpdev->dev, "could not send hello: %d\n", ret);

	/* bind 後 timeout_ms 届かなければ 1 回だけログに出す */
	mod_timer(&p->timer, p->bound + msecs_to_jiffies(timeout_ms));

	dev_info(&rpdev->dev, "mcore-keepalive channel bound (remote ept 0x%x)\n", rpdev->dst);
	return 0;
}

static void mcka_remove(struct rpmsg_device *rpdev)
{
	struct mcka_priv *p = dev_get_drvdata(&rpdev->dev);

	timer_delete_sync(&p->timer);
	dev_info(&rpdev->dev, "mcore-keepalive channel removed\n");
}

static const struct rpmsg_device_id mcka_id_table[] = {
	{ .name = "mcore-keepalive" },
	{},
};
MODULE_DEVICE_TABLE(rpmsg, mcka_id_table);

static struct rpmsg_driver mcka_driver = {
	.probe = mcka_probe,
	.remove = mcka_remove,
	.callback = mcka_cb,
	.id_table = mcka_id_table,
	.drv = {
		.name = "mcore-keepalive",
		.dev_groups = mcka_groups,
	},
};
module_rpmsg_driver(mcka_driver);

MODULE_DESCRIPTION("M-core keepalive monitor over rpmsg");
MODULE_LICENSE("GPL");
