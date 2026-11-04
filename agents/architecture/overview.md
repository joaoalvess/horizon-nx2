# Overview

Written against commit `b0d98ee7`. Every `file:line` below is at that commit.

The game's own ARM64 code runs natively in the host process. The rewriter has changed only the instructions Apple's kernel cannot run as Horizon does. Each `svc` and counter read goes through a gate into C. The host answers Horizon's SVCs, takes over the SDK's services at the `nn::` function level, and implements NVN, Vulkan and GL on Metal.

Other files of this folder:
- [host-threads.md](host-threads.md): guest threads, `G`, waits, handoffs, QoS.
- [nvn-pipeline.md](nvn-pipeline.md): one frame through the NVN layer.
- [lifetimes.md](lifetimes.md): object lifetimes.
- [nvn-state.md](nvn-state.md): the global state of the translation layer.
- [locks.md](locks.md): every lock and its order.

## Layers

| Layer | What it does | Where |
|---|---|---|
| Rewritten modules | The game's NSOs, rewritten offline. x18 becomes TSD slot K18, `tpidr_el0` becomes KTLS, `tpidrro_el0` becomes KTLR, `svc` and `mrs cntpct_el0` become gate blocks. Also: sp alignment, `ldxr` → `ldaxr` for unordered lock acquires, spin-wait gates, cuts, observation gates | `dm/tools/patch_nso.py:3-14` (header), `KEYS` at `:146` |
| Loader | Maps the images, creates the four TSD keys, writes the key page, resolves imports, registers gates, applies relocations, checks forced take-overs. It runs no guest code: the module inits run later from `guest_main`, on the guest main thread | `dm/host/loader.c:683-713` `load_modules`; `dm/host/main.c:35` |
| Gates | Save the guest registers on a per-thread gate stack, then call `gate_dispatch` | `dm/host/entry.S:41-159` `dm_gate_stubs`, `dm_gate`; `dm/host/hle.c:112-132` `gate_dispatch` |
| SVCs | Memory and info SVCs; thread and sync SVCs | `dm/host/hle_svc.c:455` `svc_dispatch`; `dm/host/hle_thread.c:913` `svc_thread` |
| HLE take-overs | Imports resolved by name to host functions | `dm/host/hle.h:7-51`; `dm/host/hle.c:51-79` `resolve_import` |
| Services | `nn::fs`, `nn::oe`, `nn::hid`, `nn::os`, `nn::vi`, `nv::`, init, libc | the `dm/host/hle_*.c` files, see [Services](#services) |
| NVN HLE | Every NVN entry point the game asks for, through counting thunks | `dm/gfx/nvn/hle_nvn.c`, `dm/gfx/nvn/nvn_thunks.S`, `dm/gfx/nvn/nvn_entry.S` |
| Metal layer | Replays recorded NVN commands into Metal 4 command buffers; pipelines, shaders, present | `dm/gfx/nvn/nvn_mtl.m`, `dm/gfx/nvn/nvn_rec.h` |
| Vulkan, GL | The same on classic Metal queues | `dm/gfx/vk/hle_vk.m`, `dm/gfx/gl/hle_gl.m` |
| Audio | AudioOut on an AudioUnit or a silent sink; the SDK's renderer on a host-made guest thread | `dm/host/hle_audio.c`, `dm/host/hle_audren.c` |
| Movies | `movie::` decoder take-over with host decoder threads | `dm/host/hle_movie.c`, `dm/host/hle_movie_avc.c`, `dm/host/hle_movie_av1.c` |
| Input | Front ends write pad state that `nn::hid` take-overs read | `dm/host/hle_hid.c`, `dm/host/dm_input.h` |
| Front ends | Window or view, layer, lifecycle, controllers | `dm/host/front_mac.m`, `dm/ios/Sources/front_ios.m`, `dm/ios/Sources/main.m` |
| Lifecycle | Focus, suspend, graceful exit | `dm/host/hle_lifecycle.c:9-29`; `dm/gfx/nvn/hle_nvn.c:1264-1272` `dm_gfx_suspend` |

## Boot

1. `main` (`dm/host/main.c:133-146`):
   - `:134` `mtl_pso_prebuild_tool`.
   - `:135` with `DM_PRELOAD`, `dm_host_preload_start` (`:126-132`) runs `host_preload` on `preload_thread` (`:117`, 8 MB stack). The iOS app starts it from its own `main`.
   - `:136-141` if it was started: join it, check that the arguments match, `:140` `crash_thread_init` for this thread.
   - `:142` otherwise `host_preload` on this thread. `:143` `dm_fps_state_apply`. `:144` `front_run(guest_main)`.
2. `host_preload` (`dm/host/main.c:65-115`):
   - `:78` `crash_install`; `:84-91` the `DM_TEST_KEYRACE` thread; `:92` `dm_term_install`; `:93` `crash_set_dump_hook(svc_thread_dump)`.
   - `:104` `load_modules`; `:105` `dm_cheats_init`; `:106` `dm_sdk_major`; `:108` `probe_install`; `:109` `hid_keys_init`; `:111` `stubs_report`; `:114` `dm_ue_malloc_install`.
3. `front_run` on the Mac (`dm/host/front_mac.m:1218`):
   - `:1220` `beginActivity` with latency-critical options. `:1221` `power_watch`, which only adds observers (`:1183-1190`).
   - `:1222` without `DM_WINDOW`: `guest()` runs on the calling thread, the process main thread.
   - Otherwise it builds the `NSApplication`, the window and the `CAMetalLayer` (`:1223-1238`) and adds the lifecycle observers (`:1318-1327`).
   - `:1334-1336` starts the guest pthread (64 MiB stack) on `guest_tramp` (`:326-331`: a 64 KB static alt stack, then `fn()`, then `exit(0)`). `:1337` `[NSApp run]` keeps the main thread.
4. On iOS:
   - `dm/ios/project.yml:24` compiles `main.c` with `-Dmain=dm_main`.
   - `dm/ios/Sources/main.m:198-203` `front_ios_boot` starts `boot_thread` (`:191-196`, 64 MiB), which calls `dm_main`. The preload thread starts at `:186`.
   - `dm/ios/Sources/front_ios.m:249` `front_run` calls `guest()` directly.
5. `guest_main` (`dm/host/main.c:18-41`), on the guest main thread:
   1. `:19` `guest_thread_init`; `:20` `guest_gate_stack(0)`; `:21` `dm_oodle_serve_maybe(0)`.
   2. `:22` `svc_thread_main_init`: registers the main thread, handle 0x1001.
   3. `:25` `_init_libc0`; `:26` `nnosInitialize(hmain, 0)`; `:27` `_init_libc1`; `:28` `nninitInitializeSdkModule`.
   4. `:31-32` `SetHostArgc` / `SetHostArgv`; `:33` `nninitStartup`; `:34` `_init_libc2`; `:35` `run_module_inits`.
   5. `:36` `dm_guest_spawn_selftest`; `:37-38` oodle serve and job modes.
   6. `:39` `nnMain`.

## Modules and imports

| Step | What happens | Where |
|---|---|---|
| Module table | `g_mod`, `g_loaded`, the rwlock `g_modules_mu`, the four key globals | `dm/host/loader.c:14-19`; `dm/host/dm.h:47-76` `module_t`, `:83` keys |
| Keys | `create_keys` makes K18, KTLS, KTLR and KGATE; `tsd_check` checks them | `dm/host/loader.c:32-36`, `:39-45` |
| Key page | Holds key number × 8 for each of the four keys, then is made read-only. Rewritten code reads its TSD slot through it, so the loader may use any key number | `dm/host/loader.c:311-320` `install_key_page`; `dm/tools/patch_nso.py:14`, `:145` |
| Mapping | Mac: copy the image, then seal text and the patch area R+X. iOS: `vm_remap` of sections embedded in the app | `dm/host/loader.c:647-677`, `:571-635` `map_image` |
| Imports | Loaded modules first, then `resolve_import`: an `HLE` entry (wrapped by `hlecount_wrap`), else a named stub | `dm/host/loader.c:203-206` `resolve_sym`; `dm/host/hle.c:51-79` |
| Forced take-overs | `HLE_FORCE` entries override definitions inside the modules | `dm/host/loader.c:211` `force_init`, `:235` `force_check` |
| Unimplemented | 4096 stubs that log `UNIMPL` once each | `dm/host/entry.S:8-32`; `dm/host/hle.c:9-21` `unimpl_c` |
| Gates | `<name>.gates.tsv` from the rewriter, keyed by the gate block's return point | `dm/host/loader.c:321-332` `register_gates`; `dm/host/hle.c:100-108` `gate_register` |
| Inits | Module init arrays, run from `guest_main` | `dm/host/loader.c:717-724` `run_module_inits` |

The take-over kinds (`dm/host/hle.h`):

| Macro | Section | Effect | Where |
|---|---|---|---|
| `HLE` | `__DATA,swhle` | Resolves an import by name | `:7-10` |
| `HLE_FORCE` | `__DATA,swforce` | Overrides a module definition; a reason string is required | `:36-40` |
| `HLE_FORCE_BIG` | `swforce` | The same, through a compile-time stub that runs the body on a 512 KB host stack | `:43-49`; `dm/host/hle_bigstack.c:42-89` |

## Gates and SVCs

1. The gate block (`dm/tools/patch_nso.py:383-399` `emit_gate_call`, `site_gate`):
   1. `stp x29,x30,[sp,#-16]!`.
   2. `mrs x30, tpidrro_el0`, then the KGATE slot address from the key page, then `ldr x30` of that slot. x29 is borrowed and restored.
   3. `blr x30`, then `ldp`, then a branch back past the original instruction.
   4. The block's return point goes into `gates.tsv` with its kind and argument.
2. The KGATE slot holds gate stub `k` (`dm/host/thread.c:74`). Each stub is 16 bytes (`dm/host/entry.S:41-49`): `mov x29,x30`; load `dm_gate_top[k]` into x30; `b dm_gate`.
3. `dm_gate` (`dm/host/entry.S:59-159`):
   - Builds an 800-byte frame at the top of the gate stack: x0..x28, q0..q31 at +256, nzcv / fpsr / fpcr at +768 / +776 / +784, the guest x29 and return point at +232 / +240, the block's sp at +792.
   - `:102-110` dies through `dm_gate_nested` if it is already on its gate stack.
   - `:111-115` `mov sp,x30`, `bl gate_dispatch`.
   - `:116-159` restores everything except x18 and returns on the block's sp.
4. `gate_dispatch` (`dm/host/hle.c:112-132`) looks the return point up in a hash of `GATE_BITS` 15 (`:95-96`):

   | Kind | Action | Line |
   |---|---|---|
   | `G_CNTPCT`, `G_CNTVCT` | `guest_clock_read_wait`, then `guest_ticks` into the target register | `:116-121` |
   | `G_OBS` | The attached observation callback, if any | `:122` |
   | `G_SPIN` | `thr_svc_enter`, `dm_spin_wait`, `thr_svc_leave` | `:123-125` |
   | `G_SVC` | `thr_svc_enter`, `svc_dispatch`, `thr_svc_leave` | `:126-128` |

5. `svc_dispatch` (`dm/host/hle_svc.c:455-458`): `hlecount_svc`, `mem_init`, then `svc_thread` (`:458`) before its own `switch` (`:459`). `svc_thread` (`dm/host/hle_thread.c:913-925`) runs the same-core handoff check at every SVC boundary: after the body of a thread or sync SVC, but before the body of any other SVC, since `svc_thread_impl` returns 0 for those. Spin and counter gates never reach it (`dm/host/hle.c:116-125`). See [host-threads.md](host-threads.md#same-core-handoffs).
6. The SVCs `hle_svc.c` answers itself:

   | SVC | Line | Notes |
   |---|---|---|
   | 0x01 SetHeapSize | `:460` | |
   | 0x02 / 0x03 | `:491` | permission and attribute stubs |
   | 0x04 MapMemory, 0x05 UnmapMemory | `:498`, `:517` | |
   | 0x06 QueryMemory | `:531` | |
   | 0x2C / 0x2D Map / UnmapPhysicalMemory | `:605` | |
   | 0x26 Break | `:664` | `_exit(42)` unless only a notification |
   | 0x1E GetSystemTick | `:673` | |
   | 0x27 OutputDebugString | `:674` | |
   | 0x29 GetInfo | `:678` | core mask 7; free thread count 96 − `thr_limit_used` (`:703`) |
   | any other | `:719-721` | logged once, returns success as a placeholder |

7. Guest memory: `mem_init_once` (`dm/host/hle_svc.c:42-71`) reserves the guest address space. The alias region sits at `g_as + 0x10000000`, then stacks, then heap (`:58-62`). Locks: `g_map_lock` (`:102-110`), `g_rgn_lock` (`:319`). See `docs/reference/memory.md`, "Partitioning the guest block between alias region, stacks and heap".

## Services

All take over `nn::` functions directly; none go through IPC. See `docs/reference/services.md`, "SDK calls that open a system service through sm" and "Game-linked HIPC clients of system services".

| Area | What | Where |
|---|---|---|
| File system | Mounts and file calls. The rom, save and device-save mounts, the commits, and the file and directory hooks call `dm_thread_service_request`: 25 directly, 6 through the hook they delegate to (`:722`, `:724`, `:1030`, `:1032`, `:1038`, `:1041`). The add-on-content, system-data, temporary and cache-storage mounts (`:497`, `:520`, `:554`, `:564`, `:567`, `:570`), the cache list hooks, and the size, query and no-op hooks do not | `dm/host/hle_fs.c:1-6`; callers at `:436`, `:600`, `:614`, `:685`, `:699`, `:728`, `:757`, `:799`, `:820`, `:826`, `:835`, `:836`, `:843`, `:853`, `:854`, `:878`, `:882`, `:903`, `:921`, `:923`, `:924`, `:980`, `:1006`, `:1024`, `:1043` |
| oe | Notification queue and its event; `PopNotificationMessage` waits as a native wait | `dm/host/hle_oe.c:223-251`; native wait `:241-243` |
| os clock | Guest clock: `guest_ns`, `guest_ticks` (31.25 or 19.2 MHz), `dm_guest_frame_tick`, freeze reasons, `guest_clock_read_wait` | `dm/host/hle_os.c:44-104` |
| os objects | `objmap` | `dm/host/hle_os.c:7-38` |
| System events | Service events bound to kernel events made by the SDK | `dm/host/hle_thread.c:1180-1261` |
| Init | SDK init take-overs | `dm/host/hle_sdkinit.c:1-15` |
| libc | Passthrough table | `dm/host/hle_table.c:7-14` |
| vi | Static display and layer objects | `dm/gfx/hle_vi.c` |
| vi vsync (SDK 16) | `GetDisplayVsyncEvent` starts a vsync thread | `dm/host/hle_sdk16.c:276-289` |
| nv | `nv::` take-overs that record the allocator and the pool | `dm/gfx/hle_nv.c` |
| Input | `nn::hid` take-overs | `dm/host/hle_hid.c:499-527` |

## NVN HLE

1. `nvnBootstrapLoader` is an `HLE_FORCE` that returns `nvn_lookup(name)` (`dm/gfx/nvn/hle_nvn.c:111-113`; lookup at `:103`). `nvnDeviceGetProcAddress` is at `:134`. The SDK's NVN driver never runs.
2. Each entry point goes through a counting thunk: `stadd` on its counter, then a branch to its slot (`dm/gfx/nvn/nvn_thunks.S`, generated).
3. Every implemented function except `nvnCommandBuffer*` runs through `nvn_big_entry` on the big host stack (`dm/gfx/nvn/hle_nvn.c:1332-1337`; `dm/gfx/nvn/nvn_entry.S:79-91`).
4. Command buffers record into game memory (`dm/gfx/nvn/hle_nvn.c:925-935`).
5. `nvnQueueSubmitCommands` (`dm/gfx/nvn/hle_nvn.c:1278-1300`):
   1. `dm_host_mutex_lock(&g_sub_mu)`.
   2. `mtl_prepare` inside `dm_host_work`.
   3. `gfx_enter`.
   4. `mtl_queue_activate`, `nvn_cap_submit`, `mtl_sub_begin`, `nvn_ft_poll`, `mtl_sub_index`.
   5. `mtl_exec_rest` and `mtl_exec` per handle.
   6. `mtl_sub_commit`, unlock, `gfx_leave`.
6. Sync and finish:
   - `nvnQueueFenceSync` (`:726`) marks the sync object fenced.
   - `nvnSyncWait` (`:737-744`) calls `mtl_wait` or `mtl_wait_acq` without `dm_host_work`.
   - `nvnQueueFlush` (`:790`) does nothing. `nvnQueueFinish` (`:791`) calls `mtl_finish`.
7. `nvnWindowAcquireTexture` (`:1404-1425`) paces the game:
   - It sets the time-constraint policy on the calling thread (`:1411`).
   - It waits through `link_wait` or `sleep_until_ns`.
8. `nvnQueuePresentTexture` (`:1896-1928`): `gfx_enter` at `:1922`; `mtl_present` only enqueues.
9. The graphics gate (`:1254-1272`):
   - `gfx_enter` waits while `g_susp` is set, counts `g_inflight_api`, then `dm_host_work++`. `gfx_leave` undoes it.
   - `dm_gfx_suspend(1)` waits for in-flight calls, then drains Vulkan, GL and Metal.

The full frame path is in [nvn-pipeline.md](nvn-pipeline.md).

## Metal layer

| Part | What | Where |
|---|---|---|
| Init | `mtl_init`. `DM_PRESENT_LINK` defaults to 1. `g_q` is a classic queue. Also a residency set, the feedback queue `dm.nvn.mtl4-feedback` (serial, user-interactive), `g_q4`, a classic fallback, allocators, `g_ev` | `dm/gfx/nvn/nvn_mtl.m:391-477`; `:394-395`, `:402`, `:410-414`, `:416-419`, `:424-430`, `:442-458`, `:471` |
| Submission owner | `g_sub_thread` and `on_sub_thread`; `up_owner_check` | `:783-792` |
| Begin | `mtl_sub_begin` dies with "submit re-entered" and sets `g_sub_thread` | `:812-830` |
| Commit | `mtl_sub_commit`: feedback handlers, `rec_commit`, `rec_signal`, `rec_drain` | `:1602-1652` |
| Completion | `post_complete` reads `g_done` without a lock (`:1590`), claims each fence's record with `post_claim` (`:1592`) and runs `post_run` with no lock held. It takes `g_mu` only to raise `g_done` and broadcast `g_cv` (`:1600`). Two callers on different threads: the commit feedback handler on `dm.nvn.mtl4-feedback` (`:1632`), and the waiting game thread through `post_early` (`:1656-1658`) from `mtl_wait_at` (`:1664`). `g_done` is also read without the lock at `:825` and `:1660` | `:1588-1601` |
| Waits | `mtl_wait_at` on `g_ev`, or on `g_cv` under `g_mu`; `mtl_wait`, `mtl_wait_acq`, `mtl_drain`, `mtl_finish` | `:1659-1690`, `:1687-1688`, `:1703`, `:1700` |
| Replay | `mtl_exec` | `:11719` |
| Encode thread | Optional; replays recorded Metal calls off the submitting thread | `dm/gfx/nvn/nvn_rec.h:80-90` `rec_on`, `:179-194` `rec_thread` |
| Uniform copies | `dm-ub-copy` thread | `dm/gfx/nvn/nvn_rec.h:24-60` |

## Present

1. `mtl_present` and `mtl_present_ext` (`dm/gfx/nvn/nvn_mtl.m:12845`, `:12854`) call `present_enqueue` (`:12970-12997`):
   - `:12978` `pthread_once(present_start)`.
   - `:12979` `link_sync`.
   - `:12992-12996` pushes the item under `g_pq_mu`.
2. Classic mode: `present_main` (`:12812-12836`, thread `nvn-present`, user-interactive) waits on `g_pq_cv` while the queue is empty or `g_link_owns_layer` is set (`:12819`); in display-link mode it takes no items. For each item it takes, it calls:
   - `ext_wait(it.ev_val)` (`:12824`; `:12626`): a GPU-side `[g_q4 waitForEvent:value:]` on the external producer's event, for Vulkan and GL frames only;
   - `snap_commit_wait(it.snap_v)` (`:12889`): a CPU wait, through `rec_note_wait` (`dm/gfx/nvn/nvn_rec.h:103-106`), until the encode thread has committed the snapshot copy;
   - then `present_now` (`dm/gfx/nvn/nvn_mtl.m:12494`).

   It does not wait for NVN fences on the CPU.
3. Display link mode: `link_sync` (`:12756-12795`) starts `link_main` (`:12739-12755`, thread `nvn-present-link`, user-interactive). `link_main` waits for the classic thread to finish its frame, attaches a `CAMetalDisplayLink`, and runs `CFRunLoopRun`. The delegate callback (`:12654-12700`) takes the frames.
4. Snapshots: `:12873-12905`. `mtl_present_wait` is at `:13004`. Suspend drops queued frames: `present_drop_for_suspend` (`:12799`).
5. Vulkan presents through `mtl_present_ext` (`dm/gfx/vk/hle_vk.m:1521-1530`); GL does the same in `eglSwapBuffers` (`dm/gfx/gl/hle_gl.m:2001-2021`, `mtl_present_ext` at `:2010`).

Findings on this path: `docs/reference/frame-rate.md`, "Present thread rescues a silent display link" and "One frame per tick of a 120 Hz display link".

## Vulkan and GL

| Layer | Queue | Gate | Where |
|---|---|---|---|
| Vulkan | Classic queue labelled `vk` (`dm/gfx/vk/hle_vk.m:164-165`) | `dm_gfx_enter` / `dm_gfx_leave` around submit (`:1367`, `:1397`) and present (`:1521`, `:1530`) | `dm/gfx/vk/hle_vk.m:1-12` |
| GL | Classic queue labelled `gl` (`dm/gfx/gl/hle_gl.m:201-202`) | The same, around commits (`:623`, `:1203-1204`, `:1356`, `:1531`, `:1652-1661`) and `eglSwapBuffers` (`:2003-2021`) | `dm/gfx/gl/hle_gl.m` |

## Audio

| Part | What | Where |
|---|---|---|
| AudioOut | Each output plays through an AudioUnit or a silent sink | `dm/host/hle_audio.c:1-4` |
| AudioUnit setup | Runs on a pthread that `dm_host_thread_join` joins | `:243-248` `au_open` |
| Render callback | `au_render`, called by Core Audio on its own thread (unverified) | `:151` |
| Silent sink | `null_sink` thread; start and stop | `:251-263` |
| Release notify | `event_notify`, one thread per AudioOut | `:71-89`, created at `:393` |
| Stream sink | `stream_sink` | `:280-300`, started at `:615` |
| Watchdog | `au_watchdog` | `:339-366` |
| Start / Stop / Close | `HLE_FORCE_BIG` take-overs | `:438`, `:464`, `:484` |
| Renderer | `render_main` on a host-made guest thread, priority 9, 64 KB stack. It runs the SDK's `ExecuteAudioRendererRendering` and paces on the output's released blocks | `dm/host/hle_audren.c:96-118`, spawned at `:203`, joined at `:210-216`; wait at `dm/host/hle_audio.c:564` |

See `docs/reference/audio.md`, "Running the SDK's own renderer on the CPU" and "AudioOut release notification can sleep with pending work".

## Movies

| Part | What | Where |
|---|---|---|
| Deferred work | `md_defer_body` on a host-made guest thread, priority 16, 64 KB | `dm/host/hle_movie.c:160-180`, spawned at `:165` |
| Decoder | `md_worker` (`dm movie decoder`, user-initiated), a 1 MB pthread per decoder | `:427-445`, created at `:533-535` |
| Decode and defer locks (`d->dmu`, `g_dfmu`) | Taken with `dm_host_lock` | `:164`, `:173`, `:180`, `:459`, `:559`, `:615`, `:632`, `:648` |
| Decoder state locks (`d->mu`, `d->wmu`) | Taken with `dm_host_mutex_lock` from guest-thread take-overs: `md_job` (`:452`), `md_pump` (`:461`, `:467`, `:490`), Configure (`:594`), Start (`:608`), `md_reset` (`:618`), AcquireInputBufferIndex (`:656`), SendInputBufferForDecode (`:687`), AcquireOutputBufferIndex (`:717`), `md_out_tex` (`:815`), `md_rel` (`:857`). `md_worker` takes `d->wmu` the same way (`:431`, `:443`), on a host thread | `dm/host/hle_movie.c:46` |
| VideoToolbox | Output callbacks, on threads VideoToolbox picks (unverified) | `dm/host/hle_movie_avc.c:120`, `:141-142`; `dm/host/hle_movie_av1.c:115`, `:137-138` |

See `docs/reference/movies.md`, "`movie::Decoder` taken over as a MediaCodec-style protocol".

## Input

1. Mac: GameController `valueChangedHandler` blocks (`dm/host/front_mac.m:192`, `:214`) write pad state through the setters in `dm/host/dm_input.h:14`, `:25-27`. The handler queue is GameController's default (unverified).
2. iOS: `dm/ios/Sources/DmGamepad.m:56`, `:96-97` take CoreMotion updates on an `NSOperationQueue` with one operation at a time.
3. The game reads the state through the `nn::hid` take-overs (`dm/host/hle_hid.c:499-527`; `GetNpadStates` at `:515-519`).
4. Scripted input: `DM_KEYS` (`hid_keys_init`, `:195-204`), `DM_CTL` (`:258-261`), `DM_REC` (`:421-424`).
5. Text input: `front_text_input` (`dm/host/front_mac.m:1376-1380`) blocks the calling guest thread on `dispatch_sync` to the main queue.

## Lifecycle

| Event | Action | Where |
|---|---|---|
| Window resigns key | `input_release`; focus 2 if not minimized | `dm/host/front_mac.m:1324` |
| Window becomes key | `input_resume`; focus 1 | `:1325` |
| Minimize | `input_release`, focus 3, `dm_audio_suspend(1)`, `dm_gfx_suspend(1)` | `:1326` |
| Restore | `dm_gfx_suspend(0)`, `dm_audio_suspend(0)`, focus 2 | `:1327` |
| SIGTERM | A GCD signal source calls `dm_host_shutdown`. That arms a 1.5 s `_exit` fallback, flushes counters, `DM_REC` and cheats, suspends audio and graphics, then calls `_exit(0)` | `dm/host/hle_lifecycle.c:9-29` |

Focus changes reach the game through the oe notification queue (`dm/host/hle_oe.c:14-18`). See `docs/reference/threads.md`, "The oe notification event and its queue", and `docs/reference/nvn-objects.md`, "Going to the background during the prepare step".

## Threads

Guest threads are pthreads registered in `hle_thread.c`; [host-threads.md](host-threads.md) covers how they wait. Host threads never enter guest code, except those made with `dm_guest_thread_spawn`.

| Thread or queue | Started by | Runs | QoS | Kind |
|---|---|---|---|---|
| Process main thread, Mac with `DM_WINDOW` | the process | `main`, then `[NSApp run]` (`dm/host/front_mac.m:1337`) | default (unverified) | host |
| Process main thread, Mac without `DM_WINDOW` | the process | `main`, then `guest()` (`dm/host/front_mac.m:1222`): the guest main thread | set by `qos_apply` (`dm/host/hle_thread.c:524`) | guest main, handle 0x1001 |
| Preload | `dm_host_preload_start` (`dm/host/main.c:126-132`) | `preload_thread`, 8 MB stack; joined in `main` | inherited (unverified) | host |
| iOS boot | `front_ios_boot` (`dm/ios/Sources/main.m:198-203`) | `dm_main`, 64 MiB stack; becomes the guest main thread | set by `qos_apply` (`dm/host/hle_thread.c:524`) | guest main |
| Mac guest main | `front_run` (`dm/host/front_mac.m:1334-1336`) | `guest_tramp` → `guest_main`, 64 MiB stack | set by `qos_apply` | guest main, handle 0x1001 |
| Game threads | SVC 0x08 (`dm/host/hle_thread.c:930-947`) | `thread_main` → `dm_thread_enter`; 1 MB detached pthread | by priority, see [host-threads.md](host-threads.md) | guest |
| Audio renderer | `dm_guest_thread_spawn` (`dm/host/hle_audren.c:203`), through the SDK's `CreateThread`, so SVC 0x08 (`dm/host/hle_guestthread.c:28`) | `render_main` | by priority 9, like a game thread (`dm/host/hle_thread.c:330`) | guest, host-owned |
| Movie deferred work | `dm_guest_thread_spawn` (`dm/host/hle_movie.c:165`), the same way | `md_defer_body` | by priority 16, like a game thread | guest, host-owned |
| Movie decoder | `dm/host/hle_movie.c:535` | `md_worker`, 1 MB | user-initiated under `DM_QOS_MAP` (`:430`) | host |
| AudioUnit setup | `au_open` (`dm/host/hle_audio.c:246`) | `au_create_th`; joined at once | inherited | host |
| Audio notify | `dm/host/hle_audio.c:393` | `event_notify`, one per AudioOut | user-interactive under `DM_QOS_MAP` (`:72`) | host |
| Silent sink | `null_start` (`dm/host/hle_audio.c:262`) | `null_sink` | user-interactive under `DM_QOS_MAP` (`:252`) | host |
| Stream sink | `dm/host/hle_audio.c:615` | `stream_sink` | user-interactive under `DM_QOS_MAP` (`:281`) | host |
| Audio watchdog | `au_watchdog_start` (`dm/host/hle_audio.c:366`) | `au_watchdog` | inherited | host |
| Core Audio IO | Core Audio | `au_render` (`dm/host/hle_audio.c:151`) | real-time (unverified) | system |
| Vsync (SDK 16) | `GetDisplayVsyncEvent` (`dm/host/hle_sdk16.c:284`) | `vsync_thread` (`:259-268`), which follows `mtl_link_wait_vsync` | user-interactive under `DM_QOS_MAP` (`:261`) | host |
| Present | `present_start`, once (`dm/gfx/nvn/nvn_mtl.m:12837`, `:12978`) | `present_main`, `nvn-present` | user-interactive (`:12815`) | host |
| Display link | `link_sync` (`dm/gfx/nvn/nvn_mtl.m:12786`) | `link_main`, `nvn-present-link`, `CFRunLoopRun` | user-interactive (`:12742`) | host |
| Encode | `rec_put`, first record (`dm/gfx/nvn/nvn_rec.h:207-209`) | `rec_thread`, `dm-encode`, 1 MB | user-interactive (`:181`) | host |
| Uniform copy | `ubc_push`, first push (`dm/gfx/nvn/nvn_rec.h:53`) | `ubc_thread`, `dm-ub-copy`; spins 2000 times, then waits on `g_ubc_cv` | user-interactive (`:25`) | host |
| Metal feedback | `mtl_init` (`dm/gfx/nvn/nvn_mtl.m:416-417`) | serial queue `dm.nvn.mtl4-feedback` | user-interactive | GCD |
| Completion handlers | Metal | handlers at `dm/gfx/nvn/nvn_mtl.m:1537`, `:3632`, `:8665`, `:11939`, `:11950`, `:12526`; `dm/gfx/gl/hle_gl.m:264`; `dm/gfx/vk/hle_vk.m:1386`; `rt_range_check.inc:53` | Metal's choice (unverified) | system |
| Shared-event listener | `MTLSharedEventListener` block on `g_ev` at `g_fence` (`dm/gfx/nvn/nvn_mtl.m:916-918`) | `gp_report` | the listener's queue (unverified) | system |
| Pipeline archive | `pso4_init` (`dm/gfx/nvn/nvn_mtl.m:6580-6593`) | `dm.nvn.pso-archive` serial queue; old archives on the global utility queue | utility | GCD |
| Background pipelines | `dm/gfx/nvn/nvn_mtl.m:6836` | `dm.nvn.pso-bg` serial queues | utility | GCD |
| Speculative pipelines | `pso_pend_kick` (`dm/gfx/nvn/nvn_mtl.m:6871-6876`) | global queue | user-initiated | GCD |
| Pipeline prebuild | `pso_prebuild` (`dm/gfx/nvn/nvn_mtl.m:7083`, groups at `:7111`, `:7137`) | global queue | caller's choice | GCD |
| Amplified pipelines | `sm_amp_get` (`dm/gfx/nvn/nvn_mtl.m:7177-7184`) | global queue | utility | GCD |
| Prepare workers | `prepare_workers` (`dm/gfx/nvn/nvn_mtl.m:7432-7442`) | global queue group | user-initiated | GCD |
| Warm start | `warm_start` (`dm/gfx/nvn/nvn_mtl.m:7478`, queue at `:7511`) | `dm.nvn.pso-warm` serial queue | user-initiated (`:7510`) | GCD |
| Shader prefetch | `shader_prefetch_rest` (`dm/gfx/nvn/nvn_mtl.m:8513`, `dispatch_apply` at `:8537`); `mtl_prog_prefetch` (`:10806`); `nvn_geometry.inc:423` | GCD | (unverified) | GCD |
| VideoToolbox output | VideoToolbox | movie decode callbacks | (unverified) | system |
| SIGTERM source | `dm_term_install` (`dm/host/hle_lifecycle.c:26`) | `dm_host_shutdown` | user-initiated global queue | GCD |
| Exit fallback | `dm_host_shutdown` (`dm/host/hle_lifecycle.c:13`) | `_exit(0)` after 1.5 s | user-interactive global queue | GCD |
| Crash watchdog | `crash_install` with `DM_WATCH` or `DM_WATCH_STALL` (`dm/host/crash.c:208`) | `watchdog_main`, 250 ms loop (`:42-60`) | inherited | host |
| Hitch dump | `hitch_init` with `DM_HITCH_DUMP` (`dm/host/hle_thread.c:506-510`) | `hitch_main` | inherited | host |
| Memory diagnostics | `mem_init_once` (`dm/host/hle_svc.c:68`, `:70`) | `alias_windows_thread`, `regions_thread` | inherited | host |
| Probes | `dm/host/probe.c:351`, `:358` | `poll_run`, `watch_arm` | inherited | host |
| Memory and CPU stats | `dm/host/memstat.m:112`, `:154` | `memstat_thread`, `thrcpu_thread` | inherited | host |
| Descriptor stats | `dm/host/hle_fdstat.c:37` | `fdstat_main` | inherited | host |
| Scripted input | `dm/host/hle_hid.c:203`, `:260`, `:423` | `keys_main`, `ctl_main`, `rec_main` | inherited | host |
| oe script | `oe_script_start` (`dm/host/hle_oe.c:212`) | `oe_script` | inherited | host |
| Cheats | `dm/host/hle_cheats.c:1074`, queue at `:1098` | `cheat_tick_thread` (about 60 Hz); `nxnative.cheats.files` serial queue | inherited | host, GCD |
| Cheat file scan | `dm/host/front_mac.m:853` | `found_cheat_files` | user-initiated global queue | GCD |
| Save sync | `dm/host/save_sync.c:376`, `:510` | `fetch_thread`, `sender` | inherited | host |
| iOS save flush | `save_sync_background` (`dm/ios/Sources/front_ios.m:339`) | `save_sync_flush` | utility global queue | GCD |
| iOS romfs cleanup | `dm/ios/Sources/main.m:66` | deletes the old romfs | background global queue | GCD |
| Stream | `dm/host/stream_mac.m:588`, `:616-617`, `:650`, `:653` | `st_reader`; `dm.stream.encode` (user-interactive) and `dm.stream.write` (user-initiated) queues; `st_link`; the pad timer | as listed | host, GCD |
| Rumble | `dm/host/haptics_apple.m:397` | `dm.rumble` serial queue | default (unverified) | GCD |
| Motion | `dm/host/motion_apple.h:16`; `dm/host/motion_pro_mac.h:70-72` | GCMotion handler; IOHID on the main run loop | (unverified) | system |
| Key race test | `DM_TEST_KEYRACE` (`dm/host/main.c:84-91`) | `keyrace_thread` | inherited | host |

Per-thread host state (TSD keys, gate stacks, big stacks, alt stacks, sleep kqueues) is listed in [host-threads.md](host-threads.md#per-thread-host-state).
