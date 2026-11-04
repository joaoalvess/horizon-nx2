#include "../dm.h"
#include <assert.h>
#include <dlfcn.h>
#include <errno.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/event.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <mach/mach.h>
#include <pthread/qos.h>
static int slow_signal(pthread_cond_t *cv);
static void watched_free(void *p);
#define pthread_cond_signal slow_signal
#define free watched_free
#include "../hle_thread.c"
#undef pthread_cond_signal
#undef free

static uint32_t main_handle;
static void fail(const char *m) { write(2, m, strlen(m)); _exit(1); }
static void on_alarm(int sig) { (void)sig; fail("[RED] t_cvsignal timed out\n"); }
static void until(_Atomic int *flag, const char *what) {
    for (int i = 0; !atomic_load(flag); i++) { if (i == 2000) fail(what); usleep(1000); }
}
static uint64_t svc(int num, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    uint64_t r[32] = {a0, a1, a2, a3}; svc_thread(num, r);
    return r[0];
}

static _Atomic(pthread_cond_t *) slow_cv;
static _Atomic int slow_gate, slow_done;
static _Atomic(void *) watch;
static _Atomic int watch_freed;
static _Atomic int64_t w_res;
static int slow_signal(pthread_cond_t *cv) {
    if (cv != atomic_load(&slow_cv)) return pthread_cond_signal(cv);
    until(&slow_gate, "[RED] a delayed signal never saw its thread leave the wait: was it issued with G held?\n");
    usleep(20000);
    int r = pthread_cond_signal(cv);
    atomic_store(&slow_cv, NULL); atomic_store(&slow_done, 1);
    return r;
}
static void watched_free(void *p) {
    if (p && p == atomic_load(&watch)) {
        if (atomic_load(&w_res) == 0 && !atomic_load(&slow_done)) fail("[RED] a thread was freed while a signal to it was still in flight\n");
        atomic_store(&watch_freed, 1);
    }
    free(p);
}

typedef struct gthr {
    thr_t t; pthread_t pt;
    void (*body)(struct gthr *); uint64_t a[3];
    _Atomic int64_t res; _Atomic int done, go;
} gthr;
static void *gthr_main(void *p) {
    gthr *g = p;
    pthread_setspecific(g_keythr, &g->t);
    g->body(g);
    thread_exit(&g->t);
    return NULL;
}
static void gthr_start(gthr *g, void (*body)(gthr *), uint64_t a0, uint64_t a1, uint64_t a2, int kind) {
    memset(&g->t, 0, sizeof g->t);
    pthread_cond_init(&g->t.cv, NULL); pthread_cond_init(&g->t.pcv, NULL);
    g->t.started = 1; g->t.prio = 50; g->t.core = 0; g->t.mask = 7;
    pthread_mutex_lock(&G); g->t.handle = h_new(O_THREAD, &g->t); g->t.all = g_all; g_all = &g->t; pthread_mutex_unlock(&G);
    g->body = body; g->a[0] = a0; g->a[1] = a1; g->a[2] = a2; g->res = -1; g->done = 0; g->go = 0;
    assert(!pthread_create(&g->pt, NULL, gthr_main, g));
    for (;;) {
        pthread_mutex_lock(&G); int k = g->t.wkind; pthread_mutex_unlock(&G);
        if (k == kind) return;
        usleep(100);
    }
}
static void gthr_join(gthr *g) {
    assert(!pthread_join(g->pt, NULL));
    pthread_mutex_lock(&G);
    for (thr_t **p = &g_all; *p; p = &(*p)->all) if (*p == &g->t) { *p = g->t.all; break; }
    g_h[g->t.handle - 0x1000].type = O_FREE; g_h[g->t.handle - 0x1000].obj = NULL;
    pthread_mutex_unlock(&G);
    pthread_cond_destroy(&g->t.cv); pthread_cond_destroy(&g->t.pcv);
}
static void body_lock_wait(gthr *g) {
    g->res = (int64_t)svc(0x1A, g->a[0], g->a[1], g->t.handle, 0);
    g->done = 1;
    while (!atomic_load(&g->go)) usleep(100);
    svc(0x1B, g->a[1], 0, 0, 0);
}
static void body_cond_wait(gthr *g) {
    g->res = (int64_t)svc(0x1C, g->a[0], g->a[1], g->t.handle, (uint64_t)-1);
    if (!g->res) svc(0x1B, g->a[0], 0, 0, 0);
    g->done = 1;
}
static void body_address_wait(gthr *g) {
    g->res = (int64_t)svc(0x34, g->a[0], 2, g->a[2], (uint64_t)-1);
    g->done = 1;
}
static uint32_t sync_handle;
static void body_sync_wait(gthr *g) {
    uint64_t r[32] = {0, (uint64_t)&sync_handle, 1, (uint64_t)-1}; svc_thread(0x18, r);
    g->res = (int64_t)r[0];
    g->done = 1;
}

static void wait_after_handoff(void) {
    static _Atomic uint32_t lock, key;
    static gthr a, b;
    atomic_store(&lock, main_handle | WAITERS_BIT); atomic_store(&key, 0);
    gthr_start(&b, body_lock_wait, main_handle, (uint64_t)&lock, 0, 1);
    gthr_start(&a, body_cond_wait, (uint64_t)&lock, (uint64_t)&key, 0, 2);
    until(&b.done, "[RED] a lock handed over right before the handing thread's own wait was never signalled\n");
    assert(b.res == 0 && atomic_load(&lock) == b.t.handle && atomic_load(&key) == 1);
    assert(svc(0x1D, (uint64_t)&key, 1, 0, 0) == 0);
    pthread_mutex_lock(&G); assert(a.t.wkind == 1 && atomic_load(&lock) == (b.t.handle | WAITERS_BIT) && atomic_load(&key) == 0); pthread_mutex_unlock(&G);
    atomic_store(&b.go, 1);
    until(&a.done, "[RED] the condition waiter turned lock waiter was never signalled\n");
    assert(a.res == 0 && atomic_load(&lock) == 0);
    gthr_join(&b); gthr_join(&a);
    assert(g_cv_ndefer == 0);
    puts("PASS: a lock handed to its waiter right before the handing thread waits on G reaches the waiter");
}

static void more_wakes_than_deferred(void) {
    enum { N = CV_DEFER + 4 };
    static _Atomic uint32_t word;
    static gthr w[N];
    atomic_store(&word, 7);
    for (int i = 0; i < N; i++) gthr_start(&w[i], body_address_wait, (uint64_t)&word, 0, 7, 3);
    assert(svc(0x35, (uint64_t)&word, 0, 0, (uint64_t)-1) == 0);
    assert(g_cv_ndefer == 0);
    for (int i = 0; i < N; i++) { until(&w[i].done, "[RED] a wake beyond the deferred list's capacity was lost\n"); assert(w[i].res == 0); gthr_join(&w[i]); }
    puts("PASS: one SVC that wakes more threads than the deferred list holds signals every one");
}

static uint8_t bound_event;
static uint64_t bound_id;
static _Atomic int host_how;
static void *host_signaller(void *p) {
    (void)p;
    assert(!pthread_getspecific(g_keythr));
    int k = atomic_load(&host_how);
    if (k == 0) hle_signal_system_event(&bound_event);
    else if (k == 1) assert(hle_signal_bound_system_event(&bound_event));
    else assert(hle_signal_system_event_binding(bound_id));
    return NULL;
}
static void host_thread_signals(void) {
    static const char *lost[] = {"[RED] hle_signal_system_event from a host thread never reached the waiter\n",
                                 "[RED] hle_signal_bound_system_event from a host thread never reached the waiter\n",
                                 "[RED] hle_signal_system_event_binding from a host thread never reached the waiter\n"};
    uint64_t r[32] = {0}; svc_thread(0x45, r); assert(r[0] == 0);
    uint32_t wh = (uint32_t)r[1]; sync_handle = (uint32_t)r[2];
    pthread_mutex_lock(&g_se_lock); g_se[g_nse].ev = &bound_event; g_se[g_nse].wh = wh; bound_id = g_se[g_nse++].id = g_next_se_id++; pthread_mutex_unlock(&g_se_lock);
    assert(hle_system_event_binding(&bound_event) == bound_id);
    for (int k = 0; k < 3; k++) {
        static gthr s;
        gthr_start(&s, body_sync_wait, 0, 0, 0, 4);
        atomic_store(&host_how, k);
        pthread_t h; assert(!pthread_create(&h, NULL, host_signaller, NULL)); assert(!pthread_join(h, NULL));
        until(&s.done, lost[k]);
        assert(s.res == 0);
        gthr_join(&s);
        assert(svc(0x12, wh, 0, 0, 0) == 0);
    }
    assert(svc(0x16, wh, 0, 0, 0) == 0 && svc(0x16, sync_handle, 0, 0, 0) == 0);
    assert(!hle_system_event_binding(&bound_event));
    puts("PASS: event signals from a host thread reach their waiter through each entry point");
}

static _Atomic uint32_t w_word;
static _Atomic int w_returned, by_closer;
static thr_t *w_thr;
static uint32_t w_handle;
static void w_entry(uint64_t arg) {
    (void)arg;
    atomic_store(&w_res, (int64_t)svc(0x34, (uint64_t)&w_word, 2, 0, 50000000));
    atomic_store(&w_returned, 1);
    if (!atomic_load(&by_closer)) atomic_store(&slow_gate, 1);
}
void dm_thread_enter(uint64_t entry, uint64_t arg, uint64_t sp) {
    (void)sp;
    ((void (*)(uint64_t))entry)(arg);
    svc(0x0A, 0, 0, 0, 0);
    abort();
}
static void *closer(void *p) {
    (void)p;
    while (!atomic_load(&w_returned)) usleep(100);
    for (;;) {
        pthread_mutex_lock(&G); int ex = w_thr->exited; pthread_mutex_unlock(&G);
        if (ex) break;
        usleep(100);
    }
    atomic_store(&slow_gate, 1);
    assert(svc(0x16, w_handle, 0, 0, 0) == 0);
    return NULL;
}
static int freed_after_signal(int close_after_exit) {
    atomic_store(&w_word, 0); atomic_store(&w_res, -1); atomic_store(&w_returned, 0); atomic_store(&by_closer, close_after_exit);
    atomic_store(&slow_gate, 0); atomic_store(&slow_done, 0); atomic_store(&watch_freed, 0);
    uint64_t r[32] = {0, (uint64_t)w_entry, 0, 0, 50, 0}; svc_thread(0x08, r); assert(r[0] == 0);
    w_handle = (uint32_t)r[1];
    pthread_mutex_lock(&G); w_thr = h_peek(w_handle, O_THREAD); pthread_mutex_unlock(&G);
    assert(w_thr);
    atomic_store(&watch, w_thr);
    assert(svc(0x09, w_handle, 0, 0, 0) == 0);
    assert(g_cv_ndefer == 0);
    for (;;) {
        pthread_mutex_lock(&G); int k = w_thr->wkind; pthread_mutex_unlock(&G);
        if (k == 3) break;
        usleep(100);
    }
    pthread_t c;
    if (close_after_exit) assert(!pthread_create(&c, NULL, closer, NULL));
    else assert(svc(0x16, w_handle, 0, 0, 0) == 0);
    atomic_store(&slow_cv, &w_thr->cv);
    assert(svc(0x35, (uint64_t)&w_word, 0, 0, 1) == 0);
    assert(g_cv_ndefer == 0);
    if (close_after_exit) assert(!pthread_join(c, NULL));
    until(&watch_freed, "[RED] the woken thread was never freed\n");
    atomic_store(&slow_cv, NULL); atomic_store(&watch, NULL);
    return atomic_load(&w_res) == 0 && atomic_load(&slow_done);
}
static void freed_only_after_its_signal(void) {
    for (int close_after_exit = 0; close_after_exit < 2; close_after_exit++) {
        int ok = 0;
        for (int attempt = 0; attempt < 5 && !ok; attempt++) ok = freed_after_signal(close_after_exit);
        if (!ok) fail("[RED] the thread was never woken before its timeout\n");
    }
    puts("PASS: a woken thread that leaves its wait and exits is freed only after the signal to it, at its exit and at CloseHandle");
}

int main(void) {
    signal(SIGALRM, on_alarm); alarm(60);
    setenv("DM_PREEMPT", "0", 1);
    main_handle = svc_thread_main_init();
    wait_after_handoff();
    more_wakes_than_deferred();
    host_thread_signals();
    freed_only_after_its_signal();
    return 0;
}
