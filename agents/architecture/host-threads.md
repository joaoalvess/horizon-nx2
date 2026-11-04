# Host threads

Written against commit `b0d98ee7`. Every `file:line` below is at that commit. Unless a path is given, lines are in `dm/host/hle_thread.c`.

Each guest thread is one host pthread. The host keeps Horizon's per-thread bookkeeping (priority, ideal core, affinity mask) but has no per-core scheduler. Waits are kernel-ordered queues under one global lock. Core ordering is restored only at SVC boundaries, through same-core handoffs (`:739-741`: "cooperative boundaries, not an asynchronous guest-core scheduler").

Other files of this folder: [overview.md](overview.md) (the thread inventory), [locks.md](locks.md) (every lock and its order), [lifetimes.md](lifetimes.md).

## Global state

| Name | What | Line |
|---|---|---|
| `G` | The scheduler mutex. It is the mutex of every thread's condition variables; since refactor item H3 those are signalled after `G` is released, except in `block` and past 16 queued signals | `:98` |
| `g_h[4096]` | Handle table: type and object. Handle = 0x1000 + index; index 0 is unused, so the first handle is 0x1001 | `:99-100`; `h_new` `:105-108` (G held) |
| `h_peek`, `h_get` | Lookups. `H_CUR_THREAD` (0xFFFF8000) gives the caller. `h_get` also logs a miss | `:109-119` |
| `g_keythr` | TSD key: pthread → `thr_t` | `:101`; created at `:513` |
| `g_next_id` | Next thread ID, from 0x51 | `:102` |
| `g_all` | All threads, linked through `all` | `:93` |
| `g_wait_key[256]`, `g_wait_sync` | Waiting threads since refactor item H2: lock, condition and address waiters in buckets hashed by kind and key (`wait_head`), sync-object waiters (kind 4, matched through their handle arrays) on their own list; each chain doubly linked through `next` / `pprev`, so a waiter unlinks in constant time; every scan still filters by kind and key | `hle_thread.c` (`wait_head`, `wait_link`, `wait_unlink`) |
| `g_cv_defer[16]`, `g_cv_ndefer` | Since H3, per host thread (`__thread`): the condition-variable signals one hold of `G` queued (`cv_signal`); `cv_flush` issues them in wake order after `G` is released. A 17th signal in one hold goes out at once under `G` | `hle_thread.c:256-267` |
| `g_wseq` | Wait registration counter | `:223` |
| `g_se[512]`, `g_se_lock` | System event bindings | `:38-41` |
| `g_core_preempt` | `DM_PREEMPT` or the profile's `DM_GAME_CORE_PREEMPT` | `:96`; set at `:515` |
| `g_preempt_n`, `g_preempt_ns` | Handoff count and time | `:95` |
| `g_qos_map`, `g_qos_e1`, `g_qos_e2` | `DM_QOS_MAP`, `DM_QOS_EDGES` (44, 59) | `:307-312` |

Lock order: `G`, then `g_se_lock` (`:37`).

Result codes: `R_TIMEOUT` 0xEA01, `R_CANCELLED` 0xEC01, `R_BAD_HANDLE` 0xE401, `R_BAD_STATE` 0xFA01 (`:25-28`). Lock words use `WAITERS_BIT` 0x40000000 (`:30`).

## `thr_t`

`thr_t` is at `:52-92`.

| Fields | Meaning | Line |
|---|---|---|
| `handle`, `id`, `entry`, `arg`, `stack_top`, `prio`, `core`, `mask` | Creation values and the Horizon scheduling bookkeeping | `:53-54` |
| `started`, `exited`, `cancel`, `pt`, `cv` | Life state, the pthread, its condition variable | `:56-57` |
| `cv_pend` | Signals queued for this thread and not yet issued (atomic; incremented under `G`, decremented by `cv_flush` without it) | `:58` |
| `wkind`, `woke`, `waddr`, `wkey`, `wtag`, `wres` | The current wait. Kinds: 0 none, 1 lock, 2 condition, 3 address, 4 sync object | `:59` |
| `sleeping` | In a timed sleep or a back-off sleep (atomic) | `:60` |
| `yield_pending` | This thread woke a higher-priority thread pinned to its core | `:61` |
| `hand_epoch` | This thread's current handoff (atomic) | `:62` |
| `start_by`, `start_epoch` | The starter whose StartThread holds for this thread | `:63` |
| `hand[4]`, `nhand` | The handoffs this thread was made runnable for | `:64` |
| `host_work` | Points at the thread's `dm_host_work` | `:65` |
| `native_wait` | Depth of native HLE waits | `:66` |
| `host_owned` | Made by `dm_guest_thread_spawn` | `:67` |
| `wseq`, `next`, `pprev`, `all` | Wait order, wait chain (with its back-link, H2), all-threads chain | `:68-70` |
| `closed` | Handle closed; freed when also exited | `:72` |
| `nsvc`, `nyield`, `nbackoff`, `nspin`, run fields | Counters and yield-run, spin-run and poll-run state | `:73-78` |
| `mport` | Mach port, for CPU time | `:79` |
| `qos_pending`, `qos` | Deferred QoS change and the current class | `:80-81` |
| `pause_req`, `paused`, `svc_regs`, `svc_pc`, `svc_x18`, `svc_state` | Pausing for collectors | `:84-88` |
| `whs`, `whn` | WaitSynchronization's handle array, valid while waiting | `:89` |
| `ctx_*`, `pcv` | Context saved by the pause signal; the pause condition variable | `:90-91` |

## Per-thread host state

| State | Set up by | Freed by | Where |
|---|---|---|---|
| TSD slots K18, KTLS, KTLR | `guest_thread_init`: K18 = 0; an 8192-byte TLS block; a 0x200-byte TLR plus a 0x400-byte thread object, with TLR[0x1f8] = the object | `own_free`, the destructor of `g_keyown`, which keeps the raw pointers | `dm/host/thread.c:14-28`, `:12` |
| Thread ID in the TLR | `guest_thread_set_id` writes it at TLR+0x110 | with the TLR | `dm/host/thread.c:31` |
| Gate slot and stack (KGATE) | `guest_gate_stack` takes a slot under `g_gate_lock` and sets `dm_gate_top[k]` and KGATE. Guest threads: the rest of their own pthread stack below `thread_main`'s frame. The main thread: a mapped 1 MB stack with a 16 KB guard | Slot: `gslot_release`, a key destructor. The main thread's stack is never freed | `dm/host/thread.c:38-75` |
| `g_keythr` → `thr_t` | `thread_main` (`:327`); `svc_thread_main_init` (`:528`) | cleared in `thread_exit` (`:359`) | |
| `dm_host_work` | `__thread` counter; `thr_t.host_work` points at it (`dm/host/hle_thread.c:333`, `:521`) | thread exit | `dm/gfx/nvn/hle_nvn.c:1257` |
| Big stack | `dm_bigstack_top`, on first use: 512 KB plus a 16 KB guard | `bs_free`, a key destructor | `dm/host/hle_bigstack.c:18-39` |
| Signal alt stack | `crash_thread_init`: 64 KB | `altstack_free`, a key destructor | `dm/host/crash.c:185-195` |
| Sleep kqueue | `sleep_kq`, on first sleep | `sleep_kq_close`, a key destructor | `:876-885` |

A guest thread exits with `pthread_exit` from inside the SVC (`:362`), so all of these destructors run on its gate stack.

## Thread life

1. CreateThread, SVC 0x08 (`:930-947`), on the creating thread:
   1. `calloc` the `thr_t`; init `cv` and `pcv` (`:931-932`); stack top aligned to 16 (`:933`).
   2. A negative core becomes 0; mask = 1 << core (`:936`). See `docs/reference/threads.md`, "Ideal core −2 resolves to the process default core".
   3. Handle and ID under `G` (`:938`).
   4. A detached pthread with a 1 MB stack on `thread_main` (`:939-941`).
   5. `pt` and the `g_all` link are published under `G` (`:944`). See "Publishing a new thread's scheduler fields".
2. `thread_main` (`:325-342`), on the new pthread:
   1. `g_keythr` (`:327`).
   2. Under `G`: QoS from `prio_qos`, `qos`, `mport`, `host_work` (`:329-334`).
   3. `crash_thread_init`, `guest_thread_init`, `guest_thread_set_id`, `guest_gate_stack(1)` (`:335-337`).
   4. Waits on `cv` until `started` (`:338`).
   5. `pthread_setname_np` with the handle and the guest name from `ThreadType+0x1a0` (`:339`; `thr_name` `:580-586`).
   6. `dm_thread_enter` (`:340`; `dm/host/entry.S:163-173`): sp = the guest stack, x29 = 0, branch to the entry. If the entry returns, `dm_thread_returned` dies (`dm/host/hle_thread.c:364`).
3. StartThread, SVC 0x09 (`:948-958`): `started` = 1, queue the signal of `cv` (issued by `svc_thread` after `G` is released, `:944`), `note_runnable`. If that set `yield_pending`, it also records `start_by` / `start_epoch` (`:954`).
4. ExitThread, SVC 0x0A (`:959`) → `thread_exit` (`:353-363`):
   - Records the exit time and does not log (`:354-355`).
   - Under `G`: `exited` = 1, `wake_sync_waiters(t)`, clear `g_keythr`, `thr_free` if `closed`.
   - After releasing `G`, `cv_flush` issues its waiters' signals (`:388-390`).
   - `pthread_exit`.
5. CloseHandle on a thread, SVC 0x16 (`:1163-1167`): frees the slot and sets `closed`; `thr_free` if already exited. `thr_free` (`:343-351`) first waits, holding `G`, with `sched_yield` until the thread's `cv_pend` is 0, so no queued signal reaches a destroyed `cv` (`:376-377`); it unlinks from `g_all` and removes every `hand[]` and `start_by` pointing at the freed thread.
6. The main thread: `guest_main` (`dm/host/main.c:22`) calls `svc_thread_main_init` (`dm/host/hle_thread.c:512-533`):
   - Key, QoS map, preempt mode, SIGUSR2 handler, hitch thread (`:513-517`).
   - Priority 44, core 0, mask 1, `started` (`:521`).
   - `qos_apply` (`:524`), then handle 0x1001 and the `g_all` link under `G` (`:527`).
7. Host-made guest threads, `dm_guest_thread_spawn` (`dm/host/hle_guestthread.c:17-32`):
   - The stack comes from the SDK's `malloc`. The SDK's `nn::os::CreateThread` and `StartThread` reach SVCs 0x08 / 0x09.
   - `spawn_tramp` (`dm/host/hle_guestthread.c:16`) calls `dm_thread_mark_host` (`dm/host/hle_thread.c:129`) before the host function. Handoffs ignore `host_owned` threads (`dm/host/hle_thread.c:200`, `:239`), but only once `spawn_tramp` has run, see [Accesses outside `G`](#accesses-outside-g).
   - `dm_guest_thread_join` (`dm/host/hle_guestthread.c:33-39`): `WaitThread`, `DestroyThread`, free.

## Waiting

The bookkeeping is all under `G`. Since H3 the host-level signals are queued (`cv_signal`) and issued after `G` is released (`cv_flush`).

1. `block(t, kind, ns)` (`:250-270`):
   1. Sets `wkind`, clears `woke`, links `t` into its kind and key's bucket (`wait_link`; kind 4 into `g_wait_sync`), `wseq = ++g_wseq` (`:251`).
   2. `ns == 0`: unlinks and returns `R_TIMEOUT` (`:252`).
   3. `hand_leave(t)` (`:253`).
   4. Deadline: on the guest clock under the deterministic clock (`:255-256`); otherwise an absolute `CLOCK_REALTIME` time (`:257-258`).
   5. Issues the caller's queued signals, still under `G` (`:282`): WaitProcessWideKeyAtomic hands its lock to a waiter, then blocks in the same hold.
   6. `pthread_cond_wait` or `pthread_cond_timedwait` on `t->cv` with `G` until `woke` or the deadline (`:259-268`).
   7. Returns `wres`, or `R_TIMEOUT`.
2. `wake(t, res)` (`:245-248`): unlink, `wkind` = 0, `woke` = 1, `wres`, queue the signal of `t->cv` (`cv_signal`), then `note_runnable(t)`. The signal is issued after `G` is released by `svc_thread`, `thread_exit`, `dm_guest_clock_advanced` or the `hle_signal_*` functions, or under `G` by `block` before it waits; the 17th and later in one hold go out at once under `G`.
3. `pick(kind, a)` (`:223-231`): the waiter of that kind and address (key for kind 2) with the lowest priority number, then the lowest `wseq`.
4. Under the deterministic clock, `dm_guest_clock_advanced` (`:572-577`) queues a signal for every waiter, issued after the unlock (`:603-605`), so it re-checks its guest deadline. `dm_detclock_enabled` is at `dm/host/hle_os.c:61`.

## Synchronization SVCs

Every row takes `G` unless noted.

| SVC | Line | Semantics |
|---|---|---|
| 0x1A ArbitrateLock | `:1023-1036` | If the lock word still equals owner \| `WAITERS_BIT`: record `waddr` / `wtag`, optionally lend QoS to the owner (`:1030-1033`), `block` kind 1 with no timeout. Otherwise return 0 at once |
| 0x1B ArbitrateUnlock | `:1037` | `lock_handoff` (`:279-285`): no waiter → word = 0; otherwise word = the picked waiter's tag, plus `WAITERS_BIT` if more wait, and `wake` it |
| 0x1C WaitProcessWideKeyAtomic | `:1038-1063` | Key = 1 first (`:1051`), then record `wkey` / `waddr` / `wtag`, `lock_handoff(addr)`, `block` kind 2 with `poll_wait_begin(timeout)`. A timeout does not retake the lock |
| 0x1D SignalProcessWideKey | `:1064-1072` | Up to `count` (≤ 0 all) kind-2 waiters in kernel order go through `lock_acquire_for` (`:287-295`): a free lock is taken by CAS and the waiter woken; a held one gets `WAITERS_BIT` and the waiter becomes a kind-1 wait with a new `wseq`, unlinked and linked into the lock's bucket (H2). Key = 0 when no kind-2 waiter is left |
| 0x34 WaitForAddress | `:1074-1086` | Type 0: wait if less than; 1: decrement if less than, then wait; 2: wait if equal; 3: wait if the 64-bit value is equal (`:1079-1080`). A failed test returns `R_BAD_STATE`; otherwise `block` kind 3 |
| 0x35 SignalToAddress | `:1087-1107` | Counts kind-3 waiters. Type 1: increment if equal. Type 2: modify by waiter count; count ≤ 0 with waiters gives value − 2 (`:1097`). A failed CAS returns `R_BAD_STATE`; otherwise wake up to `count` in kernel order |
| 0x45 CreateEvent | `:1109-1113` | `event_t` with `refs` = 2; write and read handles |
| 0x11 SignalEvent | `:1114-1128` | Write end only: `signaled` = 1, `wake_sync_waiters` |
| 0x12 ClearEvent | same | Either end: `signaled` = 0 |
| 0x17 ResetSignal | same | Read end only; `R_BAD_STATE` if not signaled |
| 0x18 WaitSynchronization | `:1129-1148` | Loop: `cancel` → `R_CANCELLED`; first signaled handle by `sig_obj` (`:551-560`: an exited thread or a signaled read end; `H_CUR_THREAD` never); a bad handle → `R_BAD_HANDLE`; else `block` kind 4 with `whs` / `whn` set. The deadline uses the guest clock or `CLOCK_MONOTONIC`. Nothing here clears an event |
| 0x19 CancelSynchronization | `:1149-1155` | `cancel` = 1; wakes the thread if it waits in kind 4 |
| 0x16 CloseHandle | `:1156-1171` | An event end: the write end unbinds its system event (`se_unbind`, `:46-50`); `free` at `refs` 0. A thread: see [Thread life](#thread-life) |

`wake_sync_waiters(obj)` (`:563-569`) wakes only kind-4 waiters whose handle array holds `obj`. Each one re-checks its handles.

Findings: `docs/reference/threads.md`, "`SignalToAddress` type 2 with count ≤ 0", "`WaitForAddress` type 3: 64-bit wait if equal" and "Lock acquire without acquire ordering runs a queue item twice".

## Thread SVCs

| SVC | Line | Semantics |
|---|---|---|
| 0x0B SleepThread | `:960-971` | See [Yields, sleeps and polls](#yields-sleeps-and-polls) |
| 0x0C / 0x0D Get / SetThreadPriority | `:972-976` | Under `G`. With `DM_QOS_MAP`, the class follows: at once on the caller, else `qos_pending` |
| 0x0E GetThreadCoreMask | `:977-978` | Without `G` |
| 0x0F SetThreadCoreMask | `:979-986` | Without `G`. −2: core 0, mask 1. A mask that excludes the ideal core moves it to the mask's lowest core (`:984`) |
| 0x10 GetCurrentProcessorNumber | `:987-988` | The ideal core, or the mask's lowest core |
| 0x25 GetThreadId | `:1021` | Without `G` |
| 0x32 SetThreadActivity | `:989-1011` | See [Pausing for collectors](#pausing-for-collectors) |
| 0x33 GetThreadContext3 | `:1012-1020` | Only for a paused thread; `ctx_fill` (`:419-431`) |
| 0x29 GetInfo, free thread count | `dm/host/hle_svc.c:703` | 96 − `thr_limit_used` (`dm/host/hle_thread.c:606-612`) |

## System events

Service events are real kernel events, created by the SDK's own code.

1. `hle_bind_system_event(ev, autoclear)` (`:1180-1194`) must run on a guest thread. It calls the SDK's `CreateSystemEvent(ev, autoclear, true)`, which reaches SVC 0x45. Then it records `ev` → write handle with a new binding ID under `g_se_lock`.
2. `hle_signal_system_event` (`:1222-1241`): under `G`, finds the write end and signals it. If the event is not bound: off a guest thread it skips, with a `[RED]` line logged once per process (`:1238`); on one it binds the event and retries.
3. `hle_signal_bound_system_event` (`:1244`) signals only a bound event, from any thread. `hle_clear_system_event` (`:1252`) clears one.
4. `hle_system_event_binding` (`:1202`) returns the binding ID. `hle_signal_system_event_binding` (`:1209`) signals by ID under `G`, then `g_se_lock`, so a closed and reused handle is not signalled.
5. `hle_dup_readable_handle` (`:1195`) adds a read end: `refs++`.
6. Since H3 the signal functions issue the waiters' signals after releasing `G` (`:1250`, `:1263`, `:1282`): host threads such as audio and vsync never pass through `svc_thread`.

See `docs/reference/threads.md`, "Service-event producers follow the binding lifetime".

## Same-core handoffs

On Horizon, a woken higher-priority thread pinned to the caller's core runs before the caller continues. The host recreates this at SVC boundaries.

1. When an SVC wakes or starts `t`, `note_runnable(t)` (`:236-244`) runs on the waker:
   - `t->hand[]` gets (waker, `waker->hand_epoch`), plus the waker's own live handoffs, up to 4.
   - It sets `waker->yield_pending` when `t` has a lower priority number, is pinned to the waker's core, and the waker's mask allows no other core (`:243`).
   - For a `host_owned` `t` it clears `t->nhand` and records nothing (`:238-239`).
2. `svc_thread` (`:913-925`) runs `svc_thread_impl`, then `cv_flush` (`:944`; the handoff wait below needs the woken thread already signalled), then the check: if `g_core_preempt` or `yield_pending`, it calls `dm_yield_to_core_peers(g_core_preempt)` and counts the wait. `svc_dispatch` calls it before its own `switch` (`dm/host/hle_svc.c:458-459`), and `svc_thread_impl` returns 0 for SVCs it does not handle. So the check runs after the body of a thread or sync SVC, but before the body of any other SVC (0x01-0x06, 0x1E, 0x26, 0x27, 0x29, 0x2C / 0x2D, unknown). Spin and counter gates never reach it (`dm/host/hle.c:116-125`).
3. `dm_yield_to_core_peers(all)` (`:192-205`):
   1. Returns at once if the caller's mask allows another core (`:195`).
   2. Under `G`, looks for a peer that is started, not exited, not host-owned, pinned to the caller's core, higher priority, runnable, and either `all` or in this caller's handoff (`thr_in_handoff`, `:136-139`) (`:199-200`).
   3. If one exists: sleeps 50 µs and scans again (`:203`).
4. Then `yield_pending` = 0 and `hand_epoch++` (`:923`). This ends the handoff for every thread it made runnable.
5. A woken thread leaves its handoffs (`hand_leave`, `:141`) when it blocks (`:253`), sleeps or yields to any thread (`:964`), or enters a native wait (`:176`).

`thr_runnable` (`:132-134`): no wait kind, not `sleeping`, no `native_wait`, no `pause_req`, and `*host_work` = 0.

Ways a guest thread in host code stops holding its core:

| Mechanism | What it does | Where | Callers |
|---|---|---|---|
| `dm_thread_native_wait(1)` / `(0)` | `native_wait++` and `hand_leave`; then `native_wait--` | `:174-181` | `dm/host/hle_oe.c:241-243`; `dm_host_lock` |
| `dm_host_lock(m)` | `trylock`; else a native wait around `pthread_mutex_lock` | `:210-215` | `dm/host/hle_movie.c:164`, `:173`, `:180`, `:459`, `:559`, `:615`, `:632`, `:648` |
| `dm_host_work` | A thread-local counter that `thr_runnable` reads through `host_work` | `dm/host/dm.h:13-21` (`dm_host_mutex_lock`: on `EBUSY`, count it around the lock), `:23-28` (`dm_host_thread_join`) | See the inventory below |
| `dm_thread_service_request` | Below | `:150-169` | 25 `dm/host/hle_fs.c` hooks directly, 6 more through the hook they delegate to (`:722`, `:724`, `:1030`, `:1032`, `:1038`, `:1041`): the rom, save and device-save mounts, the commits, the file and directory hooks. Not the add-on-content, system-data, temporary and cache-storage mounts (`:497`, `:520`, `:554`, `:564`, `:567`, `:570`), the cache list hooks, or the size, query and no-op hooks. The direct callers are listed in [overview.md](overview.md#services) |

`dm_thread_service_request` (`:150-169`):
1. Returns if the caller holds no handoff (`:154`).
2. Takes `start_by` / `start_epoch`, calls `hand_leave`, keeps `start_by`, `native_wait++` (`:155-158`).
3. For up to `SERVICE_START_WAIT_NS` (5 ms), polls every 50 µs until the starter's `hand_epoch` moves (`:160-165`).
4. Clears `start_by`, `native_wait--`; if the starter came back, sleeps `SERVICE_ROUND_TRIP_NS` (200 µs) (`:166-168`).

Every use of `dm_host_work` in `dm/` outside the tests, from a grep of `dm_host_work`, `dm_host_mutex_lock` and `dm_host_thread_join` at this commit:

| User | How | Where | Thread |
|---|---|---|---|
| Definition | `__thread _Atomic int` | `dm/gfx/nvn/hle_nvn.c:1257`; declared at `dm/host/dm.h:13`, `dm/host/hle_thread.c:94` | |
| Registration | `thr_t.host_work = &dm_host_work` | `dm/host/hle_thread.c:333`, `:521` | each guest thread |
| `thr_runnable`, `hitch_grab` | read through `host_work` | `dm/host/hle_thread.c:133`, `:449` | any, under `G` |
| `guest_clock_read_wait` | reads it to skip the background clock freeze | `dm/host/hle_os.c:85` | guest |
| `gfx_enter` / `gfx_leave` | `++` / `--` for the whole call | `dm/gfx/nvn/hle_nvn.c:1258-1259`; callers: NVN submit (`:1281`) and present (`:1922`), Vulkan (`dm/gfx/vk/hle_vk.m:1367`, `:1521`), GL (`dm/gfx/gl/hle_gl.m:623`, `:1203-1204`, `:1356`, `:1531`, `:1652`, `:2003`) | guest |
| NVN submit | `dm_host_mutex_lock(&g_sub_mu)`; `++` around `mtl_prepare` | `dm/gfx/nvn/hle_nvn.c:1279-1280` | guest |
| AudioUnit setup | `dm_host_thread_join` | `dm/host/hle_audio.c:246` | guest |
| Movie decoder | `dm_host_mutex_lock(&d->mu)` / `(&d->wmu)`: `md_job` (`:452`), `md_pump` (`:461`, `:467`, `:490`), Configure (`:594`), Start (`:608`), `md_reset` (`:618`), AcquireInputBufferIndex (`:656`), SendInputBufferForDecode (`:687`), AcquireOutputBufferIndex (`:717`), `md_out_tex` (`:815`), `md_rel` (`:857`) | `dm/host/hle_movie.c` | guest |
| Movie worker | `dm_host_mutex_lock(&d->wmu)` | `dm/host/hle_movie.c:431`, `:443` | host, so it has no effect |

`dm_host_mutex_lock` counts only while the lock is contended; the condition waits after it (for example `md_job` waiting for its job) are not host work. A guest thread blocked in `nvnSyncWait` (`dm/gfx/nvn/hle_nvn.c:737-744`), in the pacing waits of `nvnWindowAcquireTexture` (`:1404-1425`) or in `front_text_input` (`dm/host/front_mac.m:1376-1380`) still counts as runnable.

Findings: `docs/reference/threads.md`, "Same-core wake handoffs", "A same-core handoff holds only a waker pinned to that core", "Starting a higher-priority thread on the caller's core", "A host lock held across a same-core handoff", "Native HLE waits release the guest core", "File system calls are service requests".

## Yields, sleeps and polls

1. SleepThread, SVC 0x0B (`:960-971`):
   - `ns > 0` or −2 (YieldToAnyThread): `hand_leave` under `G` if the thread holds handoffs (`:964`).
   - `ns ≥ 20 µs`, or `ns > 0` under the deterministic clock: `dm_guest_sleep_ns` (`:965`).
   - Otherwise (0, −1, −2, under 20 µs): `thr_yield` (`:969`).
2. `dm_guest_sleep_ns` (`:902-912`):
   - Deterministic clock: 1 ms steps until the guest clock passes the deadline.
   - Otherwise: `sleeping` = 1 and `sleep_precise` (`:886-899`), a `NOTE_CRITICAL` kqueue timer per thread. Without a kqueue, nanosleeps of 3/4 of the remaining time. It stops within 20 µs.
3. `thr_yield` (`:778-787`):
   - Hashes x19–x28.
   - The loop moved on if the previous SVC was this run's yield and the hash differs from both of the last two. Then it returns at once.
   - Otherwise `yield_for` (`:761-765`) with the run's length.
4. `yield_backoff_ns` (`:751-759`): plain `sched_yield` for the first 2 ms of a run. After that, sleeps of run/8, between 10 µs and 250 µs, with `sleeping` = 1 (`:763`). `DM_YIELD_BACKOFF` sets the cap and the start.
5. Spin gates, `dm_spin_wait` (`:796-808`):
   - A new wait starts if another SVC came between passes or more than `SPIN_GAP_NS` (20 µs) passed.
   - It polls for `DM_SPIN_POLL` (2000 µs), then backs off as a yield run. `DM_SPIN=0` turns this off.
6. Short timed waits (under 20 µs), `poll_wait_begin` / `poll_wait_end` (`:816-832`), used by SVCs 0x1C, 0x18 and 0x34:
   - Such a wait continues a yield run.
   - Once the run passes the back-off start, its timeout becomes the back-off sleep.
   - A signalled wait ends the run.

Findings: `docs/reference/threads.md`, "Timer slack in guest sleeps (`sleep_precise`)", "Sleeps under 20 µs take the yield path", "Short timed waits are polls", "Yields that make progress return at once (`thr_yield`)", "A wait at two yields is not progress".

## QoS and the time constraint

| Item | What | Where |
|---|---|---|
| Map | Without `DM_QOS_MAP`, every guest thread is user-interactive. With it: priority ≤ 44 user-interactive, ≤ 59 user-initiated, the rest utility | `prio_qos` `:314-317` |
| Apply | Each thread sets its own class. `thread_main` calls `pthread_set_qos_class_self_np(prio_qos(prio))` directly and records the class it gets (`:330-332`). The main thread (`:524`) and SetThreadPriority on itself (`:975`) go through `qos_apply` | `qos_apply` `:318-321` |
| Deferred | A priority set from another thread raises `qos_pending`; the target applies it at its next `thr_svc_enter` | `:398-400` |
| Lending | ArbitrateLock with `DM_QOS_MAP` starts a `pthread_override_qos_class` on the owner while it waits | `:1030-1033` |
| Host helpers | `dm_host_helper_qos` sets a helper's own class only under `DM_QOS_MAP` | `:323` |
| Time constraint | `set_time_constraint_comp` sets `THREAD_TIME_CONSTRAINT_POLICY` on the calling thread: the one in `nvnWindowAcquireTexture` (`dm/gfx/nvn/hle_nvn.c:1411`). The log line names it the present thread. `DM_RT=0` turns it off; `DM_RT_COMP` fixes the computation | `dm/gfx/nvn/hle_nvn.c:1638-1652`, `:1664` |

Findings: `docs/reference/frame-rate.md`, "Main guest thread keeps inherited default QoS", "Time-constraint computation declared below the thread's peaks", "Registry lock priority inheritance", "Submitting thread moved to the efficiency cores".

## Stacks

| Stack | Who runs on it | Where |
|---|---|---|
| Guest stack | Guest code of a game thread; HLE functions it calls directly | given to CreateThread (`:933`) |
| Main thread's pthread stack | The main thread's guest code, on the 64 MiB pthread (Mac window mode and iOS) or the process main thread | `dm/host/front_mac.m:1334-1336`; `dm/ios/Sources/main.m:198-203` |
| Gate stack | `dm_gate`'s frame and every SVC handler, never below the guest sp | `dm/host/entry.S:59`, `:111`; `dm/host/thread.c:53-75` |
| Big stack | `HLE_FORCE_BIG` bodies and every implemented NVN function except `nvnCommandBuffer*`. It switches only when sp lies in the guest address block (`dm_guest_as_contains`) | `dm/host/hle_bigstack.c:27-89`; `dm/gfx/nvn/nvn_entry.S:79-91` |
| Alt stack | Signal handlers (crash, SIGUSR2 pause) | `dm/host/crash.c:185-195`; `pause_install` `dm/host/hle_thread.c:411-415` (`SA_ONSTACK`) |

The guest block is one anonymous reservation (`dm/host/hle_svc.c:53`), and `dm_guest_as_contains` tests only that range (`dm/host/hle_svc.c:38`). The main thread's stack is a separate mapping, so its big-stack calls never switch (`dm/host/hle_bigstack.c:28`). `dm_bigstack_caller` (`dm/host/hle_bigstack.c:93-97`) gives back the game's return address on both paths. Findings: `docs/reference/threads.md`, "SVCs leave the stack below sp untouched"; `docs/reference/memory.md`, "Host calls on small guest stacks".

## Pausing for collectors

1. SetThreadActivity(pause), SVC 0x32 (`:989-1011`), under `G`:
   1. `pause_req` = 1; `svc_state |= 2`.
   2. If the target is not started, has exited, or is inside an SVC (bit 0), it counts as paused at once.
   3. Otherwise it loops: `pthread_kill(SIGUSR2)` without `G`, then waits 100 µs on `pcv`. After 1 s it logs a `[RED]` line.
2. `on_pause_sig` (`:372-393`) stops only a thread that runs module code with no SVC frame:
   - Saves the ucontext into `ctx_*`, with x18 from the K18 slot and sp − 32.
   - Sets `paused`, then waits on `pcv` until resumed.
   - In host code it returns, and the requester signals again.
3. `thr_svc_enter` (`:395-402`) records `svc_regs` (the gate frame) and sets bit 0. If a pause is pending it marks `paused`.
4. `thr_svc_leave` (`:403-410`):
   - Fast path: CAS of `svc_state` from 1 to 0, without `G`.
   - Otherwise, under `G`, it waits while `pause_req`.
5. GetThreadContext3, SVC 0x33 (`:1012-1020`), returns `R_BAD_STATE` unless paused. `ctx_fill` (`:419-431`) reads the gate frame (`hz_ctx_t`, 0x320 bytes, `:417-418`) or `ctx_*`.
6. Resume: `pause_req` = 0, clear bit 1, broadcast `pcv` (`:1007`).

See `docs/reference/threads.md`, "Pausing threads and reading their context for garbage collectors".

## Diagnostics

| Function | What | Lock | Where |
|---|---|---|---|
| `svc_thread_dump` | Crash and watchdog dump of every guest thread; host threads through `task_threads` | none (`:630`) | `:666-737`; hooked at `dm/host/main.c:93` |
| `hitch_main` | `DM_HITCH_DUMP` stall dump; `hitch_grab` per thread | `G` (`:501`) | `:446-510` |
| `dm_yield_top`, `dm_thread_cpu` | Power line: top yielders; CPU time by priority band | `G` | `:835-852`, `:855-872` |
| `thr_list`, `thr_counts`, `thr_limit_used`, `thr_name_of`, `thr_find_by_name` | Queries | `G` (`:590`, `:598`, `:608`, `:616`, `:625`) | `:588-629` |
| `thr_cur_handle` | The caller's handle; reads TSD only, usable in a signal handler | none | `:621` |

## Accesses outside `G`

These read or write fields that other paths read under `G`. They are stated as code facts, not as findings.

| Access | Fields | Where | Readers under `G` |
|---|---|---|---|
| GetThreadCoreMask | `g_h`, `core`, `mask` (read) | `:977-978` | |
| SetThreadCoreMask | `g_h` (read), `core`, `mask` (write) | `:979-986` | `dm_yield_to_core_peers` (`:199-200`), `note_runnable` (`:243`) |
| GetThreadId | `g_h`, `id` (read) | `:1021` | |
| GetCurrentProcessorNumber | own `core`, `mask` | `:987-988` | |
| `dm_yield_to_core_peers` entry | own `core`, `mask` | `:194-195` | |
| `svc_thread` | own `yield_pending`; `hand_epoch` (atomic) | `:919`, `:923` | `hand_epoch`: `thr_in_handoff` (`:137`), `note_runnable` (`:240`, `:242`), StartThread (`:954`), `dm_thread_service_request` (`:161`) |
| `svc_thread_impl` entry | own `last_svc`, `last_lr`, `nsvc` | `:927` | `hitch_grab` (`:448-449`); `svc_thread_dump` reads them with no lock |
| `dm_thread_mark_host` | own `host_owned` (write) | `:129`, from `spawn_tramp` (`dm/host/hle_guestthread.c:16`) | `dm_yield_to_core_peers` (`:200`), `note_runnable` (`:239`), `thr_limit_used` (`:609`), `dm_thread_cpu` (`:869`) |
| `thr_svc_enter` | own `svc_pc`, `svc_x18` (plain); `svc_regs` store and `svc_state` bit 0 set (atomic); `qos_pending` (atomic) | `:397-398` | `ctx_fill` (`:424-425`); SetThreadActivity reads `svc_state` (`:997`) |
| SetThreadActivity pause loop | target's `pt` (read) after dropping `G`; then `paused`, `exited` after retaking it | `:1001-1002` | `thread_exit` frees the target under `G` when its handle is already closed (`:360`), so in that window these reads can reach a freed `thr_t` |
| `thr_yield`, `dm_spin_wait`, `poll_wait_begin`, `poll_wait_end` | own `nyield`, `nbackoff`, `nspin`, `spin_site`, `spin_mod`, `yrun_*`, `srun_*`, `poll_ret` | `:783`, `:803-806`, `:820-824`, `:831` | `dm_yield_top` reads the counters and writes `*_seen` (`:838-847`) |
| SleepThread | own `nhand` (read) | `:964` | `thr_free` on another thread rewrites `u->nhand` (`:347`) |
| `yield_for`, `dm_guest_sleep_ns` | own `sleeping` (atomic) | `:763`, `:909` | `thr_runnable` |
| `thr_svc_leave` fast path | `svc_state`, `svc_regs` (atomic) | `:405` | SetThreadActivity, `ctx_fill` |
| `svc_thread_dump` | `g_all` and every `thr_t` | `:666-737` | |
| `cv_flush` | each queued thread's `cv` (signal) and `cv_pend` (atomic decrement, release) | `:264-267` | `thr_free` waits for `cv_pend` 0 (acquire, `:376`) |

Between releasing `G` and its `cv_flush`, no path takes `G` again (`svc_thread` `:943-944`, `thread_exit`, `dm_guest_clock_advanced`, the `hle_signal_*` functions). `thr_free` spins on `cv_pend` holding `G`, so a `G` section added in such a window would deadlock it.

`dm_thread_mark_host` runs on the new thread, after StartThread's `note_runnable` (`:952`) has already run with `host_owned` = 0. Until then a lower-priority spawner pinned to the same core can get `yield_pending` and wait for the new thread in `dm_yield_to_core_peers`. The wait ends once `spawn_tramp` has set `host_owned`.

`handle`-table writers (`h_new`, CloseHandle) hold `G` (`:105`, `:1156-1171`).
