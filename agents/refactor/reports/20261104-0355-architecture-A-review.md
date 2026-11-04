# Architecture review: overview.md and host-threads.md

BASE `b0d98ee7`. Code read in `/Volumes/Hangar/Games/overnight/base-src-b0d98ee7` (checked byte-identical to `git show b0d98ee7:` for `hle_thread.c`, `hle_nvn.c`, `nvn_mtl.m`, `hle_audio.c`, `hle_sdk16.c`, `front_mac.m`). Links to `nvn-pipeline.md`, `lifetimes.md`, `nvn-state.md` and `locks.md` not counted, as the brief says.

## Verdicts

- `agents/architecture/overview.md`: **reject**. 4 statements wrong, 2 imprecise in a way that matters for the lock and state files. Each needs a one-line rewrite; the rest of the file holds.
- `agents/architecture/host-threads.md`: **reject**. 4 statements wrong. Two of them are inventories that S3 and `locks.md` will build on: the `dm_host_work` user list, which claims to be complete, and "Accesses outside `G`". Fix both before anyone relies on them. The rest holds, line numbers included.

## overview.md

| # | Statement (doc line) | Result |
|---|---|---|
| 1 | `svc_dispatch` calls `hlecount_svc`, `mem_init`, then `svc_thread` first (104) | holds, `hle_svc.c:456-458` |
| 2 | `svc_thread` runs the same-core handoff check *after* every SVC, including the memory ones (104) | **wrong**, see O1 |
| 3 | `gate_dispatch` kinds: CNTPCT/CNTVCT, OBS, SPIN (`thr_svc_enter`/`dm_spin_wait`/`thr_svc_leave`), SVC (95-102) | holds, `hle.c:112-132` |
| 4 | `dm_gate` 800-byte frame layout, nested check, restore all but x18 (90-94) | holds, `entry.S:59-159` |
| 5 | Loader row: `load_modules` "... applies relocations, runs module inits" (19) | **wrong**, see O3 |
| 6 | `nvnQueueSubmitCommands` order: `g_sub_mu` via `dm_host_mutex_lock`, `mtl_prepare` inside `dm_host_work`, `gfx_enter`, ..., `mtl_sub_commit`, unlock, `gfx_leave` (146-152) | holds, `hle_nvn.c:1278-1300` |
| 7 | `nvnSyncWait` calls `mtl_wait`/`mtl_wait_acq` without `dm_host_work` (155) | holds, `hle_nvn.c:737-744` |
| 8 | Graphics gate: `gfx_enter` waits on `g_susp`, counts `g_inflight_api`, then `dm_host_work++`; `dm_gfx_suspend(1)` waits, then drains VK, GL, Metal (161-163) | holds, `hle_nvn.c:1258-1270` |
| 9 | Every implemented NVN function except `nvnCommandBuffer*` goes through `nvn_big_entry` (144) | holds, `hle_nvn.c:1334-1337` (the no-op table is excluded too) |
| 10 | `mtl_sub_begin` dies "submit re-entered" and sets `g_sub_thread` (173) | holds, `nvn_mtl.m:818-819` |
| 11 | Completion: "`post_complete` under `g_mu` / `g_cv` / `g_done`" (175) | **imprecise**, see O5 |
| 12 | `present_main` "waits for their fences ... skips items while `g_link_owns_layer`" (187) | **imprecise**, see O6 |
| 13 | `link_sync` starts `link_main` (`nvn-present-link`, user-interactive), which waits for `g_classic_busy`, attaches the link, runs `CFRunLoopRun` (188) | holds, `nvn_mtl.m:12739-12755`, `:12786` |
| 14 | Thread table QoS: audio renderer and movie deferred work "inherited"; process main thread "default (unverified)" (254, 259, 260) | **wrong**, see O2 |
| 15 | fs row: "each fs hook calls `dm_thread_service_request`" (128) | **wrong**, see O4 |
| 16 | Encode thread from `rec_put` (`:207-209`), 1 MB, user-interactive; ub-copy from `ubc_push`, spins 2000 then `g_ubc_cv` (271-272) | holds, `nvn_rec.h:24-60`, `:179-212` |
| 17 | Lifecycle observers and SIGTERM path (240-244) | holds, `front_mac.m:1324-1327`, `hle_lifecycle.c:10-28` |
| 18 | Audio notify, silent sink, stream sink, vsync: user-interactive under `DM_QOS_MAP` via `dm_host_helper_qos` | holds, `hle_audio.c:72`, `:252`, `:281`; `hle_sdk16.c:261` |

### O1. The handoff check runs before the body of a non-thread SVC
- Doc line 104 (and `host-threads.md` line 174).
- Code: `svc_dispatch` calls `svc_thread` at `hle_svc.c:458`, before its own `switch` at `:459`.
- `svc_thread` (`hle_thread.c:913-925`) runs `svc_thread_impl`, then the `dm_yield_to_core_peers` wait and `hand_epoch++`, and only then returns 0.
- So for SVCs that `svc_thread_impl` does not handle (0x01-0x06, 0x1E, 0x26, 0x27, 0x29, 0x2C/0x2D, unknown), the wait and the end of the handoff come at entry, before the SVC's body. Only thread and sync SVCs get them after.
- Spin gates and counter gates never reach `svc_thread` (`hle.c:116-125`).
- Correct fact: "at every SVC boundary: after a thread or sync SVC, before the body of any other SVC; never at spin or counter gates".
- What breaks: a stage that moves work into a memory SVC, or reasons about what a woken peer can observe "after the SVC returns", gets the order wrong.

### O2. QoS of host-made guest threads and of the windowless main thread
- `dm_guest_thread_spawn` goes through the SDK's `CreateThread`, which is SVC 0x08 (`hle_guestthread.c:28`).
- So the audio renderer and the movie deferred thread start in `thread_main`, which sets QoS from priority: `pthread_set_qos_class_self_np(prio_qos(t->prio))` (`hle_thread.c:330`).
- Correct fact: both rows are "by priority, like a game thread" (user-interactive without `DM_QOS_MAP`), not "inherited".
- Process main thread without `DM_WINDOW`: it runs `guest()` (`front_mac.m:1222`), so `svc_thread_main_init` calls `qos_apply` on it (`hle_thread.c:524`). Its QoS is "set by `qos_apply`" in that mode; "default (unverified)" applies only with `DM_WINDOW`.
- What breaks: a power or QoS stage would treat these threads as following their creator.

### O3. `load_modules` does not run module inits
- `load_modules` (`loader.c:683-713`) maps, makes the keys, registers gates, relocates and checks forced take-overs. It runs no init.
- `run_module_inits` (`loader.c:717-724`) runs from `guest_main` (`main.c:35`), on the guest main thread, after `nninitStartup` and `_init_libc2`.
- With `DM_PRELOAD`, `load_modules` runs on `preload_thread` (`main.c:117`) while the inits run on the guest main thread, so "runs module inits" in the Loader row puts guest code on the wrong thread.
- The "Inits" row of "Modules and imports" (line 72) is right.

### O4. Not every fs hook is a service request
- `hle_fs.c` has 71 take-overs. 25 call `dm_thread_service_request` directly, and 4 more reach one by delegating (`:722`, `:724`, `:1030`, `:1032`).
- Hooks that touch the host file system without it: `MountAddOnContent` (`:497`), `MountTemporaryStorage` (`:554`), `CreateCacheStorage` (`:564`, `mkdir`), `MountCacheStorage` (`:567`, `mkdir`), `DeleteCacheStorage` (`:570`). The size, query and no-op hooks don't call it either.
- Correct fact: "the mount-rom/save/device-save, commit, file and directory hooks call it; the cache and add-on-content mounts and the size/query hooks do not".
- Same error in `host-threads.md` line 191.

### O5. `post_complete` is not run under `g_mu`
- `post_complete` (`nvn_mtl.m:1588-1601`) walks fences and runs `post_run` with no lock held. Each record is claimed by `post_claim` (`:1592`).
- It reads `g_done` without `g_mu` (`:1590`). It takes `g_mu` only to raise `g_done` and broadcast `g_cv` (`:1600`).
- It has two callers on different threads:
  - the commit feedback handler on `dm.nvn.mtl4-feedback` (`:1632`);
  - the waiting game thread, through `post_early` (`:1657`) from `mtl_wait_at` (`:1664`).
- `g_done` is also read without the lock at `:825` and `:1660`.
- `nvn-state.md` and `locks.md` need this exact shape: two writers of `g_done`, and lock-free readers.

### O6. What `present_main` waits for
- While `g_link_owns_layer` is set, it does not take items at all. It waits on `g_pq_cv` (`nvn_mtl.m:12819`), and the display-link callback takes the items.
- Before `present_now` it calls:
  - `ext_wait(it.ev_val)` (`:12824`, `:12626`): a GPU-side `[g_q4 waitForEvent:]` on the external producer's event, for Vulkan or GL frames only;
  - `snap_commit_wait`, for snapshots.
- It does not wait for NVN fences on the CPU.

### Nits (overview.md)
- Line 199: the GL "Gate" cell cites `hle_gl.m:201-202`, which is the queue creation. The gate calls are at `:623`, `:1203-1204`, `:1356`, `:1531`, `:1652-1661` and `:2003-2021`.
- Line 274: `nvn_mtl.m:916-918` is a `MTLSharedEventListener` block, not a command-buffer completion handler.
- Line 223: the "Decode locks" row lists only the `dm_host_lock` sites. The decoder's `d->mu` and `d->wmu` are taken with `dm_host_mutex_lock` from guest threads (see H2).

## host-threads.md

| # | Statement (doc line) | Result |
|---|---|---|
| 1 | `G` is the mutex of every `cv`/`pcv` wait; handle table and `h_new` under `G` (13-14, 296) | holds, `hle_thread.c:98-108`, `:265`, `:338`, `:389`, `:407`, `:1004`; `h_new` callers `:527`, `:938`, `:1111`, `:1198` |
| 2 | Lock order `G` → `g_se_lock` (26) | holds, `:37`, `:46-50`, `:1209-1259` |
| 3 | `block`: push, `wseq`, `ns == 0` timeout, `hand_leave`, deterministic or `CLOCK_REALTIME` deadline (105-111) | holds, `:250-270` |
| 4 | `note_runnable`: handoff entries, `yield_pending` rule, `host_owned` skipped (170-173) | holds, `:236-244` (it clears `t->nhand` before the early return) |
| 5 | `svc_thread` runs after every SVC (174) | **wrong**, see O1 |
| 6 | `dm_yield_to_core_peers`: mask test, scan under `G`, 50 µs sleeps (175-178) | holds, `:192-205` |
| 7 | Sync SVC semantics 0x1A, 0x1B, 0x1C (key = 1 first), 0x1D, 0x34 (types 0-3), 0x35 (count ≤ 0 → value − 2), 0x18, 0x19, 0x16 (120-134) | holds, `:1023-1171` |
| 8 | Thread life: CreateThread publishes `pt`/`g_all` under `G` after `pthread_create`; `thread_main` order; `thread_exit` and `thr_free` (73-91) | holds, `:930-947`, `:325-363` |
| 9 | `dm_thread_service_request` steps and the 5 ms / 200 µs constants (193-197) | holds, `:148-169` |
| 10 | System-event binding, signal paths, binding ID under `G` then `g_se_lock` (158-162) | holds, `:1180-1261` |
| 11 | "The `dm_host_work` users are the only ones, from a grep of the tree" and the table's caller column (190, 199) | **wrong**, see H2 |
| 12 | "every fs hook" calls `dm_thread_service_request` (191) | **wrong**, see O4 |
| 13 | "Accesses outside `G`" table (280-296) | **wrong (incomplete)**, see H3 |
| 14 | Pausing: SVC-state bits, `on_pause_sig` only in module code, the `thr_svc_leave` fast path (254-267) | holds, `:372-410`, `:989-1011` |
| 15 | Yields, sleeps and polls: `thr_yield`, back-off 2 ms / run/8 / 10-250 µs, spin gate, `poll_wait_*` used by 0x1C, 0x18 and 0x34 (205-223) | holds, `:751-832`, `:960-971`, `:1059`, `:1082`, `:1130` |
| 16 | Per-thread state: TLS/TLR sizes, gate slot and stack, big stack 512 KB + 16 KB, alt stack 64 KB, sleep kqueue, all freed by key destructors on the gate stack (60-69) | holds, `thread.c:14-75`, `hle_bigstack.c:18-39`, `crash.c:185-195` |
| 17 | Big stack switches only when sp is in the guest block (247) | holds, `hle_bigstack.c:27-28` |

### H2. The `dm_host_work` users list is incomplete
- `hle_movie.c` takes its decoder locks with `dm_host_mutex_lock`, which bumps `dm_host_work` when the lock is contended (`dm.h:14-21`). It does so from guest-thread take-overs:
  - `md_job` (`:452`);
  - Configure (`:594`), Start (`:608`), `md_reset` (`:618`);
  - AcquireInputBufferIndex (`:656`), SendInputBufferForDecode (`:687`), AcquireOutputBufferIndex (`:717`);
  - `md_out_tex` (`:815`), `md_rel` (`:857`).
- `md_pump` takes it at `:461`, `:467` and `:490`.
- `md_worker` (`:431`, `:443`) also takes it, but on a host thread, where it has no effect.
- `guest_clock_read_wait` reads `dm_host_work` to skip the background freeze (`hle_os.c:85`).
- So the claim "the only ones, from a grep of the tree" is false.
- What breaks: a stage that changes `dm_host_mutex_lock`, or reasons about which waits keep a guest core held, would miss every movie path.

### H3. "Accesses outside `G`" leaves out writes that readers under `G` depend on
Accesses missing from the table:
- `dm_thread_mark_host` writes `host_owned` without `G` (`hle_thread.c:129`).
  - It runs on the new thread in `spawn_tramp` (`hle_guestthread.c:16`), after StartThread's `note_runnable` (`:952`) has already run with `host_owned` = 0.
  - Readers under `G`: `dm_yield_to_core_peers` (`:200`), `note_runnable` (`:239`), `thr_limit_used` (`:609`), `dm_thread_cpu` (`:869`).
  - So "Handoffs ignore `host_owned` threads" (line 98) holds only once `spawn_tramp` has run. Until then, a lower-priority spawner pinned to the same core can get `yield_pending` and wait for the new thread in `dm_yield_to_core_peers`.
- `thr_svc_enter` writes `svc_pc` and `svc_x18` (plain fields) and `qos_pending` without `G` (`:397-398`). `ctx_fill` reads them under `G` (`:424-425`).
- `svc_thread_impl` writes `last_svc`, `last_lr` and `nsvc` without `G` (`:927`). `hitch_grab` reads them under `G` (`:448-449`); `svc_thread_dump` reads them with no lock.
- `thr_yield`, `dm_spin_wait` and `poll_wait_begin`/`end` write the following without `G` (`:783`, `:803-806`, `:820-824`, `:831`):
  - `nyield`, `nbackoff`, `nspin`;
  - `spin_site`, `spin_mod`;
  - `yrun_*`, `srun_*`, `poll_ret`.

  `dm_yield_top` reads these counters and writes `*_seen` under `G` (`:838-847`).
- SleepThread reads its own `nhand` without `G` (`:964`), while `thr_free` on another thread rewrites `u->nhand` under `G` (`:347`).
- Readers of `hand_epoch` also include `note_runnable` (`:240`, `:242`) and StartThread (`:954`), not only `thr_in_handoff` and `dm_thread_service_request`.

### Nits (host-threads.md)
- Line 232: the "Apply" row puts `thread_main` (`:330`) under `qos_apply`. `thread_main` calls `pthread_set_qos_class_self_np` directly and records the class it gets (`:330-332`). Only the main thread and SetThreadPriority go through `qos_apply`.
- Line 276-278: the Lock column is blank for `hitch_main` and for the queries, but all of them take `G` (`:501`, `:590`, `:598`, `:608`, `:616`, `:625`). `thr_cur_handle` is the exception.
- Line 159: the `[RED]` line for a signal from off a guest thread is logged once per process (`:1238`).
- Line 250: "should never switch (unverified)" can be checked from the code. `dm_bigstack_top` returns 0 unless sp is in `g_as` (`hle_bigstack.c:28`), and the 64 MiB pthread stack is a separate mapping.

## Re-check

Re-checked against the same snapshot: every line rewritten for O1-O6, H2, H3 and the nits, the two completed inventories, and 3 new statements per file.

### Correction to this report
- O4 said 4 hooks reach `dm_thread_service_request` by delegating (`:722`, `:724`, `:1030`, `:1032`). There are 6: the two `ReadFile` overloads with read options also delegate, `h_fs_ReadFileOpt` (`hle_fs.c:1038`) to `h_fs_ReadFile` and `h_fs_ReadFileExactOpt` (`:1041`) to `h_fs_ReadFileExact`.
- O4 also left out `MountSystemData` (`:520`). It mounts a host directory and does not call it.
- Both files copied the wrong count; see below.

### overview.md

| Line | Statement | Result |
|---|---|---|
| 19 | Loader row: no guest code, inits from `guest_main` | holds, `loader.c:683-713`, `main.c:35` |
| 104 | Handoff check at every SVC boundary: after thread and sync SVCs, before others; never at spin or counter gates | holds, `hle_svc.c:458-459`, `hle_thread.c:913-925`, `hle.c:116-125` |
| 128 | fs: 25 direct callers (list), "4 through the hook they delegate to"; mounts that do not call | **wrong count**: 6 delegate (add `:1038`, `:1041`); the "do not" list lacks `MountSystemData` (`:520`). The 25 direct callers listed are exact |
| 175 | `post_complete` locking, `g_done` readers, two callers | holds, `nvn_mtl.m:1588-1601`, `:1632`, `:1656-1658`, `:1664`, `:825`, `:1660` |
| 187-192 | `present_main` takes no items in link mode; `ext_wait` GPU-side; `snap_commit_wait` CPU wait on the encode thread's `RO_NOTE` | holds, `:12819`, `:12626`, `:12889`, `nvn_rec.h:103-106`, `nvn_mtl.m:12956-12965`. With no encode thread, `g_snap_cmt` is stored at once (`:12965`), so the wait returns immediately |
| 195, 203-204 | GL and Vulkan gate and present sites | holds, `hle_gl.m:623`, `:1203-1204`, `:1356`, `:1531`, `:1652`, `:1661`, `:2003-2021`; `hle_vk.m:1367`, `:1397`, `:1521`, `:1530` |
| 228-229 | Movie locks: `dm_host_lock` sites; `dm_host_mutex_lock` sites, guest vs host | holds. `md_pump`'s callers are take-overs (`hle_movie.c:709`, `:819`, `:866`) |
| 260-261 | Process main thread split by `DM_WINDOW` | holds, `front_mac.m:1222`, `:1337`, `hle_thread.c:524` |
| 266-267 | Host-made guest threads get QoS by priority in `thread_main` | holds, `hle_guestthread.c:28`, `hle_thread.c:330` |
| 281-282 | Completion handlers; shared-event listener row | holds, `nvn_mtl.m:916-918` |

New statements:
1. Line 256, "Host threads never enter guest code, except those made with `dm_guest_thread_spawn`": holds on the paths checked; the code as a whole is unverified.
   - The movie events go through the SDK's `SignalEvent` (`md_event`, `hle_movie.c:149`), called only from `md_defer_body` (`:187`), `md_pump` (`:471`, `:498-499`) and SendInputBufferForDecode (`:708`), all on guest threads.
   - The audio notify thread uses `hle_signal_system_event`, which never binds off a guest thread (`hle_thread.c:1238`).
2. Line 240, `front_text_input` blocks the guest thread on `dispatch_sync` to the main queue: holds (`front_mac.m:1380`). Without a layer it returns -1 first (`:1377`). That also keeps the windowless case, where the guest main thread is the process main thread, from deadlocking.
3. Line 120, the locks `g_map_lock` (`:102-110`) and `g_rgn_lock` (`:319`): holds, `hle_svc.c:110`, `:319`.

Nit: in line 266 the 9 is the `nn::os` priority given to `CreateThread`. `prio_qos` sees the Horizon priority the SDK passes to SVC 0x08. Both are ≤ 44 here, so the class is the same.

### host-threads.md

| Line | Statement | Result |
|---|---|---|
| 98 | `host_owned` honoured only once `spawn_tramp` has run | holds, `hle_guestthread.c:16`, `hle_thread.c:129`, `:952` |
| 172-174 | `note_runnable` with a `host_owned` `t`; `svc_thread` order | holds, `:238-239`, `hle_svc.c:458-459` |
| 191 | fs callers | **wrong count**, the same as in overview.md: 6 delegate, and `MountSystemData` (`:520`) is missing from the "not" list |
| 199-213 | `dm_host_work` inventory | holds and is complete. A fresh grep of `dm_host_work`, `dm_host_mutex_lock`, `dm_host_thread_join` and `dm_gfx_enter` under `dm/`, tests excluded, finds no other site. `md_job` waits on `wcv` outside host work (`hle_movie.c:454`), as the note says |
| 232 | QoS Apply row | holds, `:330-332`, `:318-321`, `:524`, `:975` |
| 276-280 | Diagnostics Lock column | holds, `:501`, `:590`, `:598`, `:608`, `:616`, `:625`; `thr_cur_handle` `:621` takes none |
| 280-310 | "Accesses outside `G`" | holds for every row added. **Two accesses are still missing** (below) |
| Stacks | Main-thread big-stack calls never switch | holds, `hle_svc.c:38`, `:53`, `hle_bigstack.c:28` |

Still missing from "Accesses outside `G`":
- `thr_svc_enter` also stores `svc_regs` and sets `svc_state` bit 0 without `G` (`:397`).
  - Readers under `G`: SetThreadActivity (`svc_state`, `:997`) and `ctx_fill` (`svc_regs`, `:421`).
  - The row lists only `svc_pc`, `svc_x18` and `qos_pending`.
- SetThreadActivity reads the target's `t->pt` after dropping `G` (`:1001`), and only checks `t->exited` once it holds `G` again (`:1002`).
  - Failure: if the target exits and its handle was already closed, `thread_exit` frees `t` (`:360`).
  - That makes the read a use after free, and `pthread_kill` then targets a finished detached pthread.
  - `lifetimes.md` and `locks.md` should carry this one.

New statements:
1. Line 136, `wake_sync_waiters` wakes only kind-4 waiters whose handle array holds `obj`: holds (`:563-569`).
   - The match is by object, so both ends of one event match.
   - The `!w->whs` fallback never fires, because WaitSynchronization sets `whs` before every `block(t, 4, …)` (`:1142`).
2. Line 114, `dm_guest_clock_advanced` signals every waiter under the deterministic clock: holds (`:572-577`). It is called from `dm_guest_frame_tick` (`hle_os.c:70`), on the presenting thread, at every NVN, GL and Vulkan present (`hle_nvn.c:1472`, `hle_gl.m:1930`, `hle_vk.m:1518`), and takes `G` there.
3. Line 248, QoS lending in ArbitrateLock: holds (`:1030-1033`). It applies only when the waiter's class is above the owner's and the owner is live (`o->pt && !o->exited`, `:1031`), and it ends when `block` returns, still under `G`.

### Re-check verdicts

- `agents/architecture/overview.md`: **approve with nits**. One wrong count remains in line 128, from this report's own O4: 6 delegating hooks, not 4, and `MountSystemData` (`:520`) belongs in the "do not" list. Everything else holds.
- `agents/architecture/host-threads.md`: **approve with nits**. Fix the same fs count in line 191, and add two rows to "Accesses outside `G`": `thr_svc_enter`'s `svc_regs` / `svc_state` stores (`:397`), and SetThreadActivity's `t->pt` read without `G` (`:1001`). The `dm_host_work` inventory is complete.
