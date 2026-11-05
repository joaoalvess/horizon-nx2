// The Switch 2's video decoder API as the host serves it (hle_codec_video.c), without a guest: the buffer protocol, results, sync handles, sync point events and the
// readback, on synthetic red key frames: 16x16 VP9 and VP8 (the ones t_movie_vpx.c decodes), a 64x64 H.264 baseline frame (ffmpeg's libx264, SEI removed) and a 64x64 AV1 frame
// (SVT-AV1 through PyAV, preset 12, CRF 30); no game data. The SystemEvent functions are stubs that record each event's state.
#include "../hle.h"
#undef HLE_FORCE
#define HLE_FORCE(mangled, why, ret, cname, ...) static ret cname(__VA_ARGS__)
#include "../hle_movie.c"
#include "../hle_codec_video.c"
#include "../hle_movie_avc.c"
#include "../hle_movie_av1.c"
#include <assert.h>

uint64_t now_ns(void) { return 1; }
__thread _Atomic int dm_host_work;   // hle_thread.c
static struct { void *ev; int bound, set; } g_ev[16];
static int ev_slot(void *e) { for (int i = 0; i < 16; i++) if (g_ev[i].ev == e) return i; for (int i = 0; i < 16; i++) if (!g_ev[i].ev) { g_ev[i].ev = e; return i; } abort(); }
void hle_bind_system_event(void *e, int autoclear) { (void)autoclear; g_ev[ev_slot(e)].bound = 1; }
void hle_signal_system_event(void *e) { g_ev[ev_slot(e)].set = 1; }
void hle_clear_system_event(void *e) { g_ev[ev_slot(e)].set = 0; }
static int ev_set(void *e) { return g_ev[ev_slot(e)].set; }
static void destroy_ev(void *e) { g_ev[ev_slot(e)].bound = g_ev[ev_slot(e)].set = 0; }   // nn::os::DestroySystemEvent: closing the handle unbinds the event
void *guest_sym(const char *n) { return !strcmp(n, "_ZN2nn2os18DestroySystemEventEPNS0_15SystemEventTypeE") ? (void *)destroy_ev : NULL; }
static vpx_image_t *black_i420(unsigned w, unsigned h) {
    vpx_image_t *c = vpx_img_alloc(NULL, VPX_IMG_FMT_I420, w, h, 1); if (!c) return NULL;
    memset(c->planes[0], 16, (size_t)c->stride[0] * h);
    memset(c->planes[1], 128, (size_t)c->stride[1] * ((h + 1) / 2)); memset(c->planes[2], 128, (size_t)c->stride[2] * ((h + 1) / 2));
    return c;
}

static const uint8_t vp8[] = {
    0xf0,0x02,0x00,0x9d,0x01,0x2a,0x10,0x00,0x10,0x00,0x00,0x47,0x08,0x85,0x85,0x88,
    0x85,0x84,0x88,0x02,0x02,0x02,0x75,0xaa,0x03,0xf8,0x03,0xfa,0x02,0x0d,0x4d,0x18,
    0x00,0xfe,0xfd,0x6e,0xf3,0xff,0xe3,0x99,0x37,0x30,0xc4,0xff,0x8e,0x6d,0xff,0xf1,
    0x61,0x3c,0x0e,0x28,0xc8,0xff,0xf1,0x51,0x00,
};
static const uint8_t av1[] = {   // one temporal unit: temporal delimiter, sequence header (profile 0, 64x64), frame
    0x12,0x00,0x0a,0x0b,0x02,0x00,0x00,0x04,0x95,0x7f,0xfc,0x0a,0xf9,0x00,0x40,0x32,0x15,0x10,0x00,0xbc,0x00,0x49,0x22,0x08,0x08,0x21,0x10,0x00,0xad,0x3b,0x67,0x00,
    0x1e,0xb5,0xdb,0x79,0x52,0x90,
};
static const uint8_t h264[] = {   // Annex B: SPS, PPS, one IDR slice
    0x00,0x00,0x00,0x01,0x67,0x42,0xc0,0x0a,0xdc,0x42,0x6c,0x04,0x40,0x00,0x00,0x03,0x00,0x40,0x00,0x00,0x0c,0xa3,0xc4,0x89,
    0xe0,0x00,0x00,0x00,0x01,0x68,0xce,0x0f,0xc8,0x00,0x00,0x01,0x65,0x88,0x84,0x3a,0x11,0x8a,0x00,0x02,0x18,0xf1,0xc0,0x00,
    0x40,0xf6,0x38,0x00,0x08,0x79,0x49,0xc9,0xc9,0xd7,0x5d,0x75,0xd7,0x5d,0x75,0xd7,0x5d,0x75,0xe0,
};
static const uint8_t vp9[] = {
    0x82,0x49,0x83,0x42,0x00,0x00,0xf0,0x00,0xf6,0x00,0x38,0x24,0x1c,0x18,0x4a,0x00,
    0x00,0x30,0x60,0x00,0x00,0x10,0xbf,0xff,0xf7,0x1d,0xaf,0xff,0xff,0xff,0x5f,0xdf,
    0xff,0xff,0xff,0xf2,0x2a,0xc0,0x00,
};

// The pre-NV12 AV1 ownership copy, kept as an independent byte-for-byte readback oracle.
static vpx_image_t *old_av1_i420(const mav1_picture *p) {
    vpx_image_t *im = vpx_img_alloc(NULL, VPX_IMG_FMT_I420, p->w, p->h, 1); assert(im);
    im->cs = p->matrix == 2 ? VPX_CS_BT_709 : p->matrix == 5 ? VPX_CS_BT_2020 : VPX_CS_BT_601;
    im->range = p->full_range ? VPX_CR_FULL_RANGE : VPX_CR_STUDIO_RANGE;
    for (int y = 0; y < p->h; y++) memcpy(im->planes[0] + (size_t)y * im->stride[0], p->y + (size_t)y * p->ystride, p->w);
    for (int y = 0; y < (p->h + 1) / 2; y++) for (int x = 0; x < (p->w + 1) / 2; x++) {
        im->planes[1][(size_t)y * im->stride[1] + x] = p->uv[(size_t)y * p->uvstride + 2 * x];
        im->planes[2][(size_t)y * im->stride[2] + x] = p->uv[(size_t)y * p->uvstride + 2 * x + 1];
    }
    return im;
}
static void tail_untouched(const uint8_t *p, size_t n) { for (size_t i = 0; i < n; i++) assert(p[i] == 0xa5); }

static void same_av1_output(vpx_image_t *im, const vpx_image_t *old, int w, int h) {
    enum { TAIL = 32 };
    size_t yn = (size_t)w * h, un = yn / 2, rn = yn * 4;
    uint8_t *expected = malloc(rn + TAIL), *out = malloc(rn + TAIL), *y = malloc(yn + TAIL), *uv = malloc(un + TAIL);
    assert(expected && out && y && uv);
    cv_pool pool = {.magic = CV_MAGIC, .count = 1, .img = &im}; cv_pool *handle = &pool;
    memset(expected, 0xa5, rn + TAIL); memset(out, 0xa5, rn + TAIL);
    md_nv12(old, expected, w, h);
    assert(!h_cv_nv12(&handle, 0, 0, 0, w, h, out, w, yn + TAIL, out + yn, w, un + TAIL));
    assert(!memcmp(out, expected, yn + un)); tail_untouched(out + yn + un, TAIL);
    // Explicitly check visible samples and black padding, including the rounded-up chroma of odd I420 pictures.
    for (int row = 0; row < h; row++) for (int x = 0; x < w; x++)
        assert(out[(size_t)row * w + x] == (row < (int)im->d_h && x < (int)im->d_w ? im->planes[0][(size_t)row * im->stride[0] + x] : 16));
    for (int row = 0; row < h / 2; row++) for (int x = 0; x < w; x++) {
        uint8_t value = 128;
        if (row < (int)(old->d_h + 1) / 2 && x / 2 < (int)(old->d_w + 1) / 2)
            value = old->planes[1 + (x & 1)][(size_t)row * old->stride[1 + (x & 1)] + x / 2];
        assert(out[yn + (size_t)row * w + x] == value);
    }
    memset(y, 0xa5, yn + TAIL); memset(uv, 0xa5, un + TAIL);
    assert(!h_cv_nv12(&handle, 0, 0, 0, w, h, y, w, yn + TAIL, uv, w, un + TAIL));
    assert(!memcmp(y, expected, yn) && !memcmp(uv, expected + yn, un));
    tail_untouched(y + yn, TAIL); tail_untouched(uv + un, TAIL);
    memset(expected, 0xa5, rn + TAIL); memset(out, 0xa5, rn + TAIL);
    md_rgba(old, expected, w, h);
    assert(!h_cv_rgba(&handle, 0, 0, 0, w, h, out, w * 4, rn + TAIL));
    assert(!memcmp(out, expected, rn)); tail_untouched(out + rn, TAIL);
    // Both tight and 64-byte-aligned native rows must match RGBA readback; row padding stays untouched.
    pool.w = w; pool.h = h; pool.native = 1; pool.size = native_size(w, h);
    pool.mem = malloc(pool.size); assert(pool.mem); memset(pool.mem, 0xa5, pool.size);
    pool_native_write(&pool, 0, im);
    size_t stride = native_stride(w);
    for (int row = 0; row < h; row++) {
        assert(!memcmp(pool.mem + (size_t)row * stride, expected + (size_t)row * w * 4, w * 4));
        tail_untouched(pool.mem + (size_t)row * stride + w * 4, stride - w * 4);
    }
    tail_untouched(pool.mem + stride * h, pool.size - stride * h);
    free(pool.mem); free(expected); free(out); free(y); free(uv);
}

static void patterned_av1(void) {
    static const int dims[][2] = {{2, 2}, {30, 10}, {32, 18}, {34, 20}, {31, 19}, {31, 20}, {32, 19}};
    static const int matrices[] = {0, 1, 2, 5};
    for (size_t i = 0; i < sizeof dims / sizeof dims[0]; i++) {
        int w = dims[i][0], h = dims[i][1], even = !(w & 1) && !(h & 1);
        size_t ys = w + 7, us = 2 * ((w + 1) / 2) + 13;
        uint8_t *y = malloc(ys * h), *uv = malloc(us * ((h + 1) / 2)); assert(y && uv);
        memset(y, 0xee, ys * h); memset(uv, 0xdd, us * ((h + 1) / 2));
        for (int row = 0; row < h; row++) for (int x = 0; x < w; x++) y[(size_t)row * ys + x] = (uint8_t)(17 * row + 29 * x);
        for (int row = 0; row < (h + 1) / 2; row++) for (int x = 0; x < 2 * ((w + 1) / 2); x++) uv[(size_t)row * us + x] = (uint8_t)(43 * row + 53 * x + 7);
        for (size_t m = 0; m < sizeof matrices / sizeof matrices[0]; m++) for (int full = 0; full < 2; full++) {
            mav1_picture pic = {y, uv, ys, us, w, h, matrices[m], full};
            vpx_image_t *im = av1_copy(&pic), *old = old_av1_i420(&pic); assert(im);
            assert(im->fmt == (even ? VPX_IMG_FMT_NV12 : VPX_IMG_FMT_I420) && im->img_data_owner);
            assert(im->d_w == (unsigned)w && im->d_h == (unsigned)h && im->cs == old->cs && im->range == old->range);
            int ew = (w + 1) & ~1, eh = (h + 1) & ~1;
            same_av1_output(im, old, ew, eh);
            same_av1_output(im, old, ew > 2 ? ew - 2 : 2, eh > 2 ? eh - 2 : 2);
            same_av1_output(im, old, ew + 4, eh + 4);
            same_av1_output(im, old, ew + 2, eh > 2 ? eh - 2 : 2);
            same_av1_output(im, old, ew > 2 ? ew - 2 : 2, eh + 2);
            vpx_img_free(im); vpx_img_free(old);
        }
        // The owned picture must survive overwriting and freeing both padded decoder planes.
        mav1_picture pic = {y, uv, ys, us, w, h, 2, 1};
        vpx_image_t *im = av1_copy(&pic), *old = old_av1_i420(&pic); assert(im);
        memset(y, 0, ys * h); memset(uv, 255, us * ((h + 1) / 2)); free(y); free(uv);
        same_av1_output(im, old, (w + 1) & ~1, (h + 1) & ~1);
        vpx_img_free(im); vpx_img_free(old);
    }
}

static void av1_pool_lifetime(void) {
    _Alignas(16) uint8_t dec[0x400] = {0}, pt[0x40] = {0};
    cv_pref pref = h_cv_pref(64, 64, 3, 0); uint64_t size, align, id; uint32_t idx; cv_sync sync;
    assert(!h_cv_poolsize(&size, &align, &pref, 1));
    void *mem = malloc(size); assert(mem && !h_cv_pool(pt, mem, size, &pref, 1, 0));
    uint32_t native = h_cv_native(pt, 0); assert(native);
    assert(!h_cv_av1init2(dec, 0x10000, 64, 64, 1, 1, 3));
    assert(!h_cv_av1reg(dec, 0, pt, 0) && !h_cv_av1acq(&idx, &sync, dec) && idx == 0);
    h_cv_av1rel(dec, 0, sync); assert(!h_cv_av1acq(&idx, &sync, dec) && !h_gs_trywait(&sync));
    assert(!h_cv_av1submit(&id, dec, av1, sizeof av1, 1234567, true) && id == 1 && h_gs_trywait(&sync));
    uint16_t w, h, cw, ch; int64_t ts; bool eos;
    assert(!h_cv_av1props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) && w == 64 && h == 64 && cw == 64 && ch == 64 && ts == 1234567 && eos);
    cv_pool *pool = pool_of(pt); vpx_image_t *retained = pool->img[0]; assert(retained && retained->fmt == VPX_IMG_FMT_NV12);
    // Independent old-path oracle from the same backend, before its borrowed planes expire.
    mav1_picture pic; assert(mav1_decode(cv_of(dec)->av1, av1, sizeof av1, &pic) == 1);
    vpx_image_t *old = old_av1_i420(&pic);
    uint8_t rgba[64 * 64 * 4]; md_rgba(old, rgba, 64, 64); assert(!memcmp(mem, rgba, sizeof rgba));
    same_av1_output(retained, old, 64, 64);
    for (int i = 0; i < CV_HOLD; i++) assert(!h_cv_av1submit(&id, dec, av1, sizeof av1, 2000 + i, false));
    assert(cv_of(dec)->nheld == CV_HOLD && !ev_set(dec + CV_EVENT_OFF));
    assert(h_cv_av1submit(&id, dec, av1, sizeof av1, 9999, false) == CV_BUSY);
    same_av1_output(retained, old, 64, 64);   // further decodes reused the backend storage
    h_cv_av1rel(dec, 0, sync); assert(!h_cv_av1acq(&idx, &sync, dec) && sync.gen == 2 && h_gs_trywait(&sync));
    assert(cv_of(dec)->nheld == CV_HOLD - 1 && ev_set(dec + CV_EVENT_OFF));
    assert(!h_cv_av1props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) && ts == 2000 && !eos);
    retained = pool->img[0]; same_av1_output(retained, old, 64, 64);   // replacement freed the previous owned picture
    assert(!h_cv_av1flush(dec) && !cv_of(dec)->nheld && pool->img[0] == retained);
    same_av1_output(retained, old, 64, 64);
    h_cv_av1rel(dec, 0, sync); assert(!h_cv_av1acq(&idx, &sync, dec) && !h_gs_trywait(&sync));
    assert(pool->img[0] == retained); same_av1_output(retained, old, 64, 64);   // release alone retains it
    assert(!h_cv_av1submit(&id, dec, NULL, 0, 0, true) && h_gs_trywait(&sync));
    assert(!h_cv_av1props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) && eos && !w && !h && pool->img[0] == retained);
    assert(!h_cv_av1fin(dec) && !cv_of(dec));
    same_av1_output(retained, old, 64, 64);   // pool picture outlives reset and decoder destruction
    // Finalizing a pool while registered must also free its owned NV12 without leaving a decoder reference to it.
    assert(!h_cv_av1init2(dec, 0x10000, 64, 64, 1, 1, 3));
    assert(!h_cv_av1reg(dec, 0, pt, 0) && !h_cv_av1acq(&idx, &sync, dec));
    h_cv_poolfin(pt); assert(!pool_of(pt) && !cv_of(dec)->buf[0].pool);
    uint8_t *nm; uint64_t nz; uint32_t nw, nh, ns;
    assert(!dm_native_image(native, &nm, &nz, &nw, &nh, &ns)); free(mem);
    h_cv_av1rel(dec, 0, sync); assert(!h_cv_av1acq(&idx, &sync, dec) && !h_gs_trywait(&sync));
    assert(!h_cv_av1submit(&id, dec, av1, sizeof av1, 3000, false) && h_gs_trywait(&sync));
    assert(!h_cv_av1fin(dec)); vpx_img_free(old);
}

int main(int argc, char **argv) {
    patterned_av1();
    // A focused software check for machines where VideoToolbox cannot create the unrelated H.264 session. The default check still requires every codec.
    if (argc == 2 && !strcmp(argv[1], "--av1-only")) {
        setenv("DM_AV1_DAV1D", "1", 1); av1_pool_lifetime(); unsetenv("DM_AV1_DAV1D");
        puts("t_codec_video: AV1 acceptance passed (dav1d)"); return 0;
    }
    _Alignas(16) static uint8_t dec[0x400], pool[3][0x40], spt[0x80], mem[16 * 16 * 4];
    uint64_t size, align, id; uint32_t idx; cv_sync sync; uint16_t w, h, cw, ch; int64_t ts; bool eos;

    // Pools: one picture each, NV12 (format 3, as Bananza asks)
    cv_pref pref = h_cv_pref(16, 16, 3, 0);
    assert(!h_cv_poolsize(&size, &align, &pref, 1) && size >= 16 * 16 * 4 && align == CV_NATIVE_ALIGN);
    for (int i = 0; i < 3; i++) assert(!h_cv_pool(pool[i], mem, size, &pref, 1, 0) && pool_of(pool[i]));

    // Decoder: the submission-ready event is bound in its type and signalled
    assert(!h_cv_vp9init2(dec, 0x10000, 16, 16, 1, 1, 3));
    cv_dec *d = cv_of(dec); assert(d && d->vpx_ok);
    void *ev = NULL; assert(!h_cv_vp9event(&ev, dec) && ev == dec + CV_EVENT_OFF && g_ev[ev_slot(ev)].bound && ev_set(ev));

    // Registering makes a buffer acquirable at once, its sync handle signalled; an empty queue answers 3604
    for (uint32_t i = 0; i < 2; i++) assert(!h_cv_vp9reg(dec, i, pool[i], 0));
    for (uint32_t i = 0; i < 2; i++) { assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == i && sync.magic == CV_SYNC && sync.gen == 0 && h_gs_trywait(&sync)); }
    assert(h_cv_vp9acq(&idx, &sync, dec) == CV_NONE);
    assert(h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) == CV_NONE);

    // Released: acquirable again with a new handle that signals once a picture is in the buffer; the picture's properties and its NV12 / RGBA readback
    h_cv_vp9rel(dec, 0, sync);
    assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 0 && sync.gen == 1 && !h_gs_trywait(&sync));
    assert(h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) == CV_NONE);
    assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 1000, false) && id == 1);
    assert(h_gs_trywait(&sync));
    assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) && w == 16 && h == 16 && cw == 16 && ch == 16 && ts == 1000 && !eos);
    uint8_t nv12[16 * 16 * 3 / 2], rgba[16 * 16 * 4];
    assert(!h_cv_nv12(pool[0], 0, 0, 0, 16, 16, nv12, 16, 256, nv12 + 256, 16, 128));
    for (int i = 0; i < 256; i++) assert(abs(nv12[i] - 81) <= 3);
    for (int i = 256; i < 384; i += 2) { assert(abs(nv12[i] - 90) <= 3); assert(abs(nv12[i + 1] - 240) <= 3); }
    uint8_t y[256], uv[128];   // separate planes
    assert(!h_cv_nv12(pool[0], 0, 0, 0, 16, 16, y, 16, 256, uv, 16, 128) && !memcmp(y, nv12, 256) && !memcmp(uv, nv12 + 256, 128));
    assert(!h_cv_rgba(pool[0], 0, 0, 0, 16, 16, rgba, 64, sizeof rgba));
    for (int i = 0; i < 1024; i += 4) assert(rgba[i] >= 250 && rgba[i + 1] <= 5 && rgba[i + 2] <= 5 && rgba[i + 3] == 255);

    // No released buffer: pictures wait (4), then packets are refused (3603) and the event is cleared; a release takes the oldest and signals again
    for (int i = 0; i < CV_HOLD; i++) assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 2000 + i, false));
    assert(d->nheld == CV_HOLD && !ev_set(ev));
    assert(h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 9999, false) == CV_BUSY);
    h_cv_vp9rel(dec, 1, sync);
    assert(d->nheld == CV_HOLD - 1 && ev_set(ev));
    assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 1 && h_gs_trywait(&sync));
    assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 1) && ts == 2000);

    // Sync point event: armed on an unfilled buffer, signalled when the picture lands; one armed on a filled buffer is signalled at once
    assert(!h_spt_create(spt) && g_ev[ev_slot(spt)].bound);
    h_cv_vp9rel(dec, 0, sync);   // buffer 0 takes the next waiting picture at once
    assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 0);
    assert(!h_spt_request(spt, &sync) && ev_set(spt) && !SPT(spt)->armed);
    assert(!h_cv_vp9reg(dec, 2, pool[2], 0) && !h_cv_vp9acq(&idx, &sync, dec) && idx == 2);
    for (int i = 0; i < 2; i++) { h_cv_vp9rel(dec, (uint32_t)i, sync); assert(!h_cv_vp9acq(&idx, &sync, dec)); }   // the last two waiting pictures go out
    h_cv_vp9rel(dec, 2, sync); assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 2 && !h_gs_trywait(&sync));
    assert(!h_spt_request(spt, &sync) && !ev_set(spt) && SPT(spt)->armed);
    assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 3000, false) && ev_set(spt) && !SPT(spt)->armed && h_gs_trywait(&sync));

    // End of stream with no data: the next released buffer carries it, with no picture
    assert(!h_cv_vp9submit(&id, dec, NULL, 0, 0, true) && d->eos_pending);
    h_cv_vp9rel(dec, 2, sync); assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 2 && h_gs_trywait(&sync));
    assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 2) && eos && w == 0 && h == 0);

    // A pool finalized while its buffer is still registered: the buffer keeps working, its picture has nowhere to go (ASan checks no freed pool is written)
    h_cv_poolfin(pool[1]); assert(!pool_of(pool[1]) && d->buf[1].pool == NULL);
    h_cv_vp9rel(dec, 1, sync); assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 1 && !h_gs_trywait(&sync));
    assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 4000, false) && h_gs_trywait(&sync));
    assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 1) && ts == 4000 && w == 16);
    // A flush drops the waiting pictures and restarts the decoder; finalize frees it and destroys its event
    assert(!h_cv_vp9flush(dec) && d->nheld == 0 && d->vpx_ok && ev_set(ev));
    assert(!h_cv_vp9fin(dec) && !cv_of(dec) && !g_ev[ev_slot(ev)].bound);
    // A decoder initialised again in the same memory, cleared in between (Donkey Kong Bananza's second movie): its event is bound anew
    memset(dec, 0, sizeof dec);
    assert(!h_cv_vp9init2(dec, 0x10000, 16, 16, 1, 1, 3) && cv_of(dec) && g_ev[ev_slot(ev)].bound && ev_set(ev));
    assert(!h_cv_vp9fin(dec) && !cv_of(dec) && !g_ev[ev_slot(ev)].bound);
    for (int i = 0; i < 3; i += 2) { h_cv_poolfin(pool[i]); assert(!pool_of(pool[i])); }
    // VP8 (libvpx) and H.264 (VideoToolbox) take the same protocol: one released buffer, one key frame, its picture read back red
    {   _Alignas(16) static uint8_t d8[0x400], p8[0x40], m8[16 * 16 * 4];
        assert(!h_cv_poolsize(&size, &align, &pref, 1) && !h_cv_pool(p8, m8, size, &pref, 1, 0));
        assert(!h_cv_vp8init2(d8, 0x10000, 16, 16, 1, 1, 3) && cv_of(d8) && cv_of(d8)->codec == CV_VP8 && cv_of(d8)->vpx_ok);
        assert(!h_cv_vp8reg(d8, 0, p8, 0) && !h_cv_vp8acq(&idx, &sync, d8) && idx == 0);
        h_cv_vp8rel(d8, 0, sync); assert(!h_cv_vp8acq(&idx, &sync, d8) && !h_gs_trywait(&sync));
        assert(!h_cv_vp8submit(&id, d8, vp8, sizeof vp8, 7000, false) && h_gs_trywait(&sync));
        assert(!h_cv_vp8props(&w, &h, &cw, &ch, &ts, &eos, d8, 0) && w == 16 && h == 16 && ts == 7000);
        assert(!h_cv_nv12(p8, 0, 0, 0, 16, 16, nv12, 16, 256, nv12 + 256, 16, 128));
        for (int i = 0; i < 256; i++) assert(abs(nv12[i] - 81) <= 3);
        for (int i = 256; i < 384; i += 2) { assert(abs(nv12[i] - 90) <= 4); assert(abs(nv12[i + 1] - 240) <= 4); }
        // Unregistered: no longer acquirable or filled
        h_cv_vp8rel(d8, 0, sync); assert(!h_cv_vp8unreg(d8, 0) && h_cv_vp8acq(&idx, &sync, d8) == CV_NONE && !cv_of(d8)->buf[0].reg);
        assert(!h_cv_vp8fin(d8) && !cv_of(d8)); h_cv_poolfin(p8);
    }
    {   _Alignas(16) static uint8_t dh[0x400], ph[0x40], mh[64 * 64 * 4]; static uint8_t yuv[64 * 64 * 3 / 2];
        cv_pref p64 = h_cv_pref(64, 64, 3, 0);
        assert(!h_cv_poolsize(&size, &align, &p64, 1) && !h_cv_pool(ph, mh, size, &p64, 1, 0));
        assert(!h_cv_h264init2(dh, 0x10000, 64, 64, 1, 1, 3) && cv_of(dh) && cv_of(dh)->codec == CV_H264 && cv_of(dh)->avc);
        assert(!h_cv_h264reg(dh, 0, ph, 0) && !h_cv_h264acq(&idx, &sync, dh));
        h_cv_h264rel(dh, 0, sync); assert(!h_cv_h264acq(&idx, &sync, dh) && !h_gs_trywait(&sync));
        assert(!h_cv_h264submit(&id, dh, h264, sizeof h264, 5000000, true) && h_gs_trywait(&sync));   // end of stream: VideoToolbox gives its picture out
        assert(!h_cv_h264props(&w, &h, &cw, &ch, &ts, &eos, dh, 0) && w == 64 && h == 64 && ts == 5000000 && eos);
        assert(!h_cv_nv12(ph, 0, 0, 0, 64, 64, yuv, 64, 4096, yuv + 4096, 64, 2048));
        for (int i = 0; i < 4096; i++) assert(abs(yuv[i] - 81) <= 4);
        for (int i = 4096; i < 6144; i += 2) { assert(abs(yuv[i] - 90) <= 6); assert(abs(yuv[i + 1] - 240) <= 6); }
        assert(!h_cv_h264fin(dh) && !cv_of(dh)); h_cv_poolfin(ph);
    }
    {   // AV1: a decoder of its own codec through SDK 22's entry point, whose last two arguments lie on the stack (the guest's 8-byte slots), and a packet with no sequence header yet gives no picture
        uint8_t da[0x400]; memset(da, 0, sizeof da);
        assert(!h_cv_av1tm(da, NULL, 0, 0x10000, 0xabcd0080, 0xabcd0040, 1, 3, 2, 2) && cv_of(da) && cv_of(da)->codec == CV_AV1 && cv_of(da)->w == 0x80 && cv_of(da)->h == 0x40);
        assert(h_cv_av1ev22(da) == da + CV_EVENT_OFF && ev_set(da + CV_EVENT_OFF));
        static const uint8_t delimiter[] = {0x12, 0x00};   // a temporal delimiter OBU alone
        uint64_t n; assert(!h_cv_av1submit(&n, da, delimiter, sizeof delimiter, 0, false) && !cv_of(da)->nheld);
        assert(!h_cv_av1fin(da) && !cv_of(da));
        // The av1C record from a sequence header: profile 0, one operating point at level 12 (tier 0), 2560x1440, 8-bit 4:2:0 with chroma position 0, written field by field
        uint8_t obu[32] = {0x0a, 0}; size_t bit = 16;
        #define PUT(v, nb) do { for (int k_ = (nb) - 1; k_ >= 0; k_--, bit++) if (((uint32_t)(v) >> k_) & 1) obu[bit / 8] |= (uint8_t)(0x80 >> (bit % 8)); } while (0)
        PUT(0, 3); PUT(0, 1); PUT(0, 1);            // profile, still picture, reduced header
        PUT(0, 1); PUT(0, 1); PUT(0, 5);            // no timing info, no display delay, one operating point
        PUT(0, 12); PUT(12, 5); PUT(0, 1);          // idc, level 12, tier
        PUT(11, 4); PUT(10, 4); PUT(2559, 12); PUT(1439, 11);   // frame size bits and frame size
        PUT(0, 1); PUT(0, 3); PUT(0, 4);            // no frame ids, block tools, inter tools
        PUT(1, 1); PUT(0, 2);                       // order hint, jnt_comp and ref_frame_mvs
        PUT(1, 1); PUT(1, 1);                       // screen content tools: choose; integer mv: choose
        PUT(6, 3); PUT(0, 3);                       // order hint bits, superres / cdef / restoration
        PUT(0, 1); PUT(0, 1); PUT(0, 1);            // not high bit depth, not monochrome, no colour description
        PUT(0, 1); PUT(0, 2); PUT(0, 1);            // colour range, chroma position, separate delta q
        #undef PUT
        obu[1] = (uint8_t)((bit + 7) / 8 - 2);
        uint8_t c[4]; int aw = 0, ah = 0;
        assert(mav1_av1c(obu, (bit + 7) / 8, c, &aw, &ah) && aw == 2560 && ah == 1440);
        assert(c[0] == 0x81 && c[1] == 12 && c[2] == 0x0c && c[3] == 0);
        size_t seqn = 0; assert(find_seq(obu, (bit + 7) / 8, &seqn) == obu && seqn == (bit + 7) / 8);
        assert(!mav1_av1c(delimiter, sizeof delimiter, c, &aw, &ah) && !find_seq(delimiter, sizeof delimiter, &seqn));
        // The red frame on each backend this Mac has (VideoToolbox where the chip decodes AV1, and dav1d, which DM_AV1_DAV1D=1 picks), as NV12: Y 81, Cb 90, Cr 240 (BT.601, video range)
        for (int soft = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? 0 : 1; soft < 2; soft++) {
            setenv("DM_AV1_DAV1D", soft ? "1" : "0", 1);
            mav1 *a = mav1_new(); assert(!strcmp(mav1_backend(a), soft ? "dav1d" : "VideoToolbox"));
            mav1_picture pic; assert(mav1_decode(a, av1, sizeof av1, &pic) == 1 && pic.w == 64 && pic.h == 64 && pic.matrix == 1 && !pic.full_range);   // no matrix in the stream: BT.601 at 64 lines
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) assert(abs(pic.y[(size_t)y * pic.ystride + x] - 81) <= 4);
            for (int y = 0; y < 32; y++) for (int x = 0; x < 64; x += 2) { assert(abs(pic.uv[(size_t)y * pic.uvstride + x] - 90) <= 6); assert(abs(pic.uv[(size_t)y * pic.uvstride + x + 1] - 240) <= 6); }
            mav1_reset(a); assert(mav1_decode(a, delimiter, sizeof delimiter, &pic) == 0);   // a new stream: nothing until its sequence header
            mav1_free(a);
            av1_pool_lifetime();
        }
        unsetenv("DM_AV1_DAV1D");
    }
    {   // A native image: SDK 22's preference and pool, the handle names the pool's memory, and a picture lands there as RGBA in NVN's linear layout
        cv_pref p = h_cv_pref22(0xffff0020, 0xffff0010, 2, 2); assert(p.w == 32 && p.h == 16);
        uint64_t sz, al; assert(!h_cv_poolsize(&sz, &al, &p, 2) && al == CV_NATIVE_ALIGN && sz == 2 * CV_NATIVE_ALIGN);
        uint8_t pt[0x40] = {0}; void *m; assert(!posix_memalign(&m, al, sz)); memset(m, 0, sz);
        assert(!h_cv_pool22(pt, m, sz, &p, 2));
        uint32_t ha = h_cv_native(pt, 1), nw, nh, ns; uint8_t *nm = NULL; uint64_t nz;
        assert(ha && dm_native_image(ha, &nm, &nz, &nw, &nh, &ns) && nm == (uint8_t *)m + CV_NATIVE_ALIGN && nz == CV_NATIVE_ALIGN && nw == 32 && nh == 16 && ns == 128);
        vpx_image_t *im = black_i420(32, 16); im->range = VPX_CR_STUDIO_RANGE;
        pool_native_write(pool_of(pt), 1, im); vpx_img_free(im);
        assert(nm[0] == 0 && nm[3] == 255 && nm[ns * 15 + 31 * 4 + 3] == 255);
        h_cv_poolfin(pt); assert(!dm_native_image(ha, &nm, &nz, &nw, &nh, &ns)); free(m);
    }
    printf("t_codec_video: all passed\n");
    return 0;
}
