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
static int counted_wait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *ts);
static int window_lock(pthread_mutex_t *m);
static int window_unlock(pthread_mutex_t *m);
static int counted_broadcast(pthread_cond_t *c);
#define pthread_cond_timedwait_relative_np counted_wait
#define pthread_mutex_lock window_lock
#define pthread_mutex_unlock window_unlock
#define pthread_cond_broadcast counted_broadcast
#include "../hle_thread.c"
#undef pthread_cond_timedwait_relative_np
#undef pthread_mutex_lock
#undef pthread_mutex_unlock
#undef pthread_cond_broadcast

static _Atomic int untimed, waits, timeouts, acted, release, inside, done_u, stop, window, window_hits, go, fresh, bcasts, rwaits;
static const char *volatile current = "setup";
static thr_t *S;
static thr_t *_Atomic R;
static int all_peers;
static int counted_broadcast(pthread_cond_t *c) {
    if (c == &g_hand_cv) atomic_fetch_add(&bcasts, 1);
    return pthread_cond_broadcast(c);
}
static int counted_wait(pthread_cond_t *c, pthread_mutex_t *m, const struct timespec *ts) {
    thr_t *me = pthread_getspecific(g_keythr);
    if (me && me == atomic_load(&R)) { atomic_fetch_add(&rwaits, 1); return atomic_load(&untimed) ? pthread_cond_wait(c, m) : pthread_cond_timedwait_relative_np(c, m, ts); }
    if (me != S) return pthread_cond_timedwait_relative_np(c, m, ts);
    atomic_store(&fresh, 0);
    atomic_fetch_add(&waits, 1);
    if (atomic_load(&untimed)) return pthread_cond_wait(c, m);
    int r = pthread_cond_timedwait_relative_np(c, m, ts);
    if (r == ETIMEDOUT) atomic_fetch_add(&timeouts, 1);
    return r;
}
static void say(const char *s) { write(2, s, strlen(s)); }
static void on_alarm(int sig) {
    (void)sig;
    say("[RED] t_handoff_wake: "); say((const char *)current); say(": timed out; a same-core handoff wait was never woken\n");
    _exit(1);
}
#define UNTIL(cond) for (;;) { pthread_mutex_lock(&G); int ok_ = (cond); pthread_mutex_unlock(&G); if (ok_) break; usleep(20); }

typedef struct gthr { thr_t t; pthread_t pt; void (*body)(struct gthr *); } gthr;
static gthr P, X, H, V, L, U, O, S2, P2;
static uint32_t ev[4][2];
static _Atomic uint32_t word, uword;
static uint64_t svc(int num, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    uint64_t r[32] = {a0, a1, a2, a3}; svc_thread(num, r);
    return r[0];
}
static int window_lock(pthread_mutex_t *m) {
    int r = pthread_mutex_lock(m);
    if (m == &G && atomic_load(&window) && pthread_getspecific(g_keythr) == S) atomic_store(&fresh, 1);
    return r;
}
static int window_unlock(pthread_mutex_t *m) {
    if (m != &G || !atomic_load(&window) || pthread_getspecific(g_keythr) != S) return pthread_mutex_unlock(m);
    int hit = atomic_load(&fresh) && S->yield_pending && !S->hand_wait && !atomic_load(&P.t.cv_pend) && thr_runnable(&P.t) && (all_peers || thr_in_handoff(&P.t, S));
    int r = pthread_mutex_unlock(m);
    if (hit) {
        atomic_fetch_add(&window_hits, 1); atomic_store(&go, 1);
        for (int i = 0; i < 50000; i++) { pthread_mutex_lock(&G); int b = P.t.wkind != 0; pthread_mutex_unlock(&G); if (b) break; usleep(20); }
    }
    return r;
}
static void ev_wait(int i) { uint32_t h = ev[i][1]; assert(svc(0x18, 0, (uint64_t)&h, 1, (uint64_t)-1) == 0); }
static void ev_signal(int i) { assert(svc(0x11, ev[i][0], 0, 0, 0) == 0); }
static void *gthr_main(void *p) {
    gthr *g = p;
    pthread_setspecific(g_keythr, &g->t);
    pthread_mutex_lock(&G); g->t.host_work = &dm_host_work; pthread_mutex_unlock(&G);
    g->body(g);
    thread_exit(&g->t);
    return NULL;
}
static void gthr_spawn(gthr *g, int prio, int core, void (*body)(gthr *), int started) {
    memset(&g->t, 0, sizeof g->t);
    pthread_cond_init(&g->t.cv, NULL); pthread_cond_init(&g->t.pcv, NULL);
    g->t.started = started; g->t.prio = prio; g->t.core = core; g->t.mask = 1ull << core;
    pthread_mutex_lock(&G); g->t.handle = h_new(O_THREAD, &g->t); g->t.all = g_all; g_all = &g->t; pthread_mutex_unlock(&G);
    g->body = body;
    assert(!pthread_create(&g->pt, NULL, gthr_main, g));
}
static void gthr_start(gthr *g, int prio, int core, void (*body)(gthr *)) { gthr_spawn(g, prio, core, body, 1); }
static void gthr_join(gthr *g) {
    assert(!pthread_join(g->pt, NULL));
    pthread_mutex_lock(&G);
    for (thr_t **p = &g_all; *p; p = &(*p)->all) if (*p == &g->t) { *p = g->t.all; break; }
    for (thr_t *u = g_all; u; u = u->all) for (int i = 0; i < u->nhand; ) if (u->hand[i].by == &g->t) u->hand[i] = u->hand[--u->nhand]; else i++;
    g_h[g->t.handle - 0x1000].type = O_FREE; g_h[g->t.handle - 0x1000].obj = NULL;
    pthread_mutex_unlock(&G);
    while (atomic_load(&g->t.cv_pend)) sched_yield();
    pthread_cond_destroy(&g->t.cv); pthread_cond_destroy(&g->t.pcv);
}
static void begin(const char *what, int timed) {
    current = what; alarm(20);
    for (int i = 0; i < 4; i++) { uint64_t r[32] = {0}; svc_thread(0x45, r); assert(r[0] == 0); ev[i][0] = (uint32_t)r[1]; ev[i][1] = (uint32_t)r[2]; }
    atomic_store(&acted, 0); atomic_store(&release, 0); atomic_store(&inside, 0); atomic_store(&done_u, 0); atomic_store(&stop, 0);
    atomic_store(&word, 0); atomic_store(&uword, 0);
    atomic_store(&untimed, !timed);
}
static void arm(void) { atomic_store(&waits, 0); atomic_store(&timeouts, 0); atomic_store(&bcasts, 0); }
static void disarm(void) { atomic_store(&untimed, 0); }
static int end(const char *what, int ok, int nwaits) {
    for (int i = 0; i < 4; i++) for (int k = 0; k < 2; k++) svc(0x16, ev[i][k], 0, 0, 0);
    printf("%s: %s: handoff waits %d, re-check timeouts %d\n", ok ? "PASS" : "[RED] FAIL", what, nwaits, atomic_load(&timeouts));
    return ok;
}
static void act_when_waited(void) { UNTIL(S->hand_wait); atomic_store(&acted, 1); }
static void until_waiting(gthr *g, int kind) { UNTIL(g->t.wkind == kind); }

static void p_event(gthr *g) { (void)g; ev_wait(0); act_when_waited(); ev_wait(1); }
static void p_address(gthr *g) { (void)g; ev_wait(0); act_when_waited(); assert(svc(0x34, (uint64_t)&word, 2, 0, (uint64_t)-1) == 0); }
static void p_sleep(gthr *g) { (void)g; ev_wait(0); act_when_waited(); svc(0x0B, 2000000, 0, 0, 0); }
static void p_yield_any(gthr *g) { (void)g; ev_wait(0); act_when_waited(); while (!atomic_load(&release)) svc(0x0B, (uint64_t)-2, 0, 0, 0); }
static pthread_mutex_t host_mu = PTHREAD_MUTEX_INITIALIZER;
static void p_native(gthr *g) { (void)g; ev_wait(0); act_when_waited(); dm_host_lock(&host_mu); pthread_mutex_unlock(&host_mu); }
static void p_service(gthr *g) { (void)g; ev_wait(0); act_when_waited(); dm_thread_service_request(); while (!atomic_load(&release)) usleep(50); }
static void p_exit(gthr *g) { (void)g; ev_wait(0); act_when_waited(); }
static void p_spin(gthr *g) { (void)g; ev_wait(0); while (!atomic_load(&release)) usleep(50); }
static void p_svc_spin(gthr *g) {
    (void)g; ev_wait(0);
    uint64_t regs[100] = {0}; thr_svc_enter(regs, 0); atomic_store(&inside, 1);
    while (!atomic_load(&release)) usleep(50);
    thr_svc_leave();
}
static void p_host_work(gthr *g) { (void)g; ev_wait(0); act_when_waited(); dm_host_work++; while (!atomic_load(&release)) usleep(50); dm_host_work--; }
static void h_pause(gthr *g) { (void)g; UNTIL(S->hand_wait && atomic_load(&inside)); atomic_store(&acted, 1); assert(svc(0x32, P.t.handle, 1, 0, 0) == 0); }
static void h_prio_peer(gthr *g) { (void)g; UNTIL(S->hand_wait); atomic_store(&acted, 1); assert(svc(0x0D, P.t.handle, 44, 0, 0) == 0); }
static void h_restart(gthr *g) { (void)g; UNTIL(S->hand_wait); atomic_store(&acted, 1); assert(svc(0x09, P.t.handle, 0, 0, 0) == 0); }
static void h_prio_self(gthr *g) { (void)g; UNTIL(S->hand_wait); atomic_store(&acted, 1); assert(svc(0x0D, S->handle, 30, 0, 0) == 0); }

static int ends_wait(const char *what, void (*peer)(gthr *), void (*helper)(gthr *)) {
    begin(what, 0);
    gthr_start(&P, 30, 0, peer); until_waiting(&P, 4);
    if (helper) gthr_start(&H, 50, 1, helper);
    if (peer == p_native) pthread_mutex_lock(&host_mu);
    arm();
    ev_signal(0);
    pthread_mutex_lock(&G); int a = atomic_load(&acted), n = atomic_load(&waits); pthread_mutex_unlock(&G);
    disarm();
    atomic_store(&release, 1);
    if (peer == p_native) pthread_mutex_unlock(&host_mu);
    if (helper) gthr_join(&H);
    if (helper == h_pause) assert(svc(0x32, P.t.handle, 0, 0, 0) == 0);
    if (helper == h_prio_self) assert(svc(0x0D, S->handle, 44, 0, 0) == 0);
    if (peer == p_event) ev_signal(1);
    if (peer == p_address) { atomic_store(&word, 1); assert(svc(0x35, (uint64_t)&word, 0, 0, 1) == 0); }
    gthr_join(&P);
    return end(what, a && n >= 1, n);
}

static void c_dispatcher(gthr *g) { (void)g; ev_wait(0); UNTIL(S->hand_wait); ev_signal(1); ev_wait(2); }
static void c_worker(gthr *g) { (void)g; ev_wait(1); UNTIL(P.t.wkind == 4 && S->hand_wait && atomic_load(&waits) >= 2); atomic_store(&acted, 1); ev_wait(3); }
static int chain(void) {
    const char *what = "a worker woken by the woken dispatcher blocks after the dispatcher";
    begin(what, 0);
    gthr_start(&P, 30, 0, c_dispatcher); until_waiting(&P, 4);
    gthr_start(&X, 30, 0, c_worker); until_waiting(&X, 4);
    arm();
    ev_signal(0);
    pthread_mutex_lock(&G); int a = atomic_load(&acted), n = atomic_load(&waits), b = atomic_load(&bcasts), xw = X.t.wkind == 4; pthread_mutex_unlock(&G);
    disarm();
    ev_signal(2); ev_signal(3);
    gthr_join(&P); gthr_join(&X);
    printf("  chain: %d broadcasts during the wait\n", b);
    return end(what, a && xw && n >= 2 && b == 2, n);
}

static void w_peer(gthr *g) { (void)g; ev_wait(0); UNTIL(S->hand_wait || atomic_load(&go)); atomic_store(&acted, 1); ev_wait(1); }
static int scan_window(void) {
    const char *what = "the woken thread blocks as soon as the waiter's scan lets go of G";
    begin(what, 0);
    gthr_start(&P, 30, 0, w_peer); until_waiting(&P, 4);
    atomic_store(&go, 0); atomic_store(&window_hits, 0);
    arm(); atomic_store(&window, 1);
    ev_signal(0);
    atomic_store(&window, 0);
    pthread_mutex_lock(&G); int a = atomic_load(&acted), n = atomic_load(&waits); pthread_mutex_unlock(&G);
    disarm();
    ev_signal(1);
    gthr_join(&P);
    return end(what, a && n >= 1 && !atomic_load(&window_hits), n);
}

static void r_started(gthr *g) { UNTIL(g->t.started); act_when_waited(); dm_thread_service_request(); atomic_store(&release, 1); }
static int start_request(void) {
    const char *what = "a started thread's first service request is woken when its starter returns";
    begin(what, 0);
    gthr_spawn(&P, 30, 0, r_started, 0);
    arm(); atomic_store(&rwaits, 0); atomic_store(&R, &P.t);
    assert(svc(0x09, P.t.handle, 0, 0, 0) == 0);
    UNTIL(atomic_load(&release));
    atomic_store(&R, NULL);
    pthread_mutex_lock(&G); int a = atomic_load(&acted), n = atomic_load(&waits), rw = atomic_load(&rwaits); pthread_mutex_unlock(&G);
    disarm();
    gthr_join(&P);
    printf("  start: the request waited %d times\n", rw);
    return end(what, a && n >= 1 && rw >= 1, n);
}

static void b_peer(gthr *g) { (void)g; act_when_waited(); ev_wait(1); }
static int bystander(void) {
    const char *what = "a runnable peer the waiter did not wake blocks";
    begin(what, 0);
    gthr_start(&P, 30, 0, b_peer);
    arm();
    ev_signal(0);
    pthread_mutex_lock(&G); int a = atomic_load(&acted), n = atomic_load(&waits); pthread_mutex_unlock(&G);
    disarm();
    ev_signal(1);
    gthr_join(&P);
    return end(what, a && n >= 1, n);
}

static int host_work_recheck(void) {
    const char *what = "host work entered without G ends the wait at the re-check";
    begin(what, 1);
    gthr_start(&P, 30, 0, p_host_work); until_waiting(&P, 4);
    arm();
    ev_signal(0);
    pthread_mutex_lock(&G); int a = atomic_load(&acted), n = atomic_load(&waits), hw = *P.t.host_work == 1; pthread_mutex_unlock(&G);
    int to = atomic_load(&timeouts);
    atomic_store(&release, 1);
    gthr_join(&P);
    return end(what, a && hw && n >= 1 && to >= 1, n);
}

static void q_peer(gthr *g) { (void)g; ev_wait(0); UNTIL(S->hand_wait && V.t.wkind == 4 && (all_peers || L.t.wkind == 4) && atomic_load(&done_u) == (all_peers ? 1 : 2)); atomic_store(&acted, 1); ev_wait(1); }
static void q_other(gthr *g) { (void)g; ev_wait(0); UNTIL(S->hand_wait); ev_wait(1); }
static void q_unrelated(gthr *g) {
    if (g == &O) { pthread_mutex_lock(&G); dm_thread_mark_host(); pthread_mutex_unlock(&G); }
    UNTIL(S->hand_wait);
    for (int i = 0; i < 20; i++) assert(svc(0x34, (uint64_t)&uword, 2, 0, 30000) == R_TIMEOUT);
    atomic_fetch_add(&done_u, 1);
}
static int unrelated(void) {
    const char *what = all_peers ? "blocks by threads that cannot hold the waiter (other core, host-owned) do not wake it"
                                 : "blocks outside the handoff (other core, lower priority, not woken by it, host-owned) do not wake the waiter";
    begin(what, 0);
    gthr_start(&P, 30, 0, q_peer); until_waiting(&P, 4);
    gthr_start(&V, 30, 1, q_other); until_waiting(&V, 4);
    if (!all_peers) { gthr_start(&L, 50, 0, q_other); until_waiting(&L, 4); }
    gthr_start(&O, 30, 0, q_unrelated); UNTIL(O.t.host_owned);
    arm();
    if (!all_peers) gthr_start(&U, 30, 0, q_unrelated);
    ev_signal(0);
    pthread_mutex_lock(&G); int a = atomic_load(&acted), n = atomic_load(&waits), b = atomic_load(&bcasts); pthread_mutex_unlock(&G);
    disarm();
    ev_signal(1);
    if (!all_peers) gthr_join(&U);
    gthr_join(&O); gthr_join(&P); gthr_join(&V);
    if (!all_peers) gthr_join(&L);
    printf("  unrelated: %d broadcasts during the wait\n", b);
    return end(what, a && n >= 1 && b == 1, n);
}

#define ROUNDS 2000
static _Atomic int rounds2;
static void s_peer(gthr *g) {
    int e = g == &P ? 0 : 1;
    for (;;) { ev_wait(e); assert(svc(0x12, ev[e][1], 0, 0, 0) == 0); if (atomic_load(&stop)) break; }
}
static void s_signaller2(gthr *g) {
    (void)g;
    while (!atomic_load(&stop)) { ev_signal(1); atomic_fetch_add(&rounds2, 1); }
}
static int stress(void) {
    const char *what = "peers that block at once after each wake, with a second signaller on the core";
    begin(what, 0);
    gthr_start(&P, 30, 0, s_peer); until_waiting(&P, 4);
    if (!all_peers) { gthr_start(&P2, 30, 0, s_peer); until_waiting(&P2, 4); gthr_start(&S2, 46, 0, s_signaller2); }
    arm();
    int waited = 0;
    for (int i = 0; i < ROUNDS; i++) { int w0 = atomic_load(&waits); ev_signal(0); waited += atomic_load(&waits) != w0; }
    int n = atomic_load(&waits);
    disarm();
    atomic_store(&stop, 1);
    if (!all_peers) { gthr_join(&S2); ev_signal(1); gthr_join(&P2); }
    ev_signal(0); gthr_join(&P);
    printf("  stress: %d rounds, %d of them waited; second signaller %d rounds\n", ROUNDS, waited, atomic_load(&rounds2));
    return end(what, waited > 0, n);
}

int main(int argc, char **argv) {
    (void)argv;
    setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGALRM, on_alarm);
    all_peers = argc > 1;
    setenv("DM_PREEMPT", all_peers ? "1" : "0", 1);
    setenv("DM_YIELD_BACKOFF", "0", 1);
    svc_thread_main_init();
    S = cur();
    int ok = 1;
    ok &= ends_wait("the woken thread blocks on an event", p_event, NULL);
    ok &= ends_wait("the woken thread blocks on an address", p_address, NULL);
    if (!all_peers) ok &= ends_wait("the woken thread sleeps", p_sleep, NULL);
    if (!all_peers) ok &= ends_wait("the woken thread yields to any thread", p_yield_any, NULL);
    ok &= ends_wait("the woken thread waits for a host lock (native wait)", p_native, NULL);
    if (!all_peers) ok &= ends_wait("the woken thread makes a service request", p_service, NULL);
    ok &= ends_wait("the woken thread exits", p_exit, NULL);
    ok &= ends_wait("another thread pauses the woken thread", p_svc_spin, h_pause);
    ok &= ends_wait("another thread lowers the woken thread's priority", p_spin, h_prio_peer);
    ok &= ends_wait("another thread raises the waiter's priority", p_spin, h_prio_self);
    if (!all_peers) ok &= ends_wait("another thread starts the woken thread again", p_spin, h_restart);
    ok &= start_request();
    if (all_peers) ok &= bystander();
    ok &= chain();
    ok &= scan_window();
    ok &= host_work_recheck();
    ok &= unrelated();
    ok &= stress();
    alarm(0);
    return ok ? 0 : 1;
}
