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
static int slow_kill(pthread_t *pt, int sig);
static int slow_wait(pthread_cond_t *cv, pthread_mutex_t *m, const struct timespec *dl);
static void watched_free(void *p);
static void watched_exit(void *v);
#define pthread_kill(pt, sig) slow_kill(&(pt), sig)
#define pthread_cond_timedwait slow_wait
#define free watched_free
#define pthread_exit watched_exit
#include "../hle_thread.c"
#undef pthread_kill
#undef pthread_cond_timedwait
#undef free
#undef pthread_exit

enum { CLOSE_EXIT, EXIT_CLOSE, CLOSE_PAUSE, EXIT_OPEN };
static const char *how_s[] = {"is closed, then exits", "exits, then is closed", "is closed, then pauses", "exits with its handle open, closed after the pause returns,"};
static const char *win_s[] = {"its signal", "its wait"};
static _Atomic int go_exit, go_pause, in_svc, exited_out, freed, freed_early, kill_race, wait_race, held_in, release_held;
static _Atomic(void *) watch;
static _Atomic(pthread_cond_t *) race_cv;
static thr_t *_Atomic held;
static uint32_t target_h;
static int how;
static const char freed_early_s[] = "[RED] SetThreadActivity's target was freed while its pause loop still used it\n";

static void fail(const char *m) { write(2, m, strlen(m)); _exit(1); }
static void on_alarm(int sig) { (void)sig; fail("[RED] t_pause_exit timed out\n"); }
static void until(_Atomic int *flag, const char *what) {
    for (int i = 0; !atomic_load(flag); i++) { if (i == 2000) fail(what); usleep(1000); }
}
static uint64_t svc(int num, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3) {
    uint64_t r[32] = {a0, a1, a2, a3}; svc_thread(num, r);
    return r[0];
}
static void *closer(void *p) { (void)p; if (svc(0x16, target_h, 0, 0, 0)) fail("[RED] CloseHandle on the target failed\n"); return NULL; }
static void close_target(void) {
    pthread_t c; assert(!pthread_create(&c, NULL, closer, NULL)); assert(!pthread_join(c, NULL));
}
static void let_exit(void) { atomic_store(&go_exit, 1); until(&exited_out, "[RED] the target never exited\n"); }
static void race(void) {
    if (how == EXIT_CLOSE || how == EXIT_OPEN) let_exit();
    if (how != EXIT_OPEN) close_target();
    if (how == CLOSE_EXIT) let_exit();
    if (how == CLOSE_PAUSE) { atomic_store(&go_pause, 1); until(&in_svc, "[RED] the target never entered its SVC\n"); }
    if (atomic_load(&freed)) { atomic_store(&freed_early, 1); write(2, freed_early_s, sizeof freed_early_s - 1); }
}
static int slow_kill(pthread_t *pt, int sig) {
    if (atomic_exchange(&kill_race, 0)) race();
    return pthread_kill(*pt, sig);
}
static int slow_wait(pthread_cond_t *cv, pthread_mutex_t *m, const struct timespec *dl) {
    if (cv != atomic_load(&race_cv)) return pthread_cond_timedwait(cv, m, dl);
    thr_t *hp = atomic_load(&held);
    if (hp && pthread_getspecific(g_keythr) == hp) {
        pthread_mutex_unlock(m); atomic_store(&held_in, 1);
        until(&release_held, "[RED] the held pauser was never released\n");
        pthread_mutex_lock(m); return ETIMEDOUT;
    }
    if (!atomic_exchange(&wait_race, 0)) return pthread_cond_timedwait(cv, m, dl);
    pthread_mutex_unlock(m); race(); pthread_mutex_lock(m);
    return ETIMEDOUT;
}
static void watched_free(void *p) {
    if (p && p == atomic_load(&watch)) atomic_store(&freed, 1);
    free(p);
}
static void watched_exit(void *v) { atomic_store(&exited_out, 1); pthread_exit(v); }

static void t_entry(uint64_t arg) {
    (void)arg;
    while (!atomic_load(&go_exit) && !atomic_load(&go_pause)) usleep(100);
    if (!atomic_load(&go_pause)) return;
    uint64_t regs[100] = {0};
    thr_svc_enter(regs, 0);
    atomic_store(&in_svc, 1);
    while (!atomic_load(&go_exit)) usleep(100);
    thr_svc_leave();
}
static void p_entry(uint64_t arg) { (void)arg; svc(0x32, target_h, 1, 0, 0); }
void dm_thread_enter(uint64_t entry, uint64_t arg, uint64_t sp) {
    (void)sp;
    ((void (*)(uint64_t))entry)(arg);
    svc(0x0A, 0, 0, 0, 0);
    abort();
}
static thr_t *spawn(void (*entry)(uint64_t), int core, uint32_t *h) {
    uint64_t r[32] = {0, (uint64_t)entry, 0, 0, 50, (uint64_t)core}; svc_thread(0x08, r); assert(r[0] == 0);
    *h = (uint32_t)r[1];
    pthread_mutex_lock(&G); thr_t *t = h_peek(*h, O_THREAD); pthread_mutex_unlock(&G);
    assert(t);
    return t;
}
static thr_t *setup(int h) {
    how = h;
    atomic_store(&go_exit, 0); atomic_store(&go_pause, 0); atomic_store(&in_svc, 0); atomic_store(&exited_out, 0);
    atomic_store(&freed, 0); atomic_store(&freed_early, 0);
    thr_t *t = spawn(t_entry, 1, &target_h);
    atomic_store(&watch, t);
    assert(svc(0x09, target_h, 0, 0, 0) == 0);
    return t;
}
static void resume_closed(thr_t *t) {
    pthread_mutex_lock(&G); atomic_store(&t->pause_req, 0); atomic_fetch_and(&t->svc_state, ~2); pthread_cond_broadcast(&t->pcv); pthread_mutex_unlock(&G);
    let_exit();
}

static void one(int window, int h) {
    thr_t *t = setup(h);
    if (window) { atomic_store(&race_cv, &t->pcv); atomic_store(&wait_race, 1); }
    else atomic_store(&kill_race, 1);
    uint64_t r = svc(0x32, target_h, 1, 0, 0);
    atomic_store(&race_cv, NULL);
    if (atomic_load(&freed_early)) _exit(1);
    if (r) fail("[RED] SetThreadActivity failed\n");
    if (h == CLOSE_EXIT || h == EXIT_CLOSE) {
        if (!atomic_load(&freed)) fail("[RED] a target that exited with its handle closed during SetThreadActivity was never freed\n");
    } else if (h == EXIT_OPEN) {
        if (atomic_load(&freed)) fail("[RED] a target that exited during SetThreadActivity was freed while its handle was still open\n");
        close_target();
        if (!atomic_load(&freed)) fail("[RED] a target that exited during SetThreadActivity was never freed at its CloseHandle\n");
    } else {
        if (atomic_load(&freed)) fail("[RED] a paused target whose handle was closed was freed before it exited\n");
        resume_closed(t);
        if (!atomic_load(&freed)) fail("[RED] a paused target whose handle was closed was never freed at its exit\n");
    }
    atomic_store(&watch, NULL);
    printf("PASS: a target that %s while SetThreadActivity has released G for %s is freed once, never while the pause uses it\n", how_s[h], win_s[window]);
}

static void two_pausers(void) {
    thr_t *t = setup(CLOSE_EXIT);
    uint32_t ph; thr_t *p = spawn(p_entry, 2, &ph);
    atomic_store(&held_in, 0); atomic_store(&release_held, 0);
    atomic_store(&held, p); atomic_store(&race_cv, &t->pcv);
    assert(svc(0x09, ph, 0, 0, 0) == 0);
    until(&held_in, "[RED] the second pauser never reached its wait\n");
    atomic_store(&kill_race, 1);
    svc(0x32, target_h, 1, 0, 0);
    if (atomic_load(&freed_early) || atomic_load(&freed)) fail("[RED] SetThreadActivity's target was freed while another pause of it still used it\n");
    atomic_store(&exited_out, 0);
    atomic_store(&release_held, 1);
    until(&exited_out, "[RED] the second pauser never returned\n");
    atomic_store(&held, NULL); atomic_store(&race_cv, NULL);
    if (!atomic_load(&freed)) fail("[RED] the target was never freed after its last pause returned\n");
    assert(svc(0x16, ph, 0, 0, 0) == 0);
    atomic_store(&watch, NULL);
    puts("PASS: with two SetThreadActivity calls on one target, the target is freed only after the last one");
}

int main(void) {
    signal(SIGALRM, on_alarm); alarm(20);
    setenv("DM_PREEMPT", "0", 1);
    svc_thread_main_init();
    for (int window = 0; window < 2; window++)
        for (int h = CLOSE_EXIT; h <= EXIT_OPEN; h++) one(window, h);
    two_pausers();
    assert(g_cv_ndefer == 0);
    return 0;
}
