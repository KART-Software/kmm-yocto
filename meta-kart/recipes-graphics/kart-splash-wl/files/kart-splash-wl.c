/* kart-splash-wl — SPL スプラッシュと同一の絵 (真っ黒 BG + 白ロゴ) を
 * weston 起動直後に全画面表示する極小 Wayland クライアント。
 *
 * 狙い: SPL ロゴ → weston 遷移で 0.5s のロゴ無し区間 (ダークトーン一色) が
 * 見えていた (カメラ実測 2026-08-24)。kiosk-shell は背景に画像を張れない
 * (weston 13 の背景は weston_curtain = 単色専用) ため、compositor を patch
 * するのではなく「SPL と同じ絵を出すだけのクライアント」を kmm より先に
 * マップする。kiosk-shell は最後にマップされたサーフェスを前面に置くので、
 * kmm が表示された時点で自然に背面へ隠れる。常駐しておくことで kmm 再起動
 * 中もダークトーンではなくロゴが見える (再起動時の見た目も改善)。
 *
 * ロゴは SPL と同じ 1bit マスク (kart_splash_logo.h、u-boot レシピと共用) を
 * 同じ座標 (KART_LOGO_X/Y、パネル可視域 800x480 の左上原点) に描く。
 * kiosk-shell の client-size パッチが可視域サイズを configure で通知する
 * 前提 (来なければ 800x480 にフォールバック)。 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include "xdg-shell-client-protocol.h"
#include "kart_splash_logo.h"

#define BG_XRGB 0xff000000u	/* 真っ黒 (SPL SPLASH_BG_XRGB / weston background-color と同色) */
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

static void
draw(uint32_t *px, int w, int h)
{
	int i, row, col;

	for (i = 0; i < w * h; i++)
		px[i] = BG_XRGB;
	for (row = 0; row < KART_LOGO_H; row++) {
		int y = KART_LOGO_Y + row;

		if (y >= h)
			break;
		for (col = 0; col < KART_LOGO_W; col++) {
			int x = KART_LOGO_X + col;
			int bit = row * KART_LOGO_W + col;

			if (x >= w)
				break;
			if (kart_logo_bits[bit >> 3] & (0x80 >> (bit & 7)))
				px[y * w + x] = 0xffffffffu;
		}
	}
}

int
main(void)
{
	struct wl_display *dpy = NULL;
	struct wl_registry *reg;
	struct wl_surface *surface;
	struct xdg_surface *xsurface;
	struct xdg_toplevel *toplevel;
	struct wl_shm_pool *pool;
	struct wl_buffer *buf;
	uint32_t *px;
	int fd, stride, size, tries;

	/* weston と並行起動されるためソケットは未作成から始まる。10ms 間隔で
	 * 最大 10s 粘り、ソケット出現後は数 ms でマップして weston の初回
	 * フレームにロゴを間に合わせる (100ms 間隔だとロゴ不在が見えた) */
	for (tries = 0; tries < 1000 && !dpy; tries++) {
		dpy = wl_display_connect(NULL);
		if (!dpy)
			usleep(10 * 1000);
	}
	if (!dpy) {
		fprintf(stderr, "kart-splash-wl: no wayland display\n");
		return 1;
	}

	reg = wl_display_get_registry(dpy);
	wl_registry_add_listener(reg, &registry_listener, NULL);
	wl_display_roundtrip(dpy);
	if (!compositor || !shm || !wm_base) {
		fprintf(stderr, "kart-splash-wl: missing globals\n");
		return 1;
	}
	xdg_wm_base_add_listener(wm_base, &wm_listener, NULL);

	surface = wl_compositor_create_surface(compositor);
	xsurface = xdg_wm_base_get_xdg_surface(wm_base, surface);
	xdg_surface_add_listener(xsurface, &xsurface_listener, NULL);
	toplevel = xdg_surface_get_toplevel(xsurface);
	xdg_toplevel_add_listener(toplevel, &toplevel_listener, NULL);
	xdg_toplevel_set_title(toplevel, "kart-splash");
	xdg_toplevel_set_app_id(toplevel, "kart-splash");
	xdg_toplevel_set_fullscreen(toplevel, NULL);
	wl_surface_commit(surface);

	while (!configured)
		if (wl_display_dispatch(dpy) < 0)
			return 1;

	stride = win_w * 4;
	size = stride * win_h;
	fd = memfd_create("kart-splash", 0);
	if (fd < 0 || ftruncate(fd, size) < 0) {
		perror("kart-splash-wl: shm");
		return 1;
	}
	px = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (px == MAP_FAILED) {
		perror("kart-splash-wl: mmap");
		return 1;
	}
	draw(px, win_w, win_h);

	pool = wl_shm_create_pool(shm, fd, size);
	buf = wl_shm_pool_create_buffer(pool, 0, win_w, win_h, stride,
					WL_SHM_FORMAT_XRGB8888);
	wl_surface_attach(surface, buf, 0, 0);
	wl_surface_damage(surface, 0, 0, win_w, win_h);
	wl_surface_commit(surface);

	/* 常駐: kmm の背面でロゴを保持し続ける */
	while (wl_display_dispatch(dpy) >= 0)
		;
	return 0;
}
