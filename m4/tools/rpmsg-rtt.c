/* SPDX-License-Identifier: MIT
 *
 * rpmsg-rtt.c — /dev/ttyRPMSG0 の echo で A53↔M4 往復時間を測る。
 * 使い方: rpmsg-rtt [回数 (既定 1000)]
 * 出力: min/median/p99/max と簡易ヒストグラム。片道 ≈ RTT/2。
 *
 * ビルド: aarch64-linux-gnu-gcc -static -O2 -o rpmsg-rtt rpmsg-rtt.c
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

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
	int fd = open("/dev/ttyRPMSG0", O_RDWR | O_NOCTTY);
	long long *rtt;
	struct termios tio;
	char tx[16] = "ping-0123456789";
	char rx[64];
	int i, lost = 0;

	if (fd < 0) {
		perror("open /dev/ttyRPMSG0");
		return 1;
	}
	tcgetattr(fd, &tio);
	cfmakeraw(&tio);
	tio.c_cc[VMIN] = sizeof(tx); /* 全バイト揃うまで read をブロック */
	tio.c_cc[VTIME] = 10;        /* ただし 1s で諦める */
	tcsetattr(fd, TCSANOW, &tio);

	rtt = calloc(n, sizeof(*rtt));

	/* ウォームアップ */
	write(fd, tx, sizeof(tx));
	read(fd, rx, sizeof(rx));

	for (i = 0; i < n; i++) {
		long long t0 = ns_now();
		int got = 0;

		write(fd, tx, sizeof(tx));
		while (got < (int)sizeof(tx)) {
			int r = read(fd, rx + got, sizeof(rx) - got);

			if (r <= 0)
				break;
			got += r;
		}
		if (got != (int)sizeof(tx)) {
			lost++;
			i--; /* 欠測はやり直し */
			if (lost > 50) {
				fprintf(stderr, "too many losses\n");
				return 1;
			}
			continue;
		}
		rtt[i] = ns_now() - t0;
	}

	qsort(rtt, n, sizeof(*rtt), cmp_ll);
	printf("n=%d lost=%d\n", n, lost);
	printf("RTT  min=%.1fus  median=%.1fus  p99=%.1fus  max=%.1fus\n",
	       rtt[0] / 1e3, rtt[n / 2] / 1e3, rtt[n * 99 / 100] / 1e3,
	       rtt[n - 1] / 1e3);
	printf("one-way (RTT/2) ~= %.1fus median\n", rtt[n / 2] / 2e3);

	/* 簡易ヒストグラム (25us ビン) */
	{
		int bins[20] = {0};

		for (i = 0; i < n; i++) {
			int b = rtt[i] / 25000;

			bins[b > 19 ? 19 : b]++;
		}
		for (i = 0; i < 20; i++) {
			if (!bins[i])
				continue;
			printf("%3d-%3dus %5d ", i * 25, (i + 1) * 25, bins[i]);
			for (int j = 0; j < bins[i] * 50 / n + 1; j++)
				putchar('#');
			putchar('\n');
		}
	}
	return 0;
}
