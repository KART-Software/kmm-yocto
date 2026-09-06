/* drm-image-view — weston を介さず DRM/KMS を直接叩いて XRGB8888 の raw を
 * 全画面表示する最小プログラム (暗ブート切り分け用)。card0 を開き、接続中の
 * コネクタのモードで dumb buffer を確保し raw をコピーして legacy setcrtc を
 * 1 回打つ。weston/kiosk-shell/wayland 合成を全部外し「表示スタックが早期
 * 起動でも初回 modeset を通せるか」だけを見る。 usage: drm-image-view <raw> [w h] */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <poll.h>
#include <time.h>

int main(int argc, char **argv)
{
	int w = 800, h = 480;
	if (argc < 2) { fprintf(stderr, "usage: %s <raw> [w h]\n", argv[0]); return 2; }
	if (argc >= 4) { w = atoi(argv[2]); h = atoi(argv[3]); }

	int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) { perror("open card0"); return 1; }
	drmSetMaster(fd); /* weston が居なければ自動でも master になれる */

	drmModeRes *res = drmModeGetResources(fd);
	if (!res) { perror("getresources"); return 1; }

	drmModeConnector *conn = NULL;
	for (int i = 0; i < res->count_connectors; i++) {
		drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
		if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) { conn = c; break; }
		if (c) drmModeFreeConnector(c);
	}
	if (!conn) { fprintf(stderr, "no connected connector\n"); return 1; }
	drmModeModeInfo mode = conn->modes[0];
	fprintf(stderr, "drm-image-view: connector %u mode %s %dx%d\n",
		conn->connector_id, mode.name, mode.hdisplay, mode.vdisplay);

	/* encoder -> crtc */
	drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id ? conn->encoder_id : conn->encoders[0]);
	uint32_t crtc_id = enc ? enc->crtc_id : 0;
	if (!crtc_id) { /* pick first possible crtc */
		if (enc) for (int i = 0; i < res->count_crtcs; i++)
			if (enc->possible_crtcs & (1 << i)) { crtc_id = res->crtcs[i]; break; }
	}
	if (!crtc_id && res->count_crtcs) crtc_id = res->crtcs[0];
	if (!crtc_id) { fprintf(stderr, "no crtc\n"); return 1; }

	/* dumb buffer */
	struct drm_mode_create_dumb creq = { .width = mode.hdisplay, .height = mode.vdisplay, .bpp = 32 };
	if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq)) { perror("create_dumb"); return 1; }
	uint32_t fb_id;
	if (drmModeAddFB(fd, mode.hdisplay, mode.vdisplay, 24, 32, creq.pitch, creq.handle, &fb_id)) { perror("addfb"); return 1; }
	struct drm_mode_map_dumb mreq = { .handle = creq.handle };
	if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq)) { perror("map_dumb"); return 1; }
	uint8_t *map = mmap(0, creq.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mreq.offset);
	if (map == MAP_FAILED) { perror("mmap"); return 1; }
	memset(map, 0, creq.size);

	/* load raw (w x h XRGB8888), place top-left */
	int rf = open(argv[1], O_RDONLY);
	if (rf >= 0) {
		uint32_t *img = malloc((size_t)w * h * 4);
		ssize_t got = 0, want = (ssize_t)w * h * 4, n;
		while (got < want && (n = read(rf, (char*)img + got, want - got)) > 0) got += n;
		close(rf);
		for (int y = 0; y < h && y < mode.vdisplay; y++)
			memcpy(map + y * creq.pitch, img + (size_t)y * w, (size_t)((w < mode.hdisplay ? w : mode.hdisplay)) * 4);
		free(img);
	}

	/* pristine copy of the pattern for clean per-frame redraw */
	uint8_t *base = malloc(creq.size);
	memcpy(base, map, creq.size);

	int animate = 0;
	for (int i = 1; i < argc; i++) if (!strcmp(argv[i], "--animate")) animate = 1;

	/* 2nd dumb buffer for double-buffered flipping */
	struct drm_mode_create_dumb creq2 = { .width = mode.hdisplay, .height = mode.vdisplay, .bpp = 32 };
	uint32_t fb2 = 0; uint8_t *map2 = NULL;
	if (animate) {
		if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq2)) { perror("create_dumb2"); return 1; }
		drmModeAddFB(fd, mode.hdisplay, mode.vdisplay, 24, 32, creq2.pitch, creq2.handle, &fb2);
		struct drm_mode_map_dumb m2 = { .handle = creq2.handle };
		drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &m2);
		map2 = mmap(0, creq2.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, m2.offset);
		memcpy(map2, base, creq2.size);
	}

	if (drmModeSetCrtc(fd, crtc_id, fb_id, 0, 0, &conn->connector_id, 1, &mode)) {
		perror("setcrtc"); return 1;
	}
	fprintf(stderr, "drm-image-view: setcrtc OK on crtc %u fb %u animate=%d\n", crtc_id, fb_id, animate);

	if (!animate) { for (;;) pause(); return 0; }

	/* draw a moving white bar per frame into the back buffer, flip on vblank,
	 * count completed flips over 10s = real display update rate. */
	uint8_t *maps[2] = { map, map2 };
	uint32_t fbs[2] = { fb_id, fb2 };
	int back = 1;
	unsigned long flips = 0;
	struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
	double last_report = 0;
	int flip_pending = 0;
	int col = 0;
	while (1) {
		/* draw: copy base image then overlay a vertical bar at column 'col' */
		memcpy(maps[back], base, creq.size);
		for (int y = 0; y < mode.vdisplay; y++) {
			uint32_t *row = (uint32_t*)(maps[back] + y * creq.pitch);
			for (int x = col; x < col + 20 && x < mode.hdisplay; x++) row[x] = 0xffff0000; /* red bar */
		}
		col = (col + 8) % mode.hdisplay;

		if (drmModePageFlip(fd, crtc_id, fbs[back], DRM_MODE_PAGE_FLIP_EVENT, &flip_pending) == 0) {
			flip_pending = 1;
			/* wait for flip complete */
			struct pollfd pfd = { .fd = fd, .events = POLLIN };
			while (flip_pending) {
				if (poll(&pfd, 1, 1000) <= 0) break;
				drmEventContext ev = { .version = 2 };
				ev.page_flip_handler = NULL;
				/* minimal handler via read */
				char buf[1024]; ssize_t n = read(fd, buf, sizeof(buf));
				(void)n; flip_pending = 0; /* one event per flip */
			}
			flips++;
			back ^= 1;
		} else {
			/* flip busy; brief wait */
		}
		struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
		double el = (now.tv_sec - t0.tv_sec) + (now.tv_nsec - t0.tv_nsec)/1e9;
		if (el - last_report >= 1.0) {
			fprintf(stderr, "drm-image-view: t=%.1fs flips=%lu (%.1f fps)\n", el, flips, flips/el);
			last_report = el;
		}
	}
	return 0;
}
