/* wl-image-view — raw XRGB8888 画像をフルスクリーン表示する極小 Wayland
 * クライアント (ベンチ用途)。
 *
 * LCD バリデーションシステム (tools/lcd-validation/) のパターン表示器。
 * kiosk-shell は最後にマップされた surface を前面に置くため、kmm 稼働中でも
 * これを起動すればパターンが最前面に出る。kill すれば元の画面に戻る。
 *
 * 使い方:
 *   wl-image-view <file.raw> [width height]
 *   file.raw = XRGB8888 (LE) の生ピクセル、既定 800x480 (1536000 bytes)。
 *   tools/lcd-validation/generate_pattern.py --raw が生成する。
 *
 * 実装は kart-splash-wl.c (実機検証済み) の描画部を差し替えたもの。 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"

#define FALLBACK_W 800
#define FALLBACK_H 480

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm_base;
static int32_t win_w = FALLBACK_W, win_h = FALLBACK_H;
static int configured;

static void
registry_global(void *data, struct wl_registry *reg, uint32_t name,
		const char *iface, uint32_t ver)
{
	if (!strcmp(iface, wl_compositor_interface.name))
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	else if (!strcmp(iface, wl_shm_interface.name))
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	else if (!strcmp(iface, xdg_wm_base_interface.name))
		wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
}

static void
registry_global_remove(void *data, struct wl_registry *reg, uint32_t name)
{
}

static const struct wl_registry_listener registry_listener = {
	registry_global, registry_global_remove
};

static void
wm_ping(void *data, struct xdg_wm_base *wm, uint32_t serial)
{
	xdg_wm_base_pong(wm, serial);
}

static const struct xdg_wm_base_listener wm_listener = { wm_ping };

static void
xdg_configure(void *data, struct xdg_surface *xs, uint32_t serial)
{
	xdg_surface_ack_configure(xs, serial);
	configured = 1;
}

static const struct xdg_surface_listener xsurface_listener = { xdg_configure };

static void
top_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h,
	      struct wl_array *states)
{
	if (w > 0)
		win_w = w;
	if (h > 0)
		win_h = h;
}

static void
top_close(void *data, struct xdg_toplevel *t)
{
	exit(0);
}

static void
top_bounds(void *data, struct xdg_toplevel *t, int32_t w, int32_t h)
{
}

static void
top_caps(void *data, struct xdg_toplevel *t, struct wl_array *caps)
{
}

static const struct xdg_toplevel_listener toplevel_listener = {
	top_configure, top_close, top_bounds, top_caps
};

int
main(int argc, char **argv)
{
	struct wl_display *dpy = NULL;
	struct wl_registry *reg;
	struct wl_surface *surface;
	struct xdg_surface *xsurface;
	struct xdg_toplevel *toplevel;
	struct wl_shm_pool *pool;
	struct wl_buffer *buf;
	uint32_t *px;
	uint32_t *img;
	int img_w = FALLBACK_W, img_h = FALLBACK_H;
	int fd, ifd, stride, size, tries, x, y;
	ssize_t want, got;

	if (argc < 2) {
		fprintf(stderr, "usage: wl-image-view <file.raw> [w h]\n");
		return 2;
	}
	if (argc >= 4) {
		img_w = atoi(argv[2]);
		img_h = atoi(argv[3]);
		if (img_w <= 0 || img_h <= 0) {
			fprintf(stderr, "wl-image-view: bad size\n");
			return 2;
		}
	}

	want = (ssize_t)img_w * img_h * 4;
	img = malloc(want);
	if (!img) {
		perror("wl-image-view: malloc");
		return 1;
	}
	ifd = open(argv[1], O_RDONLY);
	if (ifd < 0) {
		perror(argv[1]);
		return 1;
	}
	got = 0;
	while (got < want) {
		ssize_t n = read(ifd, (char *)img + got, want - got);

		if (n <= 0)
			break;
		got += n;
	}
	close(ifd);
	if (got != want) {
		fprintf(stderr, "wl-image-view: %s: %zd bytes (want %zd)\n",
			argv[1], got, want);
		return 1;
	}

	for (tries = 0; tries < 1000 && !dpy; tries++) {
		dpy = wl_display_connect(NULL);
		if (!dpy)
			usleep(10 * 1000);
	}
	if (!dpy) {
		fprintf(stderr, "wl-image-view: no wayland display\n");
		return 1;
	}

	reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_roundtrip(dpy);
	if (!compositor || !shm || !wm_base) {
		fprintf(stderr, "wl-image-view: missing globals\n");
		return 1;
	}
	xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);

	surface = wl_compositor_create_surface(compositor);
	xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xsurface, &xsurface_listener, NULL);
	toplevel = xdg_surface_get_toplevel(xsurface);
	xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
	xdg_toplevel_set_title(toplevel, "wl-image-view");
	xdg_toplevel_set_app_id(toplevel, "wl-image-view");
	xdg_toplevel_set_fullscreen(toplevel, NULL);
	wl_surface_commit(surface);

	while (!configured)
		if (wl_display_dispatch(dpy) < 0)
			return 1;

	stride = win_w * 4;
	size = stride * win_h;
	fd = memfd_create("wl-image-view", 0);
	if (fd < 0 || ftruncate(fd, size) < 0) {
		perror("wl-image-view: shm");
		return 1;
	}
	px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (px == MAP_FAILED) {
		perror("wl-image-view: mmap");
		return 1;
	}

	/* 画像を左上原点で配置、余白は黒。win == img (800x480) が通常ケース */
	for (y = 0; y < win_h; y++)
		for (x = 0; x < win_w; x++)
			px[y * win_w + x] =
				(x < img_w && y < img_h) ?
				img[y * img_w + x] : 0xff000000u;

	pool = wl_shm_create_pool(shm, fd, size);
	buf = wl_shm_pool_create_buffer(pool, 0, win_w, win_h, stride,
					WL_SHM_FORMAT_XRGB8888);
	wl_surface_attach(surface, buf, 0, 0);
	wl_surface_damage(surface, 0, 0, win_w, win_h);
	wl_surface_commit(surface);

	/* 常駐: kill されるまで表示し続ける */
	while (wl_display_dispatch(dpy) >= 0)
		;
	return 0;
}
