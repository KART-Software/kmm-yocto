/* SPDX-License-Identifier: MIT
 *
 * libc_min.c — -nostdlib ビルド用の最小 libc。
 * rpmsg-lite (bare-metal env) が要求するものだけ:
 *  - malloc/free: 初期化時にしか確保しないのでバンプアロケータ + free 無視
 *  - mem / str 系: 素朴実装 (gcc が memcpy 呼び出しを合成するので必須)
 */
#include <stddef.h>

static char heap[16 * 1024] __attribute__((aligned(8)));
static size_t heap_off;

void *malloc(size_t size)
{
	size = (size + 7) & ~(size_t)7;
	if (heap_off + size > sizeof(heap))
		return 0;
	void *p = &heap[heap_off];
	heap_off += size;
	return p;
}

void free(void *p)
{
	(void)p; /* バンプアロケータ: 解放しない (rpmsg-lite は deinit しない運用) */
}

void *memset(void *dst, int c, size_t n)
{
	char *d = dst;
	while (n--)
		*d++ = (char)c;
	return dst;
}

void *memcpy(void *dst, const void *src, size_t n)
{
	char *d = dst;
	const char *s = src;
	while (n--)
		*d++ = *s++;
	return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
	const unsigned char *p = a, *q = b;
	for (; n--; p++, q++)
		if (*p != *q)
			return *p - *q;
	return 0;
}

size_t strlen(const char *s)
{
	size_t n = 0;
	while (*s++)
		n++;
	return n;
}

char *strncpy(char *dst, const char *src, size_t n)
{
	char *d = dst;
	while (n && *src) {
		*d++ = *src++;
		n--;
	}
	while (n--)
		*d++ = 0;
	return dst;
}

int strcmp(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return (unsigned char)*a - (unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
	for (; n; n--, a++, b++) {
		if (*a != *b || !*a)
			return (unsigned char)*a - (unsigned char)*b;
	}
	return 0;
}

/* virtqueue.c のエラーパスが printf を呼ぶ。UART を持たない層なので捨てる */
int printf(const char *fmt, ...)
{
	(void)fmt;
	return 0;
}
