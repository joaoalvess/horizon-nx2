#include "../nvn/nvn_mtl.m"
#include "../../host/stream_mac.m"
#include <poll.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

typedef struct { dms_header h; uint8_t *p; uint64_t recv_ns; } hub_msg;
typedef struct { int frames, configs, sync, refresh, gaps, gap_without_fresh, tokens, bad_avcc, other; uint64_t last_seq, max_hop_ns; long long first_token; int have_seq, first_is_config, first_frame_sync, seen; } st_tally;

static int listen_at(const char *path) {
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    memcpy(a.sun_path, path, strlen(path) + 1);
    if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 4)) return -1;
    return fd;
}

static int accept_within(int lfd, int ms) {
    if (lfd < 0) return -1;
    struct pollfd p = {lfd, POLLIN, 0};
    if (poll(&p, 1, ms) != 1) return -1;
    int fd = accept(lfd, NULL, NULL);
    int one = 1; if (fd >= 0) setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    return fd;
}

static void hub_send(int fd, uint16_t type, uint16_t flags, const void *p, uint32_t n) {
    dms_header h = {n, type, flags, now_ns()};
    write(fd, &h, sizeof h);
    if (n) write(fd, p, n);
}

static int read_full(int fd, void *p, size_t n) {
    while (n) { ssize_t r = read(fd, p, n); if (r <= 0) return 0; p = (uint8_t *)p + r; n -= (size_t)r; }
    return 1;
}

static int hub_recv(int fd, hub_msg *m, int ms) {
    struct pollfd p = {fd, POLLIN, 0};
    if (poll(&p, 1, ms) != 1) return 0;
    if (!read_full(fd, &m->h, sizeof m->h)) return -1;
    m->recv_ns = now_ns();
    free(m->p); m->p = malloc(m->h.length ? m->h.length : 1);
    if (m->h.length && !read_full(fd, m->p, m->h.length)) return -1;
    return 1;
}

static void tally_msg(st_tally *t, const hub_msg *m) {
    if (!t->seen++) t->first_is_config = m->h.type == DMS_VIDEO_CONFIG;
    if (m->h.type == DMS_VIDEO_CONFIG) { t->configs++; return; }
    if (m->h.type != DMS_VIDEO_FRAME) { t->other++; return; }
    dms_reader r = {m->p, m->p + m->h.length, 0};
    dms_get64(&r); uint64_t seq = dms_get64(&r); long long token = (long long)dms_get64(&r);
    size_t at = 24; while (at + 4 <= m->h.length) { uint32_t n = (uint32_t)m->p[at] << 24 | (uint32_t)m->p[at + 1] << 16 | (uint32_t)m->p[at + 2] << 8 | m->p[at + 3]; at += 4 + n; }
    if (at != m->h.length) t->bad_avcc++;
    int fresh = m->h.flags & (DMS_FRAME_SYNC | DMS_FRAME_REFRESH);
    if (!t->frames) t->first_frame_sync = !!(m->h.flags & DMS_FRAME_SYNC);
    if (t->have_seq && seq != t->last_seq + 1) { t->gaps++; if (!fresh) t->gap_without_fresh++; }
    t->have_seq = 1; t->last_seq = seq;
    t->frames++; t->sync += !!(m->h.flags & DMS_FRAME_SYNC); t->refresh += !!(m->h.flags & DMS_FRAME_REFRESH);
    if (token >= 0) { if (!t->tokens++) t->first_token = token; }
    uint64_t hop = m->recv_ns - m->h.sent_ns; if (hop > t->max_hop_ns) t->max_hop_ns = hop;
}

static int hub_drain(int fd, st_tally *t, int want_frames, int ms) {
    hub_msg m = {0}; uint64_t end = now_ns() + (uint64_t)ms * 1000000ull; int r = 1;
    while (now_ns() < end && (want_frames <= 0 || t->frames < want_frames)) {
        r = hub_recv(fd, &m, 20);
        if (r < 0) break;
        if (r) tally_msg(t, &m);
    }
    free(m.p);
    return r >= 0;
}

static void fill(id<MTLTexture> t, int gradient) {
    size_t n = t.width * t.height; uint32_t *px = malloc(n * 4);
    for (size_t i = 0; i < n; i++) {
        uint32_t x = (uint32_t)(i % t.width), y = (uint32_t)(i / t.width), g = gradient == 1 ? x * 255 / (uint32_t)t.width : y * 255 / (uint32_t)t.height;
        px[i] = gradient ? 0xff000000u | g << 16 | (255 - g) << 8 | (g ^ 0x55) : 0xff2828c8u;
    }
    [t replaceRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0 withBytes:px bytesPerRow:t.width * 4];
    free(px);
}

static void capture_frames(id<MTLTexture> src, int n, uint64_t *ticket) { for (int k = 0; k < n; k++) { stream_capture(src, NULL, ++*ticket); usleep(16000); } }

static void capture_reading(int fd, st_tally *t, id<MTLTexture> src, int n, uint64_t *ticket) { for (int k = 0; k < n; k++) { stream_capture(src, NULL, ++*ticket); hub_drain(fd, t, 0, 16); } }

static void hub_attach(int fd, int w, int h, uint32_t kbps) {
    uint8_t p[16], *w8 = p; dms_put16(&w8, 60); dms_put16(&w8, (uint16_t)w); dms_put16(&w8, (uint16_t)h); dms_put16(&w8, 0); dms_put32(&w8, DMS_AVC1); dms_put32(&w8, kbps);
    hub_send(fd, DMS_ATTACH, 0, p, (uint32_t)(w8 - p));
}

static int wait_until(int (*ready)(void), int ms) { for (int k = 0; k < ms / 5; k++) { if (ready()) return 1; usleep(5000); } return ready(); }
static int encoder_on(void) { pthread_mutex_lock(&g_st_mu); int on = g_st_vt != NULL; pthread_mutex_unlock(&g_st_mu); return on && atomic_load(&g_st_sending); }
static int encoder_off(void) { pthread_mutex_lock(&g_st_mu); int off = g_st_vt == NULL; pthread_mutex_unlock(&g_st_mu); return off; }

static int hub_expect_hello(int fd) {
    hub_msg m = {0};
    int r = hub_recv(fd, &m, 2000);
    CHECK("dmhost sends HELLO first", r == 1 && m.h.type == DMS_HELLO);
    if (r != 1 || m.h.type != DMS_HELLO) { free(m.p); return 0; }
    dms_reader rd = {m.p, m.p + m.h.length, 0};
    uint32_t version = dms_get32(&rd); uint64_t title = dms_get64(&rd); int w = dms_get16(&rd), h = dms_get16(&rd);
    uint32_t rate = dms_get32(&rd); int ch = dms_get8(&rd), ncodec = dms_get8(&rd); dms_get16(&rd);
    int avc = 0; for (int i = 0; i < ncodec; i++) avc |= dms_get32(&rd) == DMS_AVC1;
    CHECK("HELLO carries protocol version 1", version == DMS_VERSION);
    CHECK("HELLO carries the title ID", title == DM_GAME_PROGRAM_ID);
    CHECK("HELLO carries the game's window size", w == 1280 && h == 720);
    CHECK("HELLO carries the audio format", rate == 48000 && ch == 2);
    CHECK("HELLO lists H.264", avc);
    CHECK("HELLO ends with the host's build", !rd.bad && rd.end - rd.p > 7 && !memcmp(rd.p, "dmhost ", 7));
    free(m.p);
    return 1;
}

int main(void) { @autoreleasepool {
    char path[200]; snprintf(path, sizeof path, "%s/t_stream_sock.sock", getenv("TMPDIR") ?: "/tmp");
    if (strlen(path) > DMS_SUN_PATH_MAX) snprintf(path, sizeof path, "/tmp/t_stream_sock_%d.sock", getpid());
    setenv("DM_STREAM", path, 1); setenv("DM_STREAM_SNDBUF", "8192", 1); unsetenv("DM_STREAM_FILE");
    int lfd = listen_at(path);
    CHECK("the test hub listens", lfd >= 0);
    mtl_init();
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1280 height:720 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> flat = [g_dev newTextureWithDescriptor:d], busy[2] = {[g_dev newTextureWithDescriptor:d], [g_dev newTextureWithDescriptor:d]};
    res_add(flat); res_add(busy[0]); res_add(busy[1]); res_commit();
    fill(flat, 0); fill(busy[0], 1); fill(busy[1], 2);
    uint64_t ticket = 0;
    capture_frames(flat, 1, &ticket);
    CHECK("the stream is on with only DM_STREAM", g_stream_on == 1);
    CHECK("no encoder runs before a client attaches", encoder_off());
    int fd = accept_within(lfd, 3000);
    CHECK("dmhost connects to the hub", fd >= 0);
    if (fd < 0) { printf("t_stream_sock: %d checks, %d failed\n", checks, failed); return 1; }
    hub_expect_hello(fd);
    uint32_t v = DMS_VERSION; hub_send(fd, DMS_HELLO, 0, &v, 4);
    uint8_t junk[10] = {0}; hub_send(fd, 99, 0, junk, sizeof junk);
    hub_attach(fd, 1280, 720, 8000);
    CHECK("ATTACH starts the encoder, after a type dmhost does not know", wait_until(encoder_on, 2000));

    st_tally t = {0};
    capture_reading(fd, &t, flat, 30, &ticket);
    hub_drain(fd, &t, 30, 2000);
    CHECK("every present reaches the hub", t.frames == 30);
    CHECK("the parameter sets come first", t.first_is_config && t.configs >= 1);
    CHECK("the first frame is a sync frame", t.first_frame_sync);
    CHECK("frame numbers follow each other", t.gaps == 0);
    CHECK("frames are AVCC with 4-byte lengths", t.bad_avcc == 0);
    CHECK("the socket hop stays under 20 ms", t.max_hop_ns < 20000000ull);
    CHECK("frames carry LTR tokens", t.tokens > 0);

    if (t.tokens) { uint8_t p[10], *w = p; dms_put16(&w, 1); dms_put64(&w, (uint64_t)t.first_token); hub_send(fd, DMS_LTR_ACK, 0, p, (uint32_t)(w - p)); }
    usleep(50000);
    hub_send(fd, DMS_REFRESH, 0, NULL, 0);
    st_tally r = {0};
    capture_frames(flat, 6, &ticket);
    hub_drain(fd, &r, 6, 2000);
    CHECK("REFRESH after an acknowledgement brings an LTR refresh frame", r.refresh >= 1);
    uint32_t kbps = 20000; hub_send(fd, DMS_BITRATE, 0, &kbps, 4);

    uint64_t drops0 = atomic_load(&g_st_queue_drops);
    for (int k = 0; k < 30; k++) capture_frames(busy[k & 1], 2, &ticket);
    st_tally b = {0};
    hub_drain(fd, &b, 0, 1500);
    int stalled = b.frames;
    capture_reading(fd, &b, flat, 10, &ticket);
    hub_drain(fd, &b, stalled + 10, 2000);
    CHECK("a hub that stops reading makes dmhost drop frames", atomic_load(&g_st_queue_drops) > drops0);
    CHECK("frames are missing after the drops", b.gaps > 0);
    CHECK("the frame after a gap is a refresh or sync frame", b.gap_without_fresh == 0);
    CHECK("frames flow again after the hub reads again", b.frames == stalled + 10);
    CHECK("the encoder keeps every frame at the bitrate the hub set", atomic_load(&g_st_encoder_drops) == 0);

    uint64_t pauses0 = atomic_load(&g_st_pauses);
    hub_send(fd, DMS_DETACH, 0, NULL, 0);
    CHECK("DETACH stops the encoder", wait_until(encoder_off, 2000));
    st_tally dt = {0};
    hub_drain(fd, &dt, 0, 300);
    capture_frames(flat, 5, &ticket);
    st_tally none = {0};
    hub_drain(fd, &none, 0, 300);
    CHECK("no frame comes while detached", none.frames == 0);
    CHECK("DETACH without its pause flag does not pause", atomic_load(&g_st_pauses) == pauses0);

    hub_attach(fd, 1280, 720, 8000);
    CHECK("ATTACH starts the encoder again", wait_until(encoder_on, 2000));
    st_tally a2 = {0};
    capture_frames(flat, 5, &ticket);
    hub_drain(fd, &a2, 5, 2000);
    CHECK("a new attach starts with parameter sets and a sync frame", a2.first_is_config && a2.first_frame_sync && a2.frames == 5);

    close(fd);
    capture_frames(flat, 5, &ticket);
    CHECK("a hub that dies while attached stops the encoder", wait_until(encoder_off, 2000));
    CHECK("a hub that dies while attached asks for a pause", atomic_load(&g_st_pauses) == pauses0 + 1);
    fd = accept_within(lfd, 3000);
    CHECK("dmhost connects again after the hub died", fd >= 0);
    if (fd >= 0) {
        hub_expect_hello(fd);
        dms_header big = {DMS_MAX_PAYLOAD + 1, DMS_PAD, 0, now_ns()};
        write(fd, &big, sizeof big);
        hub_msg m = {0};
        int eof = 0; for (int k = 0; k < 50 && !eof; k++) { int rr = hub_recv(fd, &m, 20); eof = rr < 0; }
        free(m.p);
        CHECK("a message over 8 MB closes the socket", eof);
        close(fd);
        fd = accept_within(lfd, 3000);
        CHECK("dmhost connects again after closing on a bad message", fd >= 0);
    }
    if (fd >= 0) {
        hub_expect_hello(fd);
        uint32_t v2 = 2; hub_send(fd, DMS_HELLO, 0, &v2, 4);
        hub_msg m = {0};
        int eof = 0; for (int k = 0; k < 50 && !eof; k++) { int rr = hub_recv(fd, &m, 20); eof = rr < 0; }
        free(m.p);
        CHECK("a hub of another protocol version is refused", eof);
        close(fd);
        CHECK("dmhost does not connect again to a hub it refused", accept_within(lfd, 2500) < 0);
    }
    close(lfd); unlink(path);
    printf("t_stream_sock: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
