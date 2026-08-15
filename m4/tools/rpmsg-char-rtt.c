/* SPDX-License-Identifier: MIT
 *
 * rpmsg-char-rtt.c — rpmsg_char で M4 echo と往復し RTT を測る。
 * tty 層 (行制御・多重 open の闇) を完全に迂回する、CAN 受信でも使う予定の
 * データグラム経路そのもの。
 *
 * 使い方: rpmsg-char-rtt [回数=1000]
 * 前提: modprobe rpmsg_ctrl; M4 側 echo (ept addr 30) 稼働中
 *
 * ビルド: aarch64-linux-gnu-gcc -static -O2 -o rpmsg-char-rtt rpmsg-char-rtt.c
 */
#include <fcntl.h>
#include <linux/rpmsg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <poll.h>
#include <time.h>
#include <unistd.h>

#define M4_EPT_ADDR 30

static long long ns_now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static int cmp_ll(const void *a, const void *b)
{
	long long x = *(const long long *)a, y = *(const long long *)b;

	return (x > y) - (x < y);
}

int main(int argc, char **argv)
{
	int n = argc > 1 ? atoi(argv[1]) : 1000;
	struct rpmsg_endpoint_info info;
	long long *rtt;
	char devpath[64];
	char tx[16] = "ping-char-00000";
	char rx[512];
	int ctrl, fd, i;

	ctrl = open("/dev/rpmsg_ctrl0", O_RDWR);
	if (ctrl < 0) {
		perror("open rpmsg_ctrl0 (modprobe rpmsg_ctrl?)");
		return 1;
	}
	memset(&info, 0, sizeof(info));
	strcpy(info.name, "kart-rtt");
	info.src = 0xFFFFFFFF; /* RPMSG_ADDR_ANY: カーネルに空きを採番させる
				* (固定値は再実行時に前の ept と衝突する — 実測) */
	info.dst = M4_EPT_ADDR;
	if (ioctl(ctrl, RPMSG_CREATE_EPT_IOCTL, &info) < 0) {
		perror("RPMSG_CREATE_EPT_IOCTL");
		return 1;
	}
	/* 直近に生えた /dev/rpmsgN = 一番大きい番号から試す */
	fd = -1;
	for (i = 7; i >= 0; i--) {
		snprintf(devpath, sizeof(devpath), "/dev/rpmsg%d", i);
		fd = open(devpath, O_RDWR);
		if (fd >= 0)
			break;
	}
	if (fd < 0) {
		perror("open /dev/rpmsgN");
		return 1;
	}
	fprintf(stderr, "using %s (src=0x%x dst=%d)\n", devpath, info.src,
		M4_EPT_ADDR);

	rtt = calloc(n, sizeof(*rtt));

	/* ウォームアップ (poll で可視化) */
	if (write(fd, tx, sizeof(tx)) < 0)
		perror("write");
	{
		struct pollfd pf = { .fd = fd, .events = POLLIN };
		int pr = poll(&pf, 1, 3000);

		fprintf(stderr, "warmup poll=%d revents=0x%x\n", pr, pf.revents);
		if (pr <= 0) {
			fprintf(stderr, "no echo within 3s\n");
			return 1;
		}
		fprintf(stderr, "warmup read=%zd\n", read(fd, rx, sizeof(rx)));
	}

	for (i = 0; i < n; i++) {
		long long t0;

		if (getenv("RTT_SLOW"))
			usleep(200000);
		t0 = ns_now();

		if (write(fd, tx, sizeof(tx)) != sizeof(tx)) {
			perror("write");
			return 1;
		}
		{
			struct pollfd pf = { .fd = fd, .events = POLLIN };

			if (poll(&pf, 1, 2000) <= 0) {
				fprintf(stderr, "STALL at iter %d\n", i);
				return 2;
			}
		}
		if (read(fd, rx, sizeof(rx)) <= 0) {
			perror("read");
			return 1;
		}
		rtt[i] = ns_now() - t0;
	}

	qsort(rtt, n, sizeof(*rtt), cmp_ll);
	printf("n=%d\n", n);
	printf("RTT  min=%.1fus  median=%.1fus  p99=%.1fus  max=%.1fus\n",
	       rtt[0] / 1e3, rtt[n / 2] / 1e3, rtt[n * 99 / 100] / 1e3,
	       rtt[n - 1] / 1e3);
	printf("one-way (RTT/2) ~= %.1fus median\n", rtt[n / 2] / 2e3);
	return 0;
}
