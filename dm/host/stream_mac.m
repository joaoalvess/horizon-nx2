#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CoreVideo.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <unistd.h>
#include "dm.h"

#define ST_SLOTS 4
#define ST_WINDOW 600

typedef struct { uint64_t ticket, capture_ns, gpu_ns, submit_ns; double pass_ms; } st_frame;

static VTCompressionSessionRef g_st_vt;
static CVPixelBufferRef g_st_px[ST_SLOTS];
static _Atomic int g_st_busy[ST_SLOTS];
static st_frame g_st_slot[ST_SLOTS];
static dispatch_queue_t g_st_encq, g_st_writeq;
static int g_st_fd = -1, g_st_tsv = -1, g_st_hevc, g_st_nal = 4;
static CMFormatDescriptionRef g_st_fmt;
static _Atomic uint64_t g_st_drops, g_st_failed, g_st_encoder_drops, g_st_last_done;
static struct { double enc[ST_WINDOW], total[ST_WINDOW], pass[ST_WINDOW]; int n; uint64_t frames, bytes, sync, ltr, waited, first_ns, last_ns; } g_st_win;
static const uint8_t g_st_start[4] = {0, 0, 0, 1};

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

static int st_param_sets(CMFormatDescriptionRef fd, NSMutableData *out) {
    size_t count = 0; int hl = 4;
    OSStatus s = g_st_hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, 0, NULL, NULL, &count, &hl)
                        : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, 0, NULL, NULL, &count, &hl);
    if (s) return 0;
    for (size_t i = 0; i < count; i++) {
        const uint8_t *p = NULL; size_t n = 0;
        s = g_st_hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, i, &p, &n, NULL, NULL)
                   : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, i, &p, &n, NULL, NULL);
        if (s) return 0;
        [out appendBytes:g_st_start length:4]; [out appendBytes:p length:n];
    }
    g_st_nal = hl;
    return 1;
}

static void st_window_log(void) {
    st_sort(g_st_win.enc, g_st_win.n); st_sort(g_st_win.total, g_st_win.n); st_sort(g_st_win.pass, g_st_win.n);
    double secs = (g_st_win.last_ns - g_st_win.first_ns) / 1e9;
    LOG("[stream] frames %llu: encode p50 %.2f ms / p95 %.2f / max %.2f; present to encoded p50 %.2f ms / p95 %.2f / max %.2f; capture pass GPU p50 %.3f ms / p95 %.3f; %.1f Mbit/s; sync frames %llu, LTR frames %llu; "
        "dropped: ring full %llu, by the encoder %llu; failed %llu; waited for the previous frame %llu",
        (unsigned long long)g_st_win.frames, g_st_win.enc[g_st_win.n / 2], g_st_win.enc[g_st_win.n * 95 / 100], g_st_win.enc[g_st_win.n - 1],
        g_st_win.total[g_st_win.n / 2], g_st_win.total[g_st_win.n * 95 / 100], g_st_win.total[g_st_win.n - 1], g_st_win.pass[g_st_win.n / 2], g_st_win.pass[g_st_win.n * 95 / 100], secs > 0 ? g_st_win.bytes * 8 / secs / 1e6 : 0,
        (unsigned long long)g_st_win.sync, (unsigned long long)g_st_win.ltr, (unsigned long long)atomic_load(&g_st_drops),
        (unsigned long long)atomic_load(&g_st_encoder_drops), (unsigned long long)atomic_load(&g_st_failed), (unsigned long long)g_st_win.waited);
    g_st_win.n = 0; g_st_win.bytes = 0; g_st_win.waited = 0; g_st_win.first_ns = 0;
}

static void st_frame_out(CMSampleBufferRef sb, st_frame f, uint64_t start_ns, uint64_t done_ns) {
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    CFDictionaryRef a = att && CFArrayGetCount(att) ? CFArrayGetValueAtIndex(att, 0) : NULL;
    int sync = !(a && CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync) == kCFBooleanTrue);
    CFNumberRef tok = a ? CFDictionaryGetValue(a, kVTSampleAttachmentKey_RequireLTRAcknowledgementToken) : NULL;
    long long token = -1; if (tok) CFNumberGetValue(tok, kCFNumberLongLongType, &token);
    NSMutableData *out = [[NSMutableData alloc] init];
    CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
    if (fd && (sync || !g_st_fmt || !CFEqual(fd, g_st_fmt))) {
        if (!st_param_sets(fd, out)) { static int once; if (!once++) LOG("[RED] stream: no parameter sets in the encoder's format description"); }
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
        o += n;
    }
    free(buf);
    st_write(g_st_fd, out.bytes, out.length);
    double gpu = (f.gpu_ns - f.capture_ns) / 1e6, queue = (f.submit_ns - f.gpu_ns) / 1e6, wait = (start_ns - f.submit_ns) / 1e6, enc = (done_ns - start_ns) / 1e6, total = (done_ns - f.capture_ns) / 1e6;
    char line[256];
    int n = snprintf(line, sizeof line, "%llu\t%llu\t%llu\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%lu\t%d\t%lld\n", (unsigned long long)g_st_win.frames, (unsigned long long)f.ticket,
                     (unsigned long long)f.capture_ns, f.pass_ms, gpu, queue, wait, enc, total, (unsigned long)out.length, sync, token);
    st_write(g_st_tsv, line, (size_t)n);
    g_st_win.frames++; g_st_win.sync += sync; g_st_win.ltr += token >= 0; g_st_win.bytes += out.length; g_st_win.waited += start_ns > f.submit_ns;
    if (!g_st_win.first_ns) g_st_win.first_ns = f.capture_ns;
    g_st_win.last_ns = f.capture_ns;
    g_st_win.enc[g_st_win.n] = enc; g_st_win.total[g_st_win.n] = total; g_st_win.pass[g_st_win.n] = f.pass_ms;
    if (++g_st_win.n == ST_WINDOW) st_window_log();
}

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
        return;
    }
    CFRetain(sb);
    dispatch_async(g_st_writeq, ^{ st_frame_out(sb, f, start, done); CFRelease(sb); });
}

static void st_prop(CFStringRef key, CFTypeRef value) {
    OSStatus s = VTSessionSetProperty(g_st_vt, key, value);
    if (s) LOG("[RED] stream: the encoder refused %s (%d)", CFStringGetCStringPtr(key, kCFStringEncodingUTF8) ?: "a property", (int)s);
}

static int st_env(const char *name, int fallback) { const char *e = getenv(name); return e && *e ? atoi(e) : fallback; }

int dm_stream_open(int *width, int *height) {
    const char *path = getenv("DM_STREAM_FILE");
    if (!path || !*path) return 0;
    int w = 1920, h = 1080;
    const char *size = getenv("DM_STREAM_SIZE");
    if (size && (sscanf(size, "%dx%d", &w, &h) != 2 || w < 64 || h < 64 || w > 4096 || h > 4096)) { LOG("[RED] stream: DM_STREAM_SIZE=%s is not WxH (64 to 4096), using 1920x1080", size); w = 1920; h = 1080; }
    w &= ~1; h &= ~1;
    const char *codec = getenv("DM_STREAM_CODEC");
    g_st_hevc = codec && !strcmp(codec, "hevc");
    int kbps = st_env("DM_STREAM_KBPS", 25000), ltr = st_env("DM_STREAM_LTR", 1);
    g_st_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    char tsv[1024]; snprintf(tsv, sizeof tsv, "%s.tsv", path);
    g_st_tsv = open(tsv, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (g_st_fd < 0 || g_st_tsv < 0) { LOG("[RED] stream: cannot create %s or %s (%s)", path, tsv, strerror(errno)); return 0; }
    static const char header[] = "frame\tticket\tpresent_ns\tpass_ms\tgpu_ms\tqueue_ms\twait_ms\tencode_ms\ttotal_ms\tbytes\tsync\tltr_token\n";
    st_write(g_st_tsv, header, sizeof header - 1);
    NSDictionary *spec = @{(__bridge id)kVTVideoEncoderSpecification_EnableLowLatencyRateControl: @YES,
                           (__bridge id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES};
    NSDictionary *source = @{(__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA), (__bridge id)kCVPixelBufferWidthKey: @(w),
                             (__bridge id)kCVPixelBufferHeightKey: @(h), (__bridge id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                             (__bridge id)kCVPixelBufferMetalCompatibilityKey: @YES};
    OSStatus s = VTCompressionSessionCreate(NULL, w, h, g_st_hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, (__bridge CFDictionaryRef)spec,
                                            (__bridge CFDictionaryRef)source, NULL, st_encoded, NULL, &g_st_vt);
    if (s) { LOG("[RED] stream: no low-latency hardware %s encoder (%d)", g_st_hevc ? "HEVC" : "H.264", (int)s); g_st_vt = NULL; return 0; }
    st_prop(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    st_prop(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    st_prop(kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFNumberRef)@60);
    st_prop(kVTCompressionPropertyKey_AverageBitRate, (__bridge CFNumberRef)@(kbps * 1000));
    st_prop(kVTCompressionPropertyKey_ProfileLevel, g_st_hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_ConstrainedHigh_AutoLevel);
    st_prop(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    st_prop(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    st_prop(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    if (ltr) st_prop(kVTCompressionPropertyKey_EnableLTR, kCFBooleanTrue);
    VTCompressionSessionPrepareToEncodeFrames(g_st_vt);
    for (int i = 0; i < ST_SLOTS; i++) {
        if (CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)source, &g_st_px[i]) || !CVPixelBufferGetIOSurface(g_st_px[i])) {
            LOG("[RED] stream: cannot create the IOSurface pixel buffers (%dx%d)", w, h); return 0;
        }
        CVBufferSetAttachment(g_st_px[i], kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(g_st_px[i], kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(g_st_px[i], kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    }
    g_st_encq = dispatch_queue_create("dm.stream.encode", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    g_st_writeq = dispatch_queue_create("dm.stream.write", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    LOG("[stream] %s %dx%d, %d kbit/s, low-latency rate control, LTR %s, %d frames in flight: %s (a line per frame in %s)",
        g_st_hevc ? "HEVC" : "H.264", w, h, kbps, ltr ? "on" : "off", ST_SLOTS, path, tsv);
    *width = w; *height = h;
    return ST_SLOTS;
}

IOSurfaceRef dm_stream_surface(int i) { return CVPixelBufferGetIOSurface(g_st_px[i]); }

int dm_stream_take(void) {
    for (int i = 0; i < ST_SLOTS; i++) { int idle = 0; if (atomic_compare_exchange_strong(&g_st_busy[i], &idle, 1)) return i; }
    atomic_fetch_add(&g_st_drops, 1);
    return -1;
}

void dm_stream_put(int i, uint64_t ticket, uint64_t capture_ns, double pass_s, int drawn) {
    if (!drawn) { atomic_store(&g_st_busy[i], 0); return; }
    uint64_t gpu_ns = now_ns();
    dispatch_async(g_st_encq, ^{
        g_st_slot[i] = (st_frame){ticket, capture_ns, gpu_ns, now_ns(), pass_s * 1e3};
        VTEncodeInfoFlags flags = 0;
        OSStatus s = VTCompressionSessionEncodeFrame(g_st_vt, g_st_px[i], CMTimeMake((int64_t)capture_ns, 1000000000), kCMTimeInvalid, NULL, (void *)(intptr_t)i, &flags);
        if (s) {
            atomic_fetch_add(&g_st_failed, 1); atomic_store(&g_st_busy[i], 0);
            static int once; if (!once++) LOG("[RED] stream: VTCompressionSessionEncodeFrame failed (%d)", (int)s);
        }
    });
}
