#include "../nvn/nvn_mtl.m"
#include "../../host/stream_mac.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static const uint8_t red[3] = {200, 40, 40}, blue[3] = {40, 60, 200};
static void paint(id<MTLTexture> t, const uint8_t rgb[3]) {
    size_t n = t.width * t.height; uint8_t *px = malloc(n * 4);
    for (size_t i = 0; i < n; i++) { px[i * 4] = rgb[0]; px[i * 4 + 1] = rgb[1]; px[i * 4 + 2] = rgb[2]; px[i * 4 + 3] = 255; }
    [t replaceRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0 withBytes:px bytesPerRow:t.width * 4];
    free(px);
}
static int idle(void) {
    for (int k = 0; k < 500; k++) { int any = 0; for (int i = 0; i < ST_SLOTS; i++) any |= atomic_load(&g_st_busy[i]); if (!any) return 1; usleep(10000); }
    return 0;
}
static void capture(id<MTLTexture> src, int n, uint64_t *ticket) {
    for (int k = 0; k < n; k++) { stream_capture(src, NULL, ++*ticket); usleep(16000); }
    CHECK("every frame leaves the ring", idle());
}
static CVPixelBufferRef g_decoded[64]; static int g_ndecoded;
static void decoded(void *session_ref, void *frame_ref, OSStatus status, VTDecodeInfoFlags flags, CVImageBufferRef img, CMTime pts, CMTime duration) {
    (void)session_ref; (void)frame_ref; (void)flags; (void)pts; (void)duration;
    CHECK("the frame decodes", !status && img);
    if (!status && img && g_ndecoded < 64) g_decoded[g_ndecoded++] = CVPixelBufferRetain(img);
}
static int near(CVPixelBufferRef px, const uint8_t rgb[3]) {
    CVPixelBufferLockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
    const uint8_t *p = (const uint8_t *)CVPixelBufferGetBaseAddress(px) + CVPixelBufferGetHeight(px) / 2 * CVPixelBufferGetBytesPerRow(px) + CVPixelBufferGetWidth(px) / 2 * 4;
    int ok = abs(p[2] - rgb[0]) <= 10 && abs(p[1] - rgb[1]) <= 10 && abs(p[0] - rgb[2]) <= 10;
    if (!ok) fprintf(stderr, "decoded %d,%d,%d, expected %d,%d,%d\n", p[2], p[1], p[0], rgb[0], rgb[1], rgb[2]);
    CVPixelBufferUnlockBaseAddress(px, kCVPixelBufferLock_ReadOnly);
    return ok;
}
static void decode(NSData *file, const size_t *sizes, int frames) {
    const uint8_t *base = file.bytes; size_t at = 0;
    CMFormatDescriptionRef fmt = NULL; VTDecompressionSessionRef ds = NULL;
    for (int f = 0; f < frames; f++) {
        const uint8_t *p = base + at, *end = p + sizes[f]; at += sizes[f];
        const uint8_t *nal[16]; size_t len[16]; int nn = 0;
        for (const uint8_t *q = p; q + 3 <= end && nn < 16; q++) if (!q[0] && !q[1] && q[2] == 1) { if (nn) len[nn - 1] = q - (q[-1] ? 0 : 1) - nal[nn - 1]; nal[nn++] = q + 3; q += 2; }
        if (nn) len[nn - 1] = end - nal[nn - 1];
        const uint8_t *ps[2] = {0}; size_t psn[2] = {0};
        NSMutableData *avcc = [[NSMutableData alloc] init];
        for (int k = 0; k < nn; k++) {
            int type = nal[k][0] & 0x1f;
            if (type == 7 || type == 8) { ps[type - 7] = nal[k]; psn[type - 7] = len[k]; continue; }
            uint8_t be[4] = {len[k] >> 24, len[k] >> 16, len[k] >> 8, len[k]}; [avcc appendBytes:be length:4]; [avcc appendBytes:nal[k] length:len[k]];
        }
        if (ps[0] && ps[1] && !fmt) {
            CHECK("the parameter sets make a format description", !CMVideoFormatDescriptionCreateFromH264ParameterSets(NULL, 2, ps, psn, 4, &fmt));
            NSDictionary *out = @{(__bridge id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
            VTDecompressionOutputCallbackRecord cb = {decoded, NULL};
            CHECK("a decoder takes the stream", !VTDecompressionSessionCreate(NULL, fmt, NULL, (__bridge CFDictionaryRef)out, &cb, &ds));
        }
        if (f == 0) CHECK("the first frame carries the parameter sets", fmt != NULL);
        if (!ds) return;
        CMBlockBufferRef bb = NULL; size_t n = avcc.length; void *copy = malloc(n); memcpy(copy, avcc.bytes, n);
        CMBlockBufferCreateWithMemoryBlock(NULL, copy, n, kCFAllocatorMalloc, NULL, 0, n, 0, &bb);
        CMSampleBufferRef sb = NULL; CMSampleBufferCreateReady(NULL, bb, fmt, 1, 0, NULL, 1, &n, &sb);
        CHECK("the decoder takes the frame", !VTDecompressionSessionDecodeFrame(ds, sb, 0, NULL, NULL));
        CFRelease(sb); CFRelease(bb);
    }
    VTDecompressionSessionWaitForAsynchronousFrames(ds);
    VTDecompressionSessionInvalidate(ds); CFRelease(ds); CFRelease(fmt);
}
int main(void) { @autoreleasepool {
    char path[1024]; snprintf(path, sizeof path, "%s/t_stream.h264", getenv("TMPDIR") ?: "/tmp");
    setenv("DM_STREAM_FILE", path, 1);
    mtl_init();
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1280 height:720 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> src = [g_dev newTextureWithDescriptor:d]; res_add(src); res_commit();
    uint64_t ticket = 0;
    paint(src, red); capture(src, 30, &ticket);
    CHECK("the stream is on", g_stream_on == 1);
    paint(src, blue); capture(src, 30, &ticket);
    VTCompressionSessionCompleteFrames(g_st_vt, kCMTimeInvalid);
    dispatch_sync(g_st_encq, ^{}); dispatch_sync(g_st_writeq, ^{});
    CHECK("every present is encoded", g_st_win.frames == 60);
    CHECK("no frame dropped or failed", !atomic_load(&g_st_drops) && !atomic_load(&g_st_encoder_drops) && !atomic_load(&g_st_failed));
    CHECK("the stream starts with a sync frame", g_st_win.sync >= 1);
    NSData *file = [NSData dataWithContentsOfFile:@(path)];
    NSString *tsv = [NSString stringWithContentsOfFile:[@(path) stringByAppendingString:@".tsv"] encoding:NSUTF8StringEncoding error:nil];
    NSArray<NSString *> *lines = [[tsv stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsSeparatedByString:@"\n"];
    CHECK("the per-frame table has a line per frame", lines.count == 61);
    size_t sizes[60] = {0}, sum = 0; int sync0 = 0;
    for (NSUInteger i = 1; i < lines.count && i <= 60; i++) {
        NSArray<NSString *> *c = [lines[i] componentsSeparatedByString:@"\t"];
        if (c.count != 12) { CHECK("a line has twelve columns", 0); break; }
        sizes[i - 1] = (size_t)c[9].longLongValue; sum += sizes[i - 1];
        if (i == 1) sync0 = c[10].intValue;
        CHECK("tickets follow the presents", c[1].longLongValue == (long long)i);
        CHECK("encode time is measured", c[7].doubleValue > 0 && c[7].doubleValue < 100);
        CHECK("the wait for the previous frame is never negative", c[6].doubleValue >= 0);
        CHECK("the capture pass GPU time is measured", c[3].doubleValue > 0 && c[3].doubleValue < 50);
    }
    CHECK("the first frame is a sync frame", sync0 == 1);
    CHECK("the table's sizes add up to the file", file && sum == file.length);
    if (file && sum == file.length) decode(file, sizes, 60);
    CHECK("every frame decodes", g_ndecoded == 60);
    if (g_ndecoded == 60) {
        CHECK("the decoded picture is the encoder's size", CVPixelBufferGetWidth(g_decoded[0]) == 1920 && CVPixelBufferGetHeight(g_decoded[0]) == 1080);
        CHECK("frame 0 shows the first picture", near(g_decoded[0], red));
        CHECK("frame 29 shows the first picture", near(g_decoded[29], red));
        CHECK("frame 30 shows the second picture", near(g_decoded[30], blue));
        CHECK("frame 59 shows the second picture", near(g_decoded[59], blue));
    }
    printf("t_stream: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
