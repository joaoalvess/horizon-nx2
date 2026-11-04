#include "../dm.h"
#include <assert.h>
#include <stdatomic.h>
#include <unistd.h>

static _Atomic int detclock_on;
static _Atomic uint64_t guest_clock;
static int test_detclock_enabled(void) { return atomic_load(&detclock_on); }
static uint64_t test_guest_ns(void) { return atomic_load(&guest_clock); }
#define dm_detclock_enabled test_detclock_enabled
#define guest_ns test_guest_ns
#include "../hle_thread.c"
#undef dm_detclock_enabled
#undef guest_ns

static uint32_t main_handle;
static _Atomic uint32_t words[4096];
static uint64_t word(int i) { return (uint64_t)&words[i]; }
static uint64_t word_where(int kind, thr_t **head, int same, uint64_t not_a, uint64_t not_b) {
    for (int i = 0; i < 4096; i++) {
        uint64_t a = word(i);
        if (a != not_a && a != not_b && (wait_head(kind, a) == head) == same) return a;
    }
    abort();
}

static uint64_t wait_key_of(const thr_t *t) { return t->wkind == 2 ? t->wkey : t->waddr; }
static int on_chain(thr_t **head, const thr_t *t) {
    for (thr_t *u = *head; u; u = u->next) if (u == t) return 1;
    return 0;
}
static void buckets_consistent(void) {
    pthread_mutex_lock(&G);
    int linked = 0, waiting = 0;
    for (int i = 0; i <= (1 << WAIT_BUCKET_BITS); i++) {
        thr_t **head = i < (1 << WAIT_BUCKET_BITS) ? &g_wait_key[i] : &g_wait_sync, **pp = head;
        for (thr_t *t = *head; t; pp = &t->next, t = t->next) {
            assert(t->pprev == pp);
            assert(t->wkind >= 1 && t->wkind <= 4);
            assert(wait_head(t->wkind, wait_key_of(t)) == head);
            linked++;
        }
    }
    for (thr_t *t = g_all; t; t = t->all) {
        if (t->wkind) waiting++;
        else assert(!t->pprev && !t->next);
    }
    assert(linked == waiting);
    pthread_mutex_unlock(&G);
}
static int waits_in(const thr_t *t, int kind, uint64_t key) {
    pthread_mutex_lock(&G);
    int in = t->wkind == kind && wait_key_of(t) == key && on_chain(wait_head(kind, key), t);
    pthread_mutex_unlock(&G);
    return in;
}

typedef struct {
    thr_t t; pthread_t pt;
    int svc; uint64_t a[4], lock; uint32_t hs[4];
    int64_t res; uint64_t idx; uint32_t held;
} waiter;
static void *waiter_main(void *p) {
    waiter *w = p;
    pthread_setspecific(g_keythr, &w->t);
    if (w->svc == 0x1C) st32(w->lock, w->t.handle);
    uint64_t r[32] = {w->a[0], w->a[1], w->a[2], w->a[3]};
    svc_thread(w->svc, r);
    w->res = (int64_t)r[0]; w->idx = r[1];
    if ((w->svc == 0x1C || w->svc == 0x1A) && !w->res) {
        w->held = ld32(w->lock);
        uint64_t u[32] = {w->lock}; svc_thread(0x1B, u);
    }
    thread_exit(&w->t);
    return NULL;
}
static void waiter_until(waiter *w, int kind) {
    for (;;) {
        pthread_mutex_lock(&G); int k = w->t.wkind; pthread_mutex_unlock(&G);
        if (k == kind) return;
        usleep(100);
    }
}
static void waiter_start(waiter *w, int svc, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, int kind) {
    memset(&w->t, 0, sizeof w->t);
    pthread_cond_init(&w->t.cv, NULL); pthread_cond_init(&w->t.pcv, NULL);
    w->t.started = 1; w->t.prio = 50; w->t.core = 0; w->t.mask = 7;
    pthread_mutex_lock(&G); w->t.handle = h_new(O_THREAD, &w->t); w->t.all = g_all; g_all = &w->t; pthread_mutex_unlock(&G);
    w->svc = svc; w->a[0] = a0; w->a[1] = a1; w->a[2] = a2; w->a[3] = a3; w->res = -1; w->idx = 0; w->held = 0;
    if (svc == 0x1C) { w->lock = a0; w->a[2] = w->t.handle; }
    if (svc == 0x1A) { w->lock = a1; w->a[2] = w->t.handle; }
    if (svc == 0x18) w->a[1] = (uint64_t)w->hs;
    assert(!pthread_create(&w->pt, NULL, waiter_main, w));
    waiter_until(w, kind);
}
static int64_t waiter_join(waiter *w) {
    assert(!pthread_join(w->pt, NULL));
    pthread_mutex_lock(&G);
    for (thr_t **p = &g_all; *p; p = &(*p)->all) if (*p == &w->t) { *p = w->t.all; break; }
    g_h[w->t.handle - 0x1000].type = O_FREE; g_h[w->t.handle - 0x1000].obj = NULL;
    pthread_mutex_unlock(&G);
    pthread_cond_destroy(&w->t.cv); pthread_cond_destroy(&w->t.pcv);
    return w->res;
}
static void event_new(uint32_t *wr, uint32_t *rd) {
    uint64_t r[32] = {0}; svc_thread(0x45, r); assert(r[0] == 0);
    *wr = (uint32_t)r[1]; *rd = (uint32_t)r[2];
}
static void handle_close(uint32_t h) { uint64_t r[32] = {h}; svc_thread(0x16, r); assert(r[0] == 0); }

static void condition_wait_becomes_lock_wait(void) {
    uint64_t lock = word(0);
    uint64_t key = word_where(2, wait_head(1, lock), 0, lock, 0);
    st32(lock, 0); st32(key, 0);
    static waiter cw, lw;
    waiter_start(&cw, 0x1C, lock, key, 0, (uint64_t)-1, 2);
    buckets_consistent();
    assert(waits_in(&cw.t, 2, key) && ld32(key) == 1 && ld32(lock) == 0);
    st32(lock, main_handle | WAITERS_BIT);
    waiter_start(&lw, 0x1A, main_handle, lock, 0, 0, 1);
    uint64_t r[32] = {key, 1}; svc_thread(0x1D, r);
    buckets_consistent();
    assert(waits_in(&cw.t, 1, lock) && !on_chain(wait_head(2, key), &cw.t));
    assert(waits_in(&lw.t, 1, lock));
    assert(ld32(key) == 0 && ld32(lock) == (main_handle | WAITERS_BIT));
    r[0] = lock; svc_thread(0x1B, r);
    assert(waiter_join(&lw) == 0 && waiter_join(&cw) == 0);
    assert(lw.held == (lw.t.handle | WAITERS_BIT) && cw.held == cw.t.handle && ld32(lock) == 0);
    buckets_consistent();
    puts("PASS: a signalled condition waiter moves to its lock's bucket, after the lock's earlier waiter");
}

static void colliding_keys(void) {
    uint64_t a1 = word(1);
    thr_t **h = wait_head(3, a1);
    uint64_t a2 = word_where(3, h, 1, a1, 0), lock = word_where(1, h, 1, a1, a2);
    st32(a1, 7); st32(a2, 7); st32(lock, main_handle | WAITERS_BIT);
    static waiter w1, w2, lw;
    waiter_start(&w1, 0x34, a1, 2, 7, (uint64_t)-1, 3);
    waiter_start(&w2, 0x34, a2, 2, 7, (uint64_t)-1, 3);
    waiter_start(&lw, 0x1A, main_handle, lock, 0, 0, 1);
    buckets_consistent();
    assert(waits_in(&w1.t, 3, a1) && waits_in(&w2.t, 3, a2) && waits_in(&lw.t, 1, lock));
    uint64_t r[32] = {lock, 0, 0, (uint64_t)-1}; svc_thread(0x35, r); assert(r[0] == 0);
    assert(waits_in(&lw.t, 1, lock));
    r[0] = a2; r[1] = 2; r[2] = 7; r[3] = 1; svc_thread(0x35, r); assert(r[0] == 0);
    assert(ld32(a2) == 6 && waiter_join(&w2) == 0);
    assert(waits_in(&w1.t, 3, a1) && waits_in(&lw.t, 1, lock));
    r[0] = a1; r[1] = 2; r[2] = 7; r[3] = (uint64_t)-1; svc_thread(0x35, r); assert(r[0] == 0);
    assert(ld32(a1) == 5 && waiter_join(&w1) == 0);
    r[0] = lock; svc_thread(0x1B, r);
    assert(waiter_join(&lw) == 0 && lw.held == lw.t.handle && ld32(lock) == 0);
    buckets_consistent();
    puts("PASS: waiters on keys that share a bucket are counted and woken by their own key and kind");
}

static void timeouts_leave_no_waiter(void) {
    uint64_t a = word(2), lock = word(3), key = word(4);
    st32(a, 1);
    uint64_t r[32] = {a, 2, 1, 0}; svc_thread(0x34, r); assert(r[0] == R_TIMEOUT);
    buckets_consistent();
    r[0] = a; r[1] = 2; r[2] = 1; r[3] = 1000000; svc_thread(0x34, r); assert(r[0] == R_TIMEOUT);
    buckets_consistent();
    st32(lock, main_handle);
    r[0] = lock; r[1] = key; r[2] = main_handle; r[3] = 1000000; svc_thread(0x1C, r); assert(r[0] == R_TIMEOUT);
    assert(ld32(lock) == 0);
    buckets_consistent();
    uint32_t ew, er; event_new(&ew, &er);
    r[0] = 0; r[1] = (uint64_t)&er; r[2] = 1; r[3] = 1000000; svc_thread(0x18, r); assert(r[0] == R_TIMEOUT);
    buckets_consistent();
    r[0] = 0; r[1] = (uint64_t)&er; r[2] = 1; r[3] = 0; svc_thread(0x18, r); assert(r[0] == R_TIMEOUT);
    buckets_consistent();
    handle_close(ew); handle_close(er);
    r[0] = key; r[1] = 0; svc_thread(0x1D, r);
    assert(ld32(key) == 0);
    puts("PASS: timed-out and immediate waits leave no waiter in any bucket");
}

static void sync_waiters_in_their_own_list(void) {
    uint32_t e1w, e1r, e2w, e2r; event_new(&e1w, &e1r); event_new(&e2w, &e2r);
    uint64_t a = word(5); st32(a, 3);
    static waiter s1, s2, s3, s4, x;
    s1.hs[0] = e1r; waiter_start(&s1, 0x18, 0, 0, 1, (uint64_t)-1, 4);
    s2.hs[0] = e2r; s2.hs[1] = e1r; waiter_start(&s2, 0x18, 0, 0, 2, (uint64_t)-1, 4);
    s3.hs[0] = e2r; waiter_start(&s3, 0x18, 0, 0, 1, (uint64_t)-1, 4);
    waiter_start(&x, 0x34, a, 2, 3, (uint64_t)-1, 3);
    buckets_consistent();
    assert(on_chain(&g_wait_sync, &s1.t) && on_chain(&g_wait_sync, &s2.t) && on_chain(&g_wait_sync, &s3.t) && waits_in(&x.t, 3, a));
    uint64_t r[32] = {e1w}; svc_thread(0x11, r); assert(r[0] == 0);
    assert(waiter_join(&s1) == 0 && s1.idx == 0 && waiter_join(&s2) == 0 && s2.idx == 1);
    buckets_consistent();
    assert(on_chain(&g_wait_sync, &s3.t) && waits_in(&x.t, 3, a));
    r[0] = s3.t.handle; svc_thread(0x19, r); assert(r[0] == 0);
    assert(waiter_join(&s3) == (int64_t)R_CANCELLED);
    s4.hs[0] = x.t.handle; waiter_start(&s4, 0x18, 0, 0, 1, (uint64_t)-1, 4);
    buckets_consistent();
    r[0] = a; r[1] = 0; r[2] = 0; r[3] = 1; svc_thread(0x35, r); assert(r[0] == 0);
    assert(waiter_join(&s4) == 0 && s4.idx == 0 && waiter_join(&x) == 0);
    buckets_consistent();
    handle_close(e1w); handle_close(e1r); handle_close(e2w); handle_close(e2r);
    puts("PASS: synchronization waiters are woken through their handle arrays, by an event, a cancel and a thread exit");
}

static void guest_clock_reaches_every_waiter(void) {
    atomic_store(&guest_clock, 1000000000ull); atomic_store(&detclock_on, 1);
    uint64_t lock1 = word(10), key1 = word(11), a = word(12), lock2 = word(13), key2 = word(14);
    st32(lock1, 0); st32(key1, 0); st32(a, 9); st32(lock2, 0); st32(key2, 0);
    uint32_t ew, er; event_new(&ew, &er);
    static waiter c, d, s, l;
    waiter_start(&c, 0x1C, lock1, key1, 0, 1000000, 2);
    waiter_start(&d, 0x34, a, 2, 9, 1000000, 3);
    s.hs[0] = er; waiter_start(&s, 0x18, 0, 0, 1, 1000000, 4);
    waiter_start(&l, 0x1C, lock2, key2, 0, 1000000, 2);
    st32(lock2, main_handle);
    uint64_t r[32] = {key2, 1}; svc_thread(0x1D, r);
    buckets_consistent();
    assert(waits_in(&l.t, 1, lock2) && ld32(lock2) == (main_handle | WAITERS_BIT));
    usleep(5000);
    assert(waits_in(&c.t, 2, key1) && waits_in(&d.t, 3, a) && on_chain(&g_wait_sync, &s.t) && waits_in(&l.t, 1, lock2));
    atomic_fetch_add(&guest_clock, 2000000);
    dm_guest_clock_advanced();
    assert(waiter_join(&c) == R_TIMEOUT && waiter_join(&d) == R_TIMEOUT && waiter_join(&s) == R_TIMEOUT && waiter_join(&l) == R_TIMEOUT);
    buckets_consistent();
    r[0] = lock2; svc_thread(0x1B, r); assert(ld32(lock2) == 0);
    handle_close(ew); handle_close(er);
    atomic_store(&detclock_on, 0);
    puts("PASS: a guest clock step reaches waiters of every kind, a converted lock waiter among them");
}

int main(void) {
    alarm(20);
    setenv("DM_PREEMPT", "0", 1);
    main_handle = svc_thread_main_init();
    buckets_consistent();
    condition_wait_becomes_lock_wait();
    colliding_keys();
    timeouts_leave_no_waiter();
    sync_waiters_in_their_own_list();
    guest_clock_reaches_every_waiter();
    return 0;
}
