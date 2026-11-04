#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "dm.h"
#include "stream_proto.h"
#include "dm_input.h"
#include <math.h>
#if __has_include("host_rev.h")
#include "host_rev.h"
#endif

#ifndef DM_HOST_REV
#define DM_HOST_REV "unknown"
#endif

#define ST_SLOTS 4
#define ST_WINDOW 600
#define ST_QUEUE_FRAMES 8
#define ST_QUEUE_AUDIO 40
#define ST_STATS_MAX 256

enum { ST_FORCE_NONE, ST_FORCE_REFRESH, ST_FORCE_KEY };
enum { ST_CONTROL, ST_VIDEO, ST_AUDIO };

typedef struct { uint64_t ticket, capture_ns, gpu_ns, submit_ns; double pass_ms; uint32_t gen; int force; } st_frame;
typedef struct st_item { struct st_item *next; uint8_t *data; size_t len, heads[2]; int nheads, kind; uint32_t gen; } st_item;

static pthread_mutex_t g_st_mu = PTHREAD_MUTEX_INITIALIZER;
static VTCompressionSessionRef g_st_vt;
static CVPixelBufferRef g_st_px[ST_SLOTS];
static uint32_t g_st_gen;
static int g_st_w, g_st_h;
static int g_st_ltr = 1, g_st_acked, g_st_attached, g_st_src_w, g_st_src_h, g_st_hevc, g_st_kbps;
static NSMutableArray<NSNumber *> *g_st_acks;
static _Atomic int g_st_busy[ST_SLOTS], g_st_force, g_st_sending;
static st_frame g_st_slot[ST_SLOTS];
static dispatch_queue_t g_st_encq, g_st_writeq;
static int g_st_fd = -1, g_st_tsv = -1, g_st_nal = 4;
static CMFormatDescriptionRef g_st_fmt;
static uint64_t g_st_seq;
static _Atomic uint64_t g_st_drops, g_st_failed, g_st_encoder_drops, g_st_last_done, g_st_queue_drops, g_st_pauses, g_st_pad_msgs;
static struct { double enc[ST_WINDOW], total[ST_WINDOW], pass[ST_WINDOW]; int n; uint64_t frames, bytes, sync, ltr, waited, first_ns, last_ns; } g_st_win;
static struct { double enc[ST_STATS_MAX]; int n; uint64_t frames, bytes, since_ns; } g_st_sec;
static const uint8_t g_st_start[4] = {0, 0, 0, 1};

static char g_st_path[DMS_SUN_PATH_MAX + 1];
static pthread_mutex_t g_st_qmu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_st_qcv = PTHREAD_COND_INITIALIZER;
static st_item *g_st_qhead, *g_st_qtail;
static int g_st_qvideo, g_st_qaudio, g_st_link_up, g_st_link_broken, g_st_until_refresh;
static uint32_t g_st_qgen;
static _Atomic int g_st_hub_hello, g_st_refused;
static _Atomic uint32_t g_st_pads_mask;

void dm_audio_stream(void (*sink)(uint64_t time_ns, const int16_t *pcm, int frames));
void dm_focus_stream(int state);
void mtl_stream_pace(int on);
void dm_app_suspend(int on);
void dm_audio_suspend(int on);

static int g_st_paused;
static char g_st_why[160];
static _Atomic uint64_t g_st_pad_ns[DM_PLAYERS];
static pthread_mutex_t g_st_pad_mu = PTHREAD_MUTEX_INITIALIZER;
static dispatch_source_t g_st_pad_timer;

static int st_env(const char *name, int fallback) { const char *e = getenv(name); return e && *e ? atoi(e) : fallback; }

static void st_write(int fd, const void *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) { static int once; if (!once++) LOG("[RED] stream: cannot write the stream file (%s)", strerror(errno)); return; }
        p = (const uint8_t *)p + w; n -= (size_t)w;
    }
}

static void st_sort(double *a, int n) {
    for (int i = 1; i < n; i++) { double x = a[i]; int j = i - 1; while (j >= 0 && a[j] > x) { a[j + 1] = a[j]; j--; } a[j + 1] = x; }
}

static void st_request(int force) {
    int cur = atomic_load(&g_st_force);
    while (cur < force && !atomic_compare_exchange_weak(&g_st_force, &cur, force)) {}
}

static void st_free_item(st_item *it) { free(it->data); free(it); }

static void st_drop_queued(int keep_control) {
    st_item **pp = &g_st_qhead; g_st_qtail = NULL;
    while (*pp) {
        st_item *it = *pp;
        if (keep_control && it->kind == ST_CONTROL) { g_st_qtail = it; pp = &it->next; continue; }
        *pp = it->next; st_free_item(it);
    }
    g_st_qvideo = g_st_qaudio = 0;
}

static void st_enqueue(st_item *it, uint16_t flags) {
    pthread_mutex_lock(&g_st_qmu);
    if (!g_st_link_up) { pthread_mutex_unlock(&g_st_qmu); st_free_item(it); return; }
    if (it->kind == ST_VIDEO && it->gen != g_st_qgen) { pthread_mutex_unlock(&g_st_qmu); st_free_item(it); return; }
    if (it->kind == ST_VIDEO) {
        int fresh = flags & (DMS_FRAME_SYNC | DMS_FRAME_REFRESH);
        if ((g_st_until_refresh && !fresh) || g_st_qvideo >= ST_QUEUE_FRAMES) {
            if (g_st_qvideo >= ST_QUEUE_FRAMES) { g_st_until_refresh = 1; st_request(ST_FORCE_REFRESH); }
            atomic_fetch_add(&g_st_queue_drops, 1);
            pthread_mutex_unlock(&g_st_qmu); st_free_item(it); return;
        }
        g_st_until_refresh = 0; g_st_qvideo++;
    } else if (it->kind == ST_AUDIO) {
        if (g_st_qaudio >= ST_QUEUE_AUDIO) {
            st_item **pp = &g_st_qhead, *prev = NULL;
            while (*pp && (*pp)->kind != ST_AUDIO) { prev = *pp; pp = &(*pp)->next; }
            if (*pp) { st_item *old = *pp; *pp = old->next; if (g_st_qtail == old) g_st_qtail = prev; st_free_item(old); g_st_qaudio--; }
        }
        g_st_qaudio++;
    }
    it->next = NULL;
    if (g_st_qtail) g_st_qtail->next = it; else g_st_qhead = it;
    g_st_qtail = it;
    pthread_cond_signal(&g_st_qcv);
    pthread_mutex_unlock(&g_st_qmu);
}

static uint8_t *st_head(uint8_t *w, uint16_t type, uint16_t flags, size_t payload) {
    dms_header h = {(uint32_t)payload, type, flags, 0};
    memcpy(w, &h, sizeof h);
    return w + sizeof h;
}

static void st_send_control(uint16_t type, uint16_t flags, const void *payload, size_t n) {
    st_item *it = calloc(1, sizeof *it);
    it->data = malloc(DMS_HEADER + n); it->len = DMS_HEADER + n; it->nheads = 1; it->kind = ST_CONTROL;
    uint8_t *w = st_head(it->data, type, flags, n);
    if (n) memcpy(w, payload, n);
    st_enqueue(it, 0);
}

static void st_send_hello(void) {
    char build[256]; int bn = snprintf(build, sizeof build, "dmhost %s %s built %s %s", DM_GAME_ID, DM_HOST_REV, __DATE__, __TIME__);
    if (bn < 0) bn = 0;
    if (bn >= (int)sizeof build) bn = (int)sizeof build - 1;
    uint8_t p[sizeof build + 64], *w = p;
    dms_put32(&w, DMS_VERSION); dms_put64(&w, DM_GAME_PROGRAM_ID);
    dms_put16(&w, (uint16_t)g_st_src_w); dms_put16(&w, (uint16_t)g_st_src_h);
    dms_put32(&w, 48000); dms_put8(&w, 2); dms_put8(&w, 2); dms_put8(&w, 0); dms_put8(&w, 0);
    dms_put32(&w, DMS_AVC1); dms_put32(&w, DMS_HVC1);
    dms_put(&w, build, (size_t)bn);
    st_send_control(DMS_HELLO, 0, p, (size_t)(w - p));
}

static void st_audio(uint64_t time_ns, const int16_t *pcm, int frames) {
    if (!atomic_load(&g_st_sending)) return;
    size_t n = (size_t)frames * 2 * sizeof *pcm;
    st_item *it = calloc(1, sizeof *it);
    it->data = malloc(DMS_HEADER + 12 + n); it->len = DMS_HEADER + 12 + n; it->nheads = 1; it->kind = ST_AUDIO;
    uint8_t *w = st_head(it->data, DMS_AUDIO, 0, 12 + n);
    dms_put64(&w, time_ns); dms_put32(&w, (uint32_t)frames); dms_put(&w, pcm, n);
    st_enqueue(it, 0);
}

static void st_window_log(void) {
    st_sort(g_st_win.enc, g_st_win.n); st_sort(g_st_win.total, g_st_win.n); st_sort(g_st_win.pass, g_st_win.n);
    double secs = (g_st_win.last_ns - g_st_win.first_ns) / 1e9;
    LOG("[stream] frames %llu: encode p50 %.2f ms / p95 %.2f / max %.2f; present to encoded p50 %.2f ms / p95 %.2f / max %.2f; capture pass GPU p50 %.3f ms / p95 %.3f; %.1f Mbit/s; sync frames %llu, LTR frames %llu; "
        "dropped: ring full %llu, by the encoder %llu; failed %llu; waited for the previous frame %llu; dropped from the socket queue %llu",
        (unsigned long long)g_st_win.frames, g_st_win.enc[g_st_win.n / 2], g_st_win.enc[g_st_win.n * 95 / 100], g_st_win.enc[g_st_win.n - 1],
        g_st_win.total[g_st_win.n / 2], g_st_win.total[g_st_win.n * 95 / 100], g_st_win.total[g_st_win.n - 1], g_st_win.pass[g_st_win.n / 2], g_st_win.pass[g_st_win.n * 95 / 100], secs > 0 ? g_st_win.bytes * 8 / secs / 1e6 : 0,
        (unsigned long long)g_st_win.sync, (unsigned long long)g_st_win.ltr, (unsigned long long)atomic_load(&g_st_drops),
        (unsigned long long)atomic_load(&g_st_encoder_drops), (unsigned long long)atomic_load(&g_st_failed), (unsigned long long)g_st_win.waited,
        (unsigned long long)atomic_load(&g_st_queue_drops));
    g_st_win.n = 0; g_st_win.bytes = 0; g_st_win.waited = 0; g_st_win.first_ns = 0;
}

static void st_pads_stale(uint64_t now) {
    pthread_mutex_lock(&g_st_pad_mu);
    uint32_t m = atomic_load(&g_st_pads_mask);
    for (int p = 0; p < DM_PLAYERS; p++) {
        uint64_t t = atomic_load(&g_st_pad_ns[p]);
        if (!(m >> p & 1) || !t || now < t || now - t <= 1000000000ull) continue;
        atomic_store(&g_st_pad_ns[p], 0);
        dm_net_pad_set(p, 0, 0, 0, 0, 0); dm_motion_clear_net(p);
        LOG("[stream] no PAD for player %d in over a second: its controller is released until the next one", p + 1);
    }
    pthread_mutex_unlock(&g_st_pad_mu);
}

static void st_pads_release(void) {
    pthread_mutex_lock(&g_st_pad_mu);
    if (atomic_exchange(&g_st_pads_mask, 0)) LOG("[stream] the hub's controllers are released");
    for (int p = 0; p < DM_PLAYERS; p++) atomic_store(&g_st_pad_ns[p], 0);
    dm_net_pads(0);
    pthread_mutex_unlock(&g_st_pad_mu);
}

static void st_stats(uint64_t now) {
    if (!g_st_sec.since_ns) { g_st_sec.since_ns = now; return; }
    if (now - g_st_sec.since_ns < 1000000000ull) return;
    double secs = (now - g_st_sec.since_ns) / 1e9;
    st_sort(g_st_sec.enc, g_st_sec.n);
    char t[256];
    int n = snprintf(t, sizeof t, "frames=%llu encode_p50_ms=%.2f encode_p95_ms=%.2f queue_drops=%llu ring_drops=%llu kbps=%.0f",
                     (unsigned long long)g_st_sec.frames, g_st_sec.n ? g_st_sec.enc[g_st_sec.n / 2] : 0, g_st_sec.n ? g_st_sec.enc[g_st_sec.n * 95 / 100] : 0,
                     (unsigned long long)atomic_load(&g_st_queue_drops), (unsigned long long)atomic_load(&g_st_drops), g_st_sec.bytes * 8 / secs / 1e3);
    if (atomic_load(&g_st_sending)) st_send_control(DMS_STATS, 0, t, (size_t)(n < (int)sizeof t ? n : (int)sizeof t - 1));
    g_st_sec.n = 0; g_st_sec.frames = 0; g_st_sec.bytes = 0; g_st_sec.since_ns = now;
}

static int st_param_sets(CMFormatDescriptionRef fd, NSMutableData *annexb, NSMutableData *config) {
    int hevc = CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC;
    size_t count = 0; int hl = 4;
    OSStatus s = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, NULL, NULL, &count, &hl)
                      : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, NULL, NULL, &count, &hl);
    if (s) return 0;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *p = NULL; size_t n = 0;
        s = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &p, &n, NULL, NULL)
                 : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, i, &p, &n, NULL, NULL);
        if (s || n > 0xffff) return 0;
        [annexb appendBytes:g_st_start length:4]; [annexb appendBytes:p length:n];
        uint16_t len = (uint16_t)n; [config appendBytes:&len length:2]; [config appendBytes:p length:n];
    }
    g_st_nal = hl;
    return 1;
}

static void st_send_frame(NSData *config, NSData *avcc, const st_frame *f, int sync, long long token) {
    uint16_t flags = (uint16_t)((sync ? DMS_FRAME_SYNC : 0) | (f->force == ST_FORCE_REFRESH ? DMS_FRAME_REFRESH : 0));
    size_t cfg = config ? DMS_HEADER + config.length : 0, frame = DMS_HEADER + 24 + avcc.length;
    st_item *it = calloc(1, sizeof *it);
    it->data = malloc(cfg + frame); it->len = cfg + frame; it->kind = ST_VIDEO; it->gen = f->gen;
    uint8_t *w = it->data;
    if (config) { it->heads[it->nheads++] = 0; w = st_head(w, DMS_VIDEO_CONFIG, 0, config.length); dms_put(&w, config.bytes, config.length); }
    it->heads[it->nheads++] = (size_t)(w - it->data);
    w = st_head(w, DMS_VIDEO_FRAME, flags, 24 + avcc.length);
    dms_put64(&w, f->capture_ns); dms_put64(&w, g_st_seq); dms_put64(&w, (uint64_t)token);
    dms_put(&w, avcc.bytes, avcc.length);
    st_enqueue(it, flags);
}

static void st_frame_out(CMSampleBufferRef sb, st_frame f, uint64_t start_ns, uint64_t done_ns) {
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    CFDictionaryRef a = att && CFArrayGetCount(att) ? CFArrayGetValueAtIndex(att, 0) : NULL;
    int sync = !(a && CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync) == kCFBooleanTrue);
    CFNumberRef tok = a ? CFDictionaryGetValue(a, kVTSampleAttachmentKey_RequireLTRAcknowledgementToken) : NULL;
    long long token = -1; if (tok) CFNumberGetValue(tok, kCFNumberLongLongType, &token);
    NSMutableData *out = [[NSMutableData alloc] init], *config = nil, *avcc = [[NSMutableData alloc] init];
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (fd && (sync || !g_st_fmt || !CFEqual(fd, g_st_fmt))) {
        config = [[NSMutableData alloc] init];
        if (!st_param_sets(fd, out, config)) { config = nil; static int once; if (!once++) LOG("[RED] stream: no parameter sets in the encoder's format description"); }
        if (g_st_fmt) CFRelease(g_st_fmt);
        g_st_fmt = (CMFormatDescriptionRef)CFRetain(fd);
    }
    CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
    size_t len = bb ? CMBlockBufferGetDataLength(bb) : 0;
    uint8_t *buf = malloc(len ? len : 1);
    if (len && CMBlockBufferCopyDataBytes(bb, 0, len, buf)) len = 0;
    for (size_t o = 0; o + (size_t)g_st_nal <= len;) {
        size_t n = 0; for (int k = 0; k < g_st_nal; k++) n = n << 8 | buf[o + k];
        o += (size_t)g_st_nal;
        if (n > len - o) { static int once; if (!once++) LOG("[RED] stream: a NAL unit runs past its sample (%zu of %zu bytes)", n, len - o); break; }
        [out appendBytes:g_st_start length:4]; [out appendBytes:buf + o length:n];
        uint8_t be[4] = {(uint8_t)(n >> 24), (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n}; [avcc appendBytes:be length:4]; [avcc appendBytes:buf + o length:n];
        o += n;
    }
    free(buf);
    if (g_st_fd >= 0) st_write(g_st_fd, out.bytes, out.length);
    if (atomic_load(&g_st_sending)) st_send_frame(config, avcc, &f, sync, token);
    g_st_seq++;
    double gpu = (f.gpu_ns - f.capture_ns) / 1e6, queue = (f.submit_ns - f.gpu_ns) / 1e6, wait = (start_ns - f.submit_ns) / 1e6, enc = (done_ns - start_ns) / 1e6, total = (done_ns - f.capture_ns) / 1e6;
    if (g_st_tsv >= 0) {
        char line[256];
        int n = snprintf(line, sizeof line, "%llu\t%llu\t%llu\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%lu\t%d\t%lld\n", (unsigned long long)g_st_win.frames, (unsigned long long)f.ticket,
                         (unsigned long long)f.capture_ns, f.pass_ms, gpu, queue, wait, enc, total, (unsigned long)out.length, sync, token);
        st_write(g_st_tsv, line, (size_t)n);
    }
    g_st_win.frames++; g_st_win.sync += sync; g_st_win.ltr += token >= 0; g_st_win.bytes += out.length; g_st_win.waited += start_ns > f.submit_ns;
    if (!g_st_win.first_ns) g_st_win.first_ns = f.capture_ns;
    g_st_win.last_ns = f.capture_ns;
    g_st_win.enc[g_st_win.n] = enc; g_st_win.total[g_st_win.n] = total; g_st_win.pass[g_st_win.n] = f.pass_ms;
    if (++g_st_win.n == ST_WINDOW) st_window_log();
    if (g_st_sec.n < ST_STATS_MAX) g_st_sec.enc[g_st_sec.n++] = enc;
    g_st_sec.frames++; g_st_sec.bytes += avcc.length;
    st_stats(done_ns);
}

static void st_restart(void);
static void st_encoded(void *session_ref, void *frame_ref, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
    (void)session_ref;
    int i = (int)(intptr_t)frame_ref;
    uint64_t done = now_ns();
    st_frame f = g_st_slot[i];
    uint64_t prev = atomic_exchange(&g_st_last_done, done), start = prev > f.submit_ns ? prev : f.submit_ns;
    atomic_store(&g_st_busy[i], 0);
    if (status || !sb || (flags & kVTEncodeInfo_FrameDropped)) {
        if (status) { atomic_fetch_add(&g_st_failed, 1); static int once; if (!once++) LOG("[RED] stream: the encoder failed a frame (%d)", (int)status); }
        else atomic_fetch_add(&g_st_encoder_drops, 1);
        if (f.force) st_request(f.force);
        if (status == kVTInvalidSessionErr) dispatch_async(g_st_encq, ^{ if (g_st_vt && f.gen == g_st_gen) st_restart(); });
        return;
    }
    CFRetain(sb);
    dispatch_async(g_st_writeq, ^{ st_frame_out(sb, f, start, done); CFRelease(sb); });
}

static void st_prop(VTCompressionSessionRef vt, CFStringRef key, CFTypeRef value) {
    OSStatus s = VTSessionSetProperty(vt, key, value);
    if (s) LOG("[RED] stream: the encoder refused %s (%d)", CFStringGetCStringPtr(key, kCFStringEncodingUTF8) ?: "a property", (int)s);
}

static void st_stop(void) {
    pthread_mutex_lock(&g_st_mu);
    VTCompressionSessionRef vt = g_st_vt; g_st_vt = NULL;
    CVPixelBufferRef px[ST_SLOTS]; memcpy(px, g_st_px, sizeof px); memset(g_st_px, 0, sizeof g_st_px);
    pthread_mutex_unlock(&g_st_mu);
    if (!vt) return;
    VTCompressionSessionCompleteFrames(vt, kCMTimeInvalid);
    VTCompressionSessionInvalidate(vt); CFRelease(vt);
    for (int i = 0; i < ST_SLOTS; i++) if (px[i]) CVPixelBufferRelease(px[i]);
}

static int st_start(int w, int h, int hevc, int kbps) {
    st_stop();
    NSDictionary *spec = @{(__bridge id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES,
                           (__bridge id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
    NSDictionary *source = @{(__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (__bridge id)kCVPixelBufferWidthKey: @(w),
                             (__bridge id)kCVPixelBufferHeightKey: @(h), (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                             (__bridge id)kCVPixelBufferMetalCompatibilityKey: @YES};
    VTCompressionSessionRef vt = NULL;
    OSStatus s = VTCompressionSessionCreate(NULL, w, h, hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, (__bridge CFDictionaryRef)spec,
                                            (__bridge CFDictionaryRef)source, NULL, st_encoded, NULL, &vt);
    if (s) { snprintf(g_st_why, sizeof g_st_why, "no low-latency hardware %s encoder (%d)", hevc ? "HEVC" : "H.264", (int)s); LOG("[RED] stream: %s", g_st_why); return 0; }
    st_prop(vt, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    st_prop(vt, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    st_prop(vt, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@60);
    st_prop(vt, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@((long long)kbps * 1000));
    st_prop(vt, kVTCompressionPropertyKey_ProfileLevel, hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel);
    st_prop(vt, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    st_prop(vt, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    st_prop(vt, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    if (g_st_ltr) st_prop(vt, kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue);
    VTCompressionSessionPrepareToEncodeFrames(vt);
    CVPixelBufferRef px[ST_SLOTS] = {0};
    for (int i = 0; i < ST_SLOTS; i++) {
        if (CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)source, &px[i]) || !CVPixelBufferGetIOSurface(px[i])) {
            snprintf(g_st_why, sizeof g_st_why, "cannot create the IOSurface pixel buffers (%dx%d)", w, h); LOG("[RED] stream: %s", g_st_why);
            for (int k = 0; k <= i; k++) if (px[k]) CVPixelBufferRelease(px[k]);
            VTCompressionSessionInvalidate(vt); CFRelease(vt);
            return 0;
        }
        CVBufferSetAttachment(px[i], kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(px[i], kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(px[i], kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    }
    g_st_acked = 0; [g_st_acks removeAllObjects];
    atomic_store(&g_st_force, ST_FORCE_KEY);
    pthread_mutex_lock(&g_st_mu);
    g_st_vt = vt; memcpy(g_st_px, px, sizeof px); g_st_gen++; g_st_w = w; g_st_h = h; g_st_hevc = hevc; g_st_kbps = kbps;
    pthread_mutex_unlock(&g_st_mu);
    LOG("[stream] %s %dx%d, %d kbit/s, low-latency rate control, LTR %s, %d frames in flight", hevc ? "HEVC" : "H.264", w, h, kbps, g_st_ltr ? "on" : "off", ST_SLOTS);
    return 1;
}

static void st_client(int on) {
    if (g_st_attached == on) return;
    g_st_attached = on;
    dm_audio_stream(on ? st_audio : NULL);
    dm_focus_stream(on ? 1 : g_st_paused ? 2 : 0);
    mtl_stream_pace(on || g_st_paused);
}

static void st_attach_result(int ok, int w, int h, uint32_t codec, const char *why) {
    uint8_t p[12 + sizeof g_st_why], *w8 = p;
    dms_put8(&w8, (uint8_t)ok); dms_put8(&w8, 0); dms_put16(&w8, (uint16_t)w); dms_put16(&w8, (uint16_t)h); dms_put16(&w8, 0); dms_put32(&w8, codec);
    size_t n = why ? strnlen(why, sizeof g_st_why) : 0;
    if (n) dms_put(&w8, why, n);
    st_send_control(DMS_ATTACH_RESULT, 0, p, (size_t)(w8 - p));
}

static void st_restart(void) {
    LOG("[RED] stream: VideoToolbox invalidated the encoder session: making it again at %dx%d, %d kbit/s", g_st_w, g_st_h, g_st_kbps);
    int ok = st_start(g_st_w, g_st_h, g_st_hevc, g_st_kbps);
    pthread_mutex_lock(&g_st_qmu); g_st_qgen = ok ? g_st_gen : 0; st_drop_queued(1); pthread_mutex_unlock(&g_st_qmu);
    if (!ok) { st_attach_result(0, g_st_w, g_st_h, g_st_hevc ? DMS_HVC1 : DMS_AVC1, g_st_why); atomic_store(&g_st_sending, 0); st_client(0); }
}

static void st_detach(int pause, const char *why) {
    __block int suspend = 0, resume = 0;
    st_pads_release();
    dispatch_sync(g_st_encq, ^{
        int was = g_st_attached;
        if (pause && was && !g_st_paused) { g_st_paused = suspend = 1; dm_audio_suspend(1); }
        else if (!pause && g_st_paused) { g_st_paused = 0; resume = 1; mtl_stream_pace(0); }
        atomic_store(&g_st_sending, 0);
        st_client(0);
        st_stop();
        pthread_mutex_lock(&g_st_qmu); g_st_qgen = 0; st_drop_queued(1); pthread_mutex_unlock(&g_st_qmu);
        if (suspend) atomic_fetch_add(&g_st_pauses, 1);
        if (was) LOG("[stream] %s: the encoder stopped%s", why, suspend ? "; the game is paused until the next ATTACH" : "");
    });
    if (suspend) { dm_app_suspend(1); LOG("[stream] the game is paused, as the Switch's HOME button pauses it"); }
    if (resume) { dm_app_suspend(0); dm_focus_stream(0); LOG("[stream] %s: the paused game goes on at the Mac", why); }
}

static void st_attach(int w, int h, uint32_t codec, int kbps, int hz, NSString *note) {
    dispatch_async(g_st_encq, ^{
        int was = g_st_attached, ok = st_start(w, h, codec == DMS_HVC1, kbps);
        st_attach_result(ok, w, h, codec, ok ? note.UTF8String : g_st_why);
        pthread_mutex_lock(&g_st_qmu); g_st_qgen = ok ? g_st_gen : 0; st_drop_queued(1); pthread_mutex_unlock(&g_st_qmu);
        if (!ok) { atomic_store(&g_st_sending, 0); st_client(0); return; }
        atomic_store(&g_st_sending, 1);
        st_client(1);
        LOG("[stream] a client %s: %dx%d at %d Hz, %d kbit/s", was ? "attached again" : "attached", w, h, hz, kbps);
        if (g_st_paused) { g_st_paused = 0; dm_app_suspend(0); LOG("[stream] the paused game goes on for the client"); }
    });
}

static int st_hub_message(const dms_header *h, uint8_t *p, uint32_t n) {
    dms_reader r = {p, p + n, 0};
    switch (h->type) {
    case DMS_HELLO: {
        uint32_t v = dms_get32(&r);
        if (r.bad || v != DMS_VERSION) {
            LOG("[RED] stream: the hub speaks protocol %u, this host speaks %d: closing, not connecting again", v, DMS_VERSION);
            atomic_store(&g_st_refused, 1); return 0;
        }
        atomic_store(&g_st_hub_hello, 1);
        LOG("[stream] the hub speaks protocol %u", v);
        return 1;
    }
    case DMS_ATTACH: {
        int hz = dms_get16(&r), w = dms_get16(&r), hh = dms_get16(&r); dms_get16(&r);
        uint32_t codec = dms_get32(&r); int kbps = (int)dms_get32(&r);
        if (r.bad) { LOG("[RED] stream: a short ATTACH from the hub (%u bytes), ignored", n); st_attach_result(0, 0, 0, 0, "a short ATTACH"); return 1; }
        if (!atomic_load(&g_st_hub_hello)) { LOG("[RED] stream: ATTACH before the hub's HELLO, ignored"); st_attach_result(0, w, hh, codec, "ATTACH before the hub's HELLO"); return 1; }
        if (codec != DMS_AVC1 && codec != DMS_HVC1) { LOG("[RED] stream: ATTACH asks for codec %#x, which HELLO did not list: ignored", codec); st_attach_result(0, w, hh, codec, "a codec HELLO did not list"); return 1; }
        NSString *note = nil;
        if (w < 64 || hh < 64 || w > 4096 || hh > 4096) {
            LOG("[RED] stream: ATTACH asks for %dx%d (64 to 4096): using 1920x1080", w, hh);
            note = [NSString stringWithFormat:@"the size asked for, %dx%d, is outside 64 to 4096: 1920x1080 instead", w, hh]; w = 1920; hh = 1080;
        } else if ((w | hh) & 1) note = [NSString stringWithFormat:@"the size asked for, %dx%d, is rounded down to even numbers", w, hh];
        if (kbps <= 0) kbps = 25000;
        st_attach(w & ~1, hh & ~1, codec, kbps, hz, note);
        return 1;
    }
    case DMS_DETACH:
        st_detach(h->flags & DMS_DETACH_PAUSE, "the hub detached its client");
        return 1;
    case DMS_PAD: {
        int p = dms_get8(&r); uint8_t pad[7]; dms_get(&r, pad, sizeof pad);
        uint64_t b = dms_get64(&r); int32_t ax[4]; float acc[3] = {0}, rot[3] = {0};
        for (int i = 0; i < 4; i++) { int16_t v = (int16_t)dms_get16(&r); ax[i] = v < -DM_STICK_MAX ? -DM_STICK_MAX : v; }
        int motion = h->flags & DMS_PAD_MOTION;
        if (motion) { dms_get(&r, acc, sizeof acc); dms_get(&r, rot, sizeof rot); }
        if (r.bad) { LOG("[RED] stream: a short PAD from the hub (%u bytes), ignored", n); return 1; }
        if (p >= DM_PLAYERS || !(atomic_load(&g_st_pads_mask) >> p & 1)) {
            if (atomic_fetch_add(&g_st_pad_msgs, 1) == 0) LOG("[RED] stream: a PAD for player %d, whom the hub's PADS did not connect: ignored", p + 1);
            return 1;
        }
        int finite = 1; for (int i = 0; i < 3; i++) finite &= isfinite(acc[i]) && isfinite(rot[i]);
        pthread_mutex_lock(&g_st_pad_mu);
        atomic_store(&g_st_pad_ns[p], now_ns());
        dm_net_pad_set(p, b & (0xffffull | DM_BTN_SHAKE), ax[0], ax[1], ax[2], ax[3]);
        if (motion && finite) dm_motion_set_net(p, acc, rot, h->sent_ns);
        pthread_mutex_unlock(&g_st_pad_mu);
        return 1;
    }
    case DMS_PADS: {
        uint32_t m = dms_get32(&r) & ((1u << DM_PLAYERS) - 1);
        if (r.bad) { LOG("[RED] stream: a short PADS from the hub (%u bytes), ignored", n); return 1; }
        pthread_mutex_lock(&g_st_pad_mu);
        uint32_t old = atomic_exchange(&g_st_pads_mask, m);
        for (int p = 0; p < DM_PLAYERS; p++) if ((m & ~old) >> p & 1) atomic_store(&g_st_pad_ns[p], now_ns());
        dm_net_pads(m);
        pthread_mutex_unlock(&g_st_pad_mu);
        if (old != m) LOG("[stream] the hub's controllers: players %#x", m);
        return 1;
    }
    case DMS_LTR_ACK: {
        int count = dms_get16(&r);
        NSMutableArray<NSNumber *> *tokens = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        for (int i = 0; i < count && !r.bad; i++) [tokens addObject:@((long long)dms_get64(&r))];
        if (r.bad) { LOG("[RED] stream: a short LTR_ACK from the hub (%u bytes), ignored", n); return 1; }
        dispatch_async(g_st_encq, ^{ if (g_st_vt) { [g_st_acks addObjectsFromArray:tokens]; g_st_acked = 1; } });
        return 1;
    }
    case DMS_REFRESH:
        st_request(ST_FORCE_REFRESH);
        return 1;
    case DMS_BITRATE: {
        int kbps = (int)dms_get32(&r);
        if (r.bad || kbps <= 0) { LOG("[RED] stream: a BITRATE of %d kbit/s from the hub, ignored", kbps); return 1; }
        dispatch_async(g_st_encq, ^{ if (g_st_vt) { g_st_kbps = kbps; st_prop(g_st_vt, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@((long long)kbps * 1000)); } });
        LOG("[stream] the hub set the bitrate to %d kbit/s", kbps);
        return 1;
    }
    default:
        return 1;
    }
}

static int st_read_all(int fd, void *p, size_t n) {
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return 0;
        p = (uint8_t *)p + r; n -= (size_t)r;
    }
    return 1;
}

static int st_write_all(int fd, const uint8_t *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { LOG("[RED] stream: the hub has read nothing for 5 s: closing its socket"); return 0; }
        if (w <= 0) return 0;
        p += w; n -= (size_t)w;
    }
    return 1;
}

static void *st_reader(void *arg) {
    int fd = (int)(intptr_t)arg;
    uint8_t *buf = NULL; size_t cap = 0;
    for (;;) {
        dms_header h;
        if (!st_read_all(fd, &h, sizeof h)) break;
        if (h.length > DMS_MAX_PAYLOAD) { LOG("[RED] stream: the hub sent a message of %u bytes (type %u), over the 8 MB limit: closing", h.length, h.type); break; }
        if (h.length > cap) { uint8_t *grown = realloc(buf, h.length); if (!grown) die("stream: cannot allocate %u bytes for a message from the hub", h.length); buf = grown; cap = h.length; }
        if (h.length && !st_read_all(fd, buf, h.length)) break;
        if (!st_hub_message(&h, buf, h.length)) break;
    }
    free(buf);
    shutdown(fd, SHUT_RDWR);
    pthread_mutex_lock(&g_st_qmu); g_st_link_broken = 1; pthread_cond_broadcast(&g_st_qcv); pthread_mutex_unlock(&g_st_qmu);
    return NULL;
}

static st_item *st_pop(void) {
    pthread_mutex_lock(&g_st_qmu);
    while (!g_st_qhead && !g_st_link_broken) pthread_cond_wait(&g_st_qcv, &g_st_qmu);
    st_item *it = g_st_link_broken ? NULL : g_st_qhead;
    if (it) {
        g_st_qhead = it->next; if (!g_st_qhead) g_st_qtail = NULL;
        if (it->kind == ST_VIDEO) g_st_qvideo--; else if (it->kind == ST_AUDIO) g_st_qaudio--;
    }
    pthread_mutex_unlock(&g_st_qmu);
    return it;
}

static void *st_link(void *unused) {
    (void)unused;
    pthread_setname_np("dm.stream.link");
    int last_err = -1;
    for (;;) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un addr = {.sun_family = AF_UNIX};
        memcpy(addr.sun_path, g_st_path, strlen(g_st_path) + 1);
        if (fd < 0 || connect(fd, (struct sockaddr *)&addr, sizeof addr)) {
            int e = errno;
            if (fd >= 0) close(fd);
            if (e != last_err) {
                if (e == ENOENT || e == ECONNREFUSED) LOG("[stream] no hub listening at %s (%s): trying once a second", g_st_path, strerror(e));
                else LOG("[RED] stream: cannot connect to the hub at %s (%s): trying once a second", g_st_path, strerror(e));
                last_err = e;
            }
            sleep(1);
            continue;
        }
        last_err = -1;
        int one = 1, sndbuf = st_env("DM_STREAM_SNDBUF", 4 << 20);
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof sndbuf)) LOG("[RED] stream: SO_SNDBUF %d refused (%s)", sndbuf, strerror(errno));
        struct timeval deadline = {5, 0};
        if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, sizeof deadline)) LOG("[RED] stream: SO_SNDTIMEO refused (%s)", strerror(errno));
        pthread_mutex_lock(&g_st_qmu); g_st_link_up = 1; g_st_link_broken = 0; g_st_until_refresh = 0; st_drop_queued(0); pthread_mutex_unlock(&g_st_qmu);
        atomic_store(&g_st_hub_hello, 0);
        LOG("[stream] connected to the hub at %s, %.2f s after the host started", g_st_path, (now_ns() - g_t0_ns) / 1e9);
        st_send_hello();
        pthread_t reader;
        if (pthread_create(&reader, NULL, st_reader, (void *)(intptr_t)fd)) die("stream: cannot start the socket reader thread");
        for (;;) {
            st_item *it = st_pop();
            if (!it) break;
            uint64_t t = now_ns();
            for (int k = 0; k < it->nheads; k++) memcpy(it->data + it->heads[k] + 8, &t, 8);
            int ok = st_write_all(fd, it->data, it->len);
            st_free_item(it);
            if (!ok) break;
        }
        shutdown(fd, SHUT_RDWR);
        pthread_join(reader, NULL);
        close(fd);
        pthread_mutex_lock(&g_st_qmu); g_st_link_up = 0; st_drop_queued(0); pthread_mutex_unlock(&g_st_qmu);
        st_detach(1, "the hub's socket closed while a client was attached");
        if (atomic_load(&g_st_refused)) { st_detach(0, "the hub was refused"); return NULL; }
        LOG("[stream] the hub's socket closed: connecting again once a second");
        sleep(1);
    }
}

int dm_stream_open(int width, int height) {
    const char *file = getenv("DM_STREAM_FILE"), *sock = getenv("DM_STREAM");
    int want_file = file && *file, want_sock = sock && *sock;
    if (!want_file && !want_sock) return 0;
    g_st_src_w = width; g_st_src_h = height;
    g_st_ltr = st_env("DM_STREAM_LTR", 1);
    g_st_acks = [NSMutableArray array];
    g_st_encq = dispatch_queue_create("dm.stream.encode", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    g_st_writeq = dispatch_queue_create("dm.stream.write", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    int on = 0;
    if (want_file) {
        g_st_fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        char tsv[1024]; snprintf(tsv, sizeof tsv, "%s.tsv", file);
        g_st_tsv = open(tsv, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (g_st_fd < 0 || g_st_tsv < 0) {
            LOG("[RED] stream: cannot create %s or %s (%s)", file, tsv, strerror(errno));
            if (g_st_fd >= 0) close(g_st_fd);
            if (g_st_tsv >= 0) close(g_st_tsv);
            g_st_fd = g_st_tsv = -1;
        } else {
            static const char header[] = "frame\tticket\tpresent_ns\tpass_ms\tgpu_ms\tqueue_ms\twait_ms\tencode_ms\ttotal_ms\tbytes\tsync\tltr_token\n";
            st_write(g_st_tsv, header, sizeof header - 1);
            LOG("[stream] writing the encoded frames to %s (a line per frame in %s)", file, tsv);
            on = 1;
        }
    }
    if (on && !want_sock) {
        int w = 1920, h = 1080;
        const char *size = getenv("DM_STREAM_SIZE");
        if (size && (sscanf(size, "%dx%d", &w, &h) != 2 || w < 64 || h < 64 || w > 4096 || h > 4096)) { LOG("[RED] stream: DM_STREAM_SIZE=%s is not WxH (64 to 4096), using 1920x1080", size); w = 1920; h = 1080; }
        const char *codec = getenv("DM_STREAM_CODEC");
        int hevc = codec && !strcmp(codec, "hevc"), kbps = st_env("DM_STREAM_KBPS", 25000);
        __block int started = 0;
        dispatch_sync(g_st_encq, ^{ started = st_start(w & ~1, h & ~1, hevc, kbps); g_st_attached = started; });
        on = started;
    }
    if (want_sock) {
        if (strlen(sock) > DMS_SUN_PATH_MAX) LOG("[RED] stream: DM_STREAM=%s is longer than %d bytes, the socket path limit: no stream", sock, DMS_SUN_PATH_MAX);
        else {
            memcpy(g_st_path, sock, strlen(sock) + 1);
            pthread_t t;
            if (pthread_create(&t, NULL, st_link, NULL)) LOG("[RED] stream: cannot start the socket thread");
            else {
                pthread_detach(t); on = 1;
                g_st_pad_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
                dispatch_source_set_timer(g_st_pad_timer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
                dispatch_source_set_event_handler(g_st_pad_timer, ^{ st_pads_stale(now_ns()); });
                dispatch_resume(g_st_pad_timer);
            }
        }
    }
    return on ? ST_SLOTS : 0;
}

int dm_stream_take(IOSurfaceRef *surface, uint32_t *gen, int *width, int *height) {
    int got = -1;
    pthread_mutex_lock(&g_st_mu);
    if (g_st_vt) {
        for (int i = 0; i < ST_SLOTS && got < 0; i++) { int idle = 0; if (atomic_compare_exchange_strong(&g_st_busy[i], &idle, 1)) got = i; }
        if (got < 0) atomic_fetch_add(&g_st_drops, 1);
        else { *surface = (IOSurfaceRef)CFRetain(CVPixelBufferGetIOSurface(g_st_px[got])); *gen = g_st_gen; *width = g_st_w; *height = g_st_h; }
    }
    pthread_mutex_unlock(&g_st_mu);
    return got;
}

void dm_stream_put(int i, uint32_t gen, uint64_t ticket, uint64_t capture_ns, double pass_s, int drawn) {
    if (!drawn) { atomic_store(&g_st_busy[i], 0); return; }
    uint64_t gpu_ns = now_ns();
    dispatch_async(g_st_encq, ^{
        if (!g_st_vt || gen != g_st_gen) { atomic_store(&g_st_busy[i], 0); return; }
        int force = atomic_exchange(&g_st_force, ST_FORCE_NONE);
        if (force == ST_FORCE_REFRESH && !(g_st_ltr && g_st_acked)) force = ST_FORCE_KEY;
        NSMutableDictionary *options = nil;
        if (force || g_st_acks.count) {
            options = [NSMutableDictionary dictionary];
            if (force == ST_FORCE_KEY) options[(__bridge id)kVTEncodeFrameOptionKey_ForceKeyFrame] = @YES;
            if (force == ST_FORCE_REFRESH) options[(__bridge id)kVTEncodeFrameOptionKey_ForceLTRRefresh] = @YES;
            if (g_st_acks.count) { options[(__bridge id)kVTEncodeFrameOptionKey_AcknowledgedLTRTokens] = [g_st_acks copy]; }
        }
        g_st_slot[i] = (st_frame){ticket, capture_ns, gpu_ns, now_ns(), pass_s * 1e3, gen, force};
        VTEncodeInfoFlags flags = 0;
        OSStatus s = VTCompressionSessionEncodeFrame(g_st_vt, g_st_px[i], CMTimeMake((int64_t)capture_ns, 1000000000), kCMTimeInvalid, (__bridge CFDictionaryRef)options, (void *)(intptr_t)i, &flags);
        if (!s) [g_st_acks removeAllObjects];
        else {
            atomic_fetch_add(&g_st_failed, 1); atomic_store(&g_st_busy[i], 0);
            if (force) st_request(force);
            static int once; if (!once++) LOG("[RED] stream: VTCompressionSessionEncodeFrame failed (%d)", (int)s);
            if (s == kVTInvalidSessionErr) st_restart();
        }
    });
}
