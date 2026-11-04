#include "../hle_audio.c"
#include <time.h>
__thread _Atomic int dm_host_work;
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static struct { const void *k; void *v; } om[8];
void *objmap_get(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) return om[i].v; return NULL; }
void objmap_put(const void *k, void *v) { for (int i = 0; i < 8; i++) if (!om[i].k) { om[i].k = k; om[i].v = v; return; } }
void *objmap_del(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) { om[i].k = 0; return om[i].v; } return NULL; }
void hle_signal_system_event(void *g) { (void)g; }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }
module_t *module_of(const void *p) { (void)p; return NULL; }
int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }
void dm_host_helper_qos(qos_class_t q) { (void)q; }

static int checks, failures;
#define CHECK(v, why) do { checks++; if (!(v)) { failures++; printf("FAIL: %s\n", why); } } while (0)

enum { BLOCKS = 400 };
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static int g_blocks, g_bad_size, g_mixed, g_clipped, g_silent;
static uint64_t g_first_t, g_last_t, g_max_step;
static void sink(uint64_t t, const int16_t *pcm, int frames) {
    pthread_mutex_lock(&g_mu);
    if (frames != STREAM_FRAMES) g_bad_size++;
    if (g_blocks) { uint64_t step = t - g_last_t; if (step > g_max_step) g_max_step = step; } else g_first_t = t;
    g_last_t = t; g_blocks++;
    for (int i = 0; i < frames; i++) {
        int l = pcm[2 * i], r = pcm[2 * i + 1];
        g_mixed += l == 1100 && r == -800;
        g_clipped += l == 32767 && r == 32767;
        g_silent += !l && !r;
    }
    pthread_mutex_unlock(&g_mu);
}
static int blocks(void) { pthread_mutex_lock(&g_mu); int n = g_blocks; pthread_mutex_unlock(&g_mu); return n; }

static int16_t stereo[4800 * 2], surround[4800 * 6], loud2[4800 * 2], loud6[4800 * 6];
static gbuf bufs[2][64];
static void *open_out(int ch) {
    void *key = calloc(1, 64); uint8_t param[8] = {0}; *(uint16_t *)(param + 4) = (uint16_t)ch;
    if (au_open_at(key, NULL, "test", param, NULL)) return NULL;
    au_start_at(key, NULL);
    return key;
}
static int append(void *out, gbuf *b, int16_t *pcm, uint64_t bytes) { b->ptr = pcm; b->cap = bytes; b->size = bytes; return (int)h_au_Append(out, b); }
static int released(void *out) { int n = 0; while (h_au_Released(out)) n++; return n; }

int main(void) {
    for (int i = 0; i < 4800; i++) {
        stereo[2 * i] = 1000; stereo[2 * i + 1] = -1000;
        surround[6 * i] = 100; surround[6 * i + 1] = 200;
        loud2[2 * i] = loud2[2 * i + 1] = 30000;
        loud6[6 * i] = loud6[6 * i + 1] = 30000;
    }
    void *a = open_out(2), *b = open_out(6);
    CHECK(a && b, "two outputs open");
    CHECK(ao(a)->backend == BK_NULL && ao(b)->backend == BK_NULL, "the outputs start on the silent sink");

    dm_audio_stream(sink);
    CHECK(ao(a)->backend == BK_STREAM && ao(b)->backend == BK_STREAM, "the stream takes every started output");
    CHECK(append(a, &bufs[0][0], stereo, sizeof stereo) && append(b, &bufs[1][0], surround, sizeof surround), "the outputs take a 100 ms buffer each");
    usleep(150000);
    CHECK(released(a) == 1 && released(b) == 1, "the stream consumes both buffers in real time");
    CHECK(append(a, &bufs[0][1], loud2, sizeof loud2) && append(b, &bufs[1][1], loud6, sizeof loud6), "the outputs take a loud buffer each");
    usleep(150000);
    released(a); released(b);

    void *c = open_out(2);
    CHECK(c && ao(c)->backend == BK_STREAM, "an output started while streaming goes to the stream");
    au_stop_at(c, NULL);
    CHECK(ao(c)->backend == BK_NONE, "an output stopped while streaming leaves the stream");
    au_close(c, NULL);

    int n = blocks();
    pthread_mutex_lock(&g_mu);
    CHECK(n >= 50 && n <= 80, "a block every 5 ms");
    CHECK(!g_bad_size, "every block has 240 frames");
    CHECK(g_max_step >= 4000000 && g_max_step < 30000000, "block times step by about 5 ms");
    CHECK(g_mixed >= 4000, "both outputs are summed: stereo plus the 5.1 downmix");
    CHECK(g_clipped >= 4000, "the sum saturates");
    pthread_mutex_unlock(&g_mu);

    dm_audio_stream(NULL);
    CHECK(ao(a)->backend == BK_NULL && ao(b)->backend == BK_NULL, "after the stream the outputs go back to the silent sink");
    int after = blocks();
    CHECK(append(a, &bufs[0][2], stereo, sizeof stereo), "the output takes a buffer after the stream");
    usleep(150000);
    CHECK(blocks() == after, "no block reaches the stream after it stopped");
    CHECK(released(a) == 1, "the silent sink consumes again");

    dm_audio_stream(sink);
    dm_audio_stream(sink);
    CHECK(ao(a)->backend == BK_STREAM, "a second start of the stream changes nothing");
    dm_audio_stream(NULL);
    dm_audio_stream(NULL);
    CHECK(ao(a)->backend == BK_NULL, "a second stop of the stream changes nothing");

    au_close(a, NULL); au_close(b, NULL);
    printf("t_audio_stream: %d checks, %d failures\n", checks, failures);
    return failures != 0;
}
