/* LD_PRELOAD shim: dump DRM_IOCTL_MODE_ATOMIC / SETCRTC / PAGE_FLIP requests with property names (bench tool) */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_mode.h>
#include <linux/kd.h>
#include <linux/vt.h>

static int (*real_ioctl)(int, unsigned long, ...);
static ssize_t (*real_read)(int, void *, size_t);
static int drm_fd = -1;                 /* 最後に DRM ioctl を受けた fd */
static FILE *out;
static int busy;
static double now(void);
static int vt_done;
static void vt_prepare(void)
{
	const char *m = getenv("DRM_DUMP_VT");
	if (!m || !*m || vt_done) return;
	vt_done = 1;
	int t = open("/dev/tty0", O_RDWR | O_CLOEXEC | O_NOCTTY);
	if (t < 0) { fprintf(out, "%.6f    VT: open tty0 failed errno=%d\n", now(), errno); return; }
	int r1 = 0, r2 = 0, r3 = 0;
	if (!strcmp(m, "full")) {
		struct vt_mode vm = { .mode = VT_PROCESS, .relsig = SIGUSR1, .acqsig = SIGUSR2 };
		r1 = real_ioctl(t, VT_SETMODE, &vm);
		r2 = real_ioctl(t, KDSKBMODE, K_OFF);
	}
	r3 = real_ioctl(t, KDSETMODE, KD_GRAPHICS);
	fprintf(out, "%.6f    VT(%s): VT_SETMODE=%d KDSKBMODE=%d KDSETMODE(KD_GRAPHICS)=%d errno=%d\n", now(), m, r1, r2, r3, errno);
	/* fd は閉じない(seatd 同様に保持) */
}
static int first_done;               /* 初回 ALLOW_MODESET ATOMIC を処理済み */
static const char *mode_env;         /* DRM_DUMP_MODE: setcrtc | noevent | strip | (unset=dump only) */

/* props から値を探す */
static int find_prop(int fd, struct drm_mode_atomic *a, const char *want, uint32_t *obj_out, uint64_t *val_out)
{
	uint32_t *objs = (uint32_t *)(uintptr_t)a->objs_ptr, *cnt = (uint32_t *)(uintptr_t)a->count_props_ptr;
	uint32_t *props = (uint32_t *)(uintptr_t)a->props_ptr; uint64_t *vals = (uint64_t *)(uintptr_t)a->prop_values_ptr;
	uint32_t k = 0;
	for (uint32_t i = 0; i < a->count_objs; i++)
		for (uint32_t j = 0; j < cnt[i]; j++, k++) {
			drmModePropertyPtr p = drmModeGetProperty(fd, props[k]);
			int hit = p && !strcmp(p->name, want);
			if (p) drmModeFreeProperty(p);
			if (hit) { *obj_out = objs[i]; *val_out = vals[k]; return 1; }
		}
	return 0;
}
/* 初回 ATOMIC を legacy SETCRTC(+PAGE_FLIP で event 補完)に置換 */
static int do_setcrtc(int fd, struct drm_mode_atomic *a)
{
	uint32_t crtc, conn, plane, fb, dummy; uint64_t mode_id, fbv, crtc_of_conn, x = 0, y = 0;
	if (!find_prop(fd, a, "MODE_ID", &crtc, &mode_id) || !find_prop(fd, a, "FB_ID", &plane, &fbv) || !find_prop(fd, a, "max bpc", &conn, &crtc_of_conn)) { fprintf(out, "   setcrtc: props not found\n"); return -2; }
	find_prop(fd, a, "CRTC_X", &dummy, &x); find_prop(fd, a, "CRTC_Y", &dummy, &y); fb = (uint32_t)fbv;
	drmModePropertyBlobPtr b = drmModeGetPropertyBlob(fd, (uint32_t)mode_id);
	if (!b || b->length != sizeof(drmModeModeInfo)) { fprintf(out, "   setcrtc: mode blob missing\n"); return -2; }
	drmModeModeInfo m; memcpy(&m, b->data, sizeof m); drmModeFreePropertyBlob(b);
	double t0 = now(); int r = drmModeSetCrtc(fd, crtc, fb, (uint32_t)x, (uint32_t)y, &conn, 1, &m); int e = errno;
	fprintf(out, "%.6f    SETCRTC(crtc=%u fb=%u conn=%u) -> %d errno=%d (%.1f ms)\n", now(), crtc, fb, conn, r, r ? e : 0, (now() - t0) * 1000);
	if (r) { errno = e; return r; }
	if (a->flags & DRM_MODE_PAGE_FLIP_EVENT) {
		r = drmModePageFlip(fd, crtc, fb, DRM_MODE_PAGE_FLIP_EVENT, (void *)(uintptr_t)a->user_data); e = errno;
		fprintf(out, "%.6f    PAGE_FLIP(event, same fb) -> %d errno=%d\n", now(), r, r ? e : 0);
		if (r) { errno = e; return r; }
	}
	return 0;
}
/* 初回 ATOMIC を blocking/no-event で発行し、PAGE_FLIP で event 補完 */
static int do_noevent(int fd, struct drm_mode_atomic *a)
{
	struct drm_mode_atomic b = *a; b.flags &= ~(DRM_MODE_ATOMIC_NONBLOCK | DRM_MODE_PAGE_FLIP_EVENT);
	double t0 = now(); int r = real_ioctl(fd, DRM_IOCTL_MODE_ATOMIC, &b); int e = errno;
	fprintf(out, "%.6f    ATOMIC(blocking, no event) -> %d errno=%d (%.1f ms)\n", now(), r, r ? e : 0, (now() - t0) * 1000);
	if (r) { errno = e; return r; }
	if (a->flags & DRM_MODE_PAGE_FLIP_EVENT) {
		uint32_t crtc, plane; uint64_t mode_id, fbv; find_prop(fd, a, "MODE_ID", &crtc, &mode_id); find_prop(fd, a, "FB_ID", &plane, &fbv);
		r = drmModePageFlip(fd, crtc, (uint32_t)fbv, DRM_MODE_PAGE_FLIP_EVENT, (void *)(uintptr_t)a->user_data); e = errno;
		fprintf(out, "%.6f    PAGE_FLIP(event, same fb) -> %d errno=%d\n", now(), r, r ? e : 0);
		if (r) { errno = e; return r; }
	}
	return 0;
}
/* 初回 ATOMIC から VRR_ENABLED / max bpc を除いて発行(フラグはそのまま) */
static int do_strip(int fd, struct drm_mode_atomic *a)
{
	uint32_t *objs = (uint32_t *)(uintptr_t)a->objs_ptr, *cnt = (uint32_t *)(uintptr_t)a->count_props_ptr;
	uint32_t *props = (uint32_t *)(uintptr_t)a->props_ptr; uint64_t *vals = (uint64_t *)(uintptr_t)a->prop_values_ptr;
	uint32_t ncnt[16], nprops[64]; uint64_t nvals[64]; uint32_t k = 0, nk = 0;
	for (uint32_t i = 0; i < a->count_objs && i < 16; i++) {
		ncnt[i] = 0;
		for (uint32_t j = 0; j < cnt[i]; j++, k++) {
			drmModePropertyPtr p = drmModeGetProperty(fd, props[k]);
			int drop = p && (!strcmp(p->name, "VRR_ENABLED") || !strcmp(p->name, "max bpc"));
			if (p) drmModeFreeProperty(p);
			if (drop || nk >= 64) continue;
			nprops[nk] = props[k]; nvals[nk] = vals[k]; nk++; ncnt[i]++;
		}
	}
	struct drm_mode_atomic b = *a; b.count_props_ptr = (uintptr_t)ncnt; b.props_ptr = (uintptr_t)nprops; b.prop_values_ptr = (uintptr_t)nvals;
	double t0 = now(); int r = real_ioctl(fd, DRM_IOCTL_MODE_ATOMIC, &b); int e = errno;
	fprintf(out, "%.6f    ATOMIC(stripped VRR/max bpc, %u props) -> %d errno=%d (%.1f ms)\n", now(), nk, r, r ? e : 0, (now() - t0) * 1000);
	errno = e; return r;
}

static void init(void)
{
	if (!real_ioctl) real_ioctl = dlsym(RTLD_NEXT, "ioctl");
	if (!real_read) real_read = dlsym(RTLD_NEXT, "read");
	if (!out) {
		const char *p = getenv("DRM_DUMP_FILE");
		out = fopen(p ? p : "/data/strace-out/drmdump.log", "a");
		if (out) setvbuf(out, NULL, _IOLBF, 0);
	}
}
static double now(void) { struct timespec ts; clock_gettime(CLOCK_BOOTTIME, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }
static void modeline(const struct drm_mode_modeinfo *m)
{
	fprintf(out, "      mode \"%s\" clock=%u h=%u/%u/%u/%u/%u v=%u/%u/%u/%u/%u vrefresh=%u flags=0x%x type=0x%x\n",
		m->name, m->clock, m->hdisplay, m->hsync_start, m->hsync_end, m->htotal, m->hskew,
		m->vdisplay, m->vsync_start, m->vsync_end, m->vtotal, m->vscan, m->vrefresh, m->flags, m->type);
}
static void dump_atomic(int fd, struct drm_mode_atomic *a)
{
	uint32_t *objs = (uint32_t *)(uintptr_t)a->objs_ptr, *cnt = (uint32_t *)(uintptr_t)a->count_props_ptr;
	uint32_t *props = (uint32_t *)(uintptr_t)a->props_ptr; uint64_t *vals = (uint64_t *)(uintptr_t)a->prop_values_ptr;
	uint32_t k = 0;
	fprintf(out, "%.6f pid=%d ATOMIC flags=0x%x%s%s%s%s objs=%u\n", now(), getpid(), a->flags,
		a->flags & DRM_MODE_ATOMIC_ALLOW_MODESET ? " ALLOW_MODESET" : "", a->flags & DRM_MODE_ATOMIC_NONBLOCK ? " NONBLOCK" : "",
		a->flags & DRM_MODE_PAGE_FLIP_EVENT ? " PAGE_FLIP_EVENT" : "", a->flags & DRM_MODE_ATOMIC_TEST_ONLY ? " TEST_ONLY" : "", a->count_objs);
	for (uint32_t i = 0; i < a->count_objs; i++) {
		fprintf(out, "   obj %u (%u props)\n", objs[i], cnt[i]);
		for (uint32_t j = 0; j < cnt[i]; j++, k++) {
			drmModePropertyPtr p = drmModeGetProperty(fd, props[k]);
			const char *name = p ? p->name : "?";
			fprintf(out, "      %-22s = %llu\n", name, (unsigned long long)vals[k]);
			if (p && (p->flags & DRM_MODE_PROP_BLOB) && vals[k]) {
				drmModePropertyBlobPtr b = drmModeGetPropertyBlob(fd, (uint32_t)vals[k]);
				if (b) { if (b->length == sizeof(struct drm_mode_modeinfo)) modeline(b->data); else fprintf(out, "      (blob %u bytes)\n", b->length); drmModeFreePropertyBlob(b); }
			}
			if (p) drmModeFreeProperty(p);
		}
	}
}
int ioctl(int fd, unsigned long req, ...)
{
	va_list ap; va_start(ap, req); void *arg = va_arg(ap, void *); va_end(ap);
	init();
	if (!out || busy) return real_ioctl(fd, req, arg);
	if (req == DRM_IOCTL_MODE_ATOMIC || req == DRM_IOCTL_MODE_SETCRTC || req == DRM_IOCTL_MODE_PAGE_FLIP) drm_fd = fd;
	if (req == DRM_IOCTL_MODE_ATOMIC || req == DRM_IOCTL_MODE_SETCRTC) { busy = 1; vt_prepare(); busy = 0; }
	if (req == DRM_IOCTL_MODE_ATOMIC) {
		struct drm_mode_atomic *a = arg;
		busy = 1; dump_atomic(fd, a);
		if (!mode_env) mode_env = getenv("DRM_DUMP_MODE");
		if (mode_env && *mode_env && !first_done && (a->flags & DRM_MODE_ATOMIC_ALLOW_MODESET) && !(a->flags & DRM_MODE_ATOMIC_TEST_ONLY)) {
			int r = -2;
			first_done = 1;
			fprintf(out, "   [mode=%s] rewriting first modeset commit\n", mode_env);
			if (!strcmp(mode_env, "setcrtc")) r = do_setcrtc(fd, a);
			else if (!strcmp(mode_env, "noevent")) r = do_noevent(fd, a);
			else if (!strcmp(mode_env, "strip")) r = do_strip(fd, a);
			busy = 0;
			if (r != -2) return r;   /* -2 = フォールバック(素の ATOMIC を通す) */
			busy = 1;
		}
		busy = 0;
	}
	else if (req == DRM_IOCTL_MODE_SETCRTC) {
		struct drm_mode_crtc *c = arg;
		fprintf(out, "%.6f pid=%d SETCRTC crtc=%u fb=%u x=%u y=%u conns=%u mode_valid=%u\n", now(), getpid(), c->crtc_id, c->fb_id, c->x, c->y, c->count_connectors, c->mode_valid);
		if (c->mode_valid) modeline(&c->mode);
	} else if (req == DRM_IOCTL_MODE_PAGE_FLIP) {
		struct drm_mode_crtc_page_flip *f = arg;
		fprintf(out, "%.6f pid=%d PAGE_FLIP crtc=%u fb=%u flags=0x%x\n", now(), getpid(), f->crtc_id, f->fb_id, f->flags);
	} else return real_ioctl(fd, req, arg);
	double t0 = now(); int r = real_ioctl(fd, req, arg); int e = errno;
	fprintf(out, "%.6f    -> ret=%d errno=%d (%.1f ms)\n", now(), r, r < 0 ? e : 0, (now() - t0) * 1000);
	errno = e; return r;
}

/* DRM fd からの read = イベント受信をログ(flip complete / vblank) */
ssize_t read(int fd, void *buf, size_t n)
{
	if (!real_read) real_read = dlsym(RTLD_NEXT, "read");
	ssize_t r = real_read(fd, buf, n);
	if (fd == drm_fd && out && r > 0) {
		size_t off = 0;
		while (off + sizeof(struct drm_event) <= (size_t)r) {
			struct drm_event *e = (struct drm_event *)((char *)buf + off);
			if (e->length < sizeof(struct drm_event)) break;
			if ((e->type == DRM_EVENT_FLIP_COMPLETE || e->type == DRM_EVENT_VBLANK) && e->length >= sizeof(struct drm_event_vblank)) {
				struct drm_event_vblank *v = (struct drm_event_vblank *)e;
				fprintf(out, "%.6f pid=%d EVENT %s seq=%u crtc=%u tv=%u.%06u\n", now(), getpid(), e->type == DRM_EVENT_FLIP_COMPLETE ? "FLIP_COMPLETE" : "VBLANK", v->sequence, v->crtc_id, v->tv_sec, v->tv_usec);
			} else fprintf(out, "%.6f pid=%d EVENT type=%u len=%u\n", now(), getpid(), e->type, e->length);
			off += e->length;
		}
	}
	return r;
}
