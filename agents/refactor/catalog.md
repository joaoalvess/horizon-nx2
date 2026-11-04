# Catalog

Findings from five read-only reviews (2026-11-04):
- `nvn_mtl.m` 1-4700;
- `nvn_mtl.m` 4700-9800;
- `nvn_mtl.m` 9800-13110 with `nvn_geometry.inc` and `nvn_rec.h`;
- `hle_nvn.c` with the texture code;
- the host core.

An independent adversarial review of the plan and catalog followed.

How to read the tables:
- **Costs** are estimates at hot clock from `round2/cpu.md`'s unit costs. None is measured, and several overlap.
- **Line numbers** are in `dm/gfx/nvn/nvn_mtl.m` unless another file is named.
- **Checked**: `read` means read at the cited lines by the main thread; `review` gives the adversarial review's verdict; `agent` means only the finding agent's word.
- **State**: `pending`, `committed <hash>`, `reverted (<reason>)` or `dropped (<reason>)`. The main thread sets it; it is the only record of an item's state.

## Tools (found during S0)

| ID | Item | Where | Cost (estimate) | Risk | Checked | Stage | State |
|---|---|---|---|---|---|---|---|
| R1 | Replay CPU cannot be measured: `/usr/bin/time` totals are dominated by applying the captured state (~500 ms a replay) and `submit CPU` is wall time. `nvn_replay` prints the replay thread's `submit instructions` and the process's over the submit span | `dm/gfx/tests/nvn_replay.m` | none (tool) | none: the replay is unchanged | review: approve with nits | S0 | committed (`test(replay): count the instructions of the submit`); review `reports/20261104-0522-R1-review.md` |
| R2 | `DM_NVN_CAPTURE` cannot read back ASTC textures (`cap_pf_block` knows plain and BC formats only), so DK captures replay magenta | `dm/gfx/nvn/nvn_capture.inc:220-228` | none (tool) | low: capture only | search `reports/20261104-0510-R2-search.md`; review: approve with nits | S0 | committed (`fix(capture): read back ASTC textures`); review `reports/20261104-0530-R2-review.md` |

| R3 | `nvn_replay` links the weak `dm_sdk_ounce()` (`hle_nvn.c:184`, returns 0) and the capture records no Switch 2 flag, so replays deswizzle Switch 2 textures with Switch 1's GOB order (`nvn_gob_switch2` stays 0) and skip the NVN2 dispatch dims in c0. Found by the capture subagent on Pokopia's SSAO noise texture (ser 8175) | `dm/gfx/nvn/hle_nvn.c:127`, `:184-185`; capture files; `nvn_replay.m` | none (tool) | low: replay only | capture subagent: proven on Pokopia | S0 | implementing |

## Build

| ID | Item | Where | Cost (estimate) | Risk | Checked | Stage | State |
|---|---|---|---|---|---|---|---|
| B1 | `-O1` without LTO; change to `-O2` with ThinLTO | `dm/host/Makefile:18`, `dm/gfx/tests/Makefile:14`, `dm/host/tests/Makefile` | unknown; all host code | exposes UB; `__builtin_return_address` under inlining; slower test builds | read; review: holds | S1 | committed (`build(host): build at -O2 with ThinLTO`); review approve with nits (`reports/20261104-0458-B1-review.md`); replay CPU pending R1 |

## Per draw

| ID | Item | Where | Cost (estimate) | Risk | Checked | Stage | State |
|---|---|---|---|---|---|---|---|
| C1 | `arena_alloc` returns a `__strong` buffer, and every caller sends `contents`. `sh->ab_buf` is a strong store used only as a flag. `bind_args` ignores its `ab` / `off`. Keep a `cpu` pointer in `NvArena` and return offsets | 5377, 8210-8213, 7771 | 35-180 ns per allocation × ~980 encodes a frame: 0.05-0.3 ms | low (shared buffers never move while live) | read | S2 | pending |
| C2 | Per-draw scans of immutable binding lists. Compute per-stage masks once per program: `prog_swrites` (writable IMG / SBUFP / GMEM), `udc_note_draw` (adds SBUFU and any IMG), `order_note` (stages 1-5), `image_prepare` (IMG rw/atom, reg < 32) | 5566-5611, 7701-7707 | 0.1-0.3 ms. `draw_samples_rt` runs only on continued / slice-merged passes and `sm_plan` | low (`rf` is filled once, in `shader_load` 4592) | review: holds, caveats | S4 | pending |
| C3 | `fb_prepare` locks `g_rmu` once per fragment texture binding | 9852-9855 | 0.1-0.3 ms | low | read | S2 | pending |
| C4 | `draw_samples_rt` locks `g_rmu` and copies a 128 B `tex_t` per binding | 8786-8830 | continued passes only | medium: one lock across the loop nests `g_vp_mu` (`nvn_sparse_alias`, 8783) under `g_rmu` | review: holds, caveat | S2b | pending |
| C5 | `vconv_bind` scans 16 formats linearly per vertex input. Use a 256-entry table | 5758, 5867, 5974 | a few hundred instructions a draw | low; the table must cover every enum value the scan handles | agent | S2 | pending |
| C6 | Strong ObjC locals in the per-draw path cost a retain / release each. Make them `__unsafe_unretained`, but keep `en` strong | 7705, 9843, 10410, 10445, 10851 | 0.05-0.15 ms | low: shaders stay in `g_shcache` for good, programs go through `defer_obj_release` | review: holds | S2 | pending |
| C7 | `cp_on` reads a `_Thread_local` on every profiled call site, even with profiling off | 141 | 15-50 µs | none | read | S2 | committed (`perf(nvn): read the CPU-profile switch without a thread-local`); review approve (`reports/20261104-0647-C7-review.md`); measured: 12 instructions fewer per check, ~800-4,600 checks a frame, not resolvable in replay CPU |
| C8 | The `tex_by_id` slow path does work twice: `tex_cpu_written` twice, `treg_tex` twice on a stale view, a 280 B `treg_t` copy, and `gpuResourceID` sent again in `tex_rid_` | 5094-5101, 5299 | 25-100 µs | low | read | S2 | pending |
| C9 | `mtl_reg_samp` has no same-descriptor early out (`mtl_reg_tex` has one), so every re-registration releases both sampler states and bumps `g_reg_gen` | 5048-5061 | game-dependent; one bump re-encodes every argument block | low (`samp_par` is 40 B with no padding) | read | S2 | pending |
| C10 | `prog_get` publishes plain programs through `serial_put`, which bumps `g_ser_gen`; `prog_serial_put` does not | 4796, 1831-1834 | hitches at scene changes | low: `prog_get` only publishes a serial with no entry (4769-4770), and `hm_put_id` releases a replaced value anyway (1733) | read; review | S2 | pending |
| C11 | In the PSO stand-in phase, each draw builds a 352 B key, misses two hash maps and runs a 384-entry `memcmp` scan under `g_pp_mu` | 6804-6901, 10553 | 1-2 µs a draw in warm-up frames | medium; the corpus cannot check it (captures run with `DM_PSO_HYBRID=0`) | review: holds | S2b | pending |
| C12 | Small message sends: `tbuf_shadow` (~6 before its early return), `textureType` per TEX binding, `args_sync_dirty` per `encode_args`, `treg` hot fields split over two cache lines | 7592, 8029, 7764, 5296 | < 50 ns each a draw | low | agent | S2b | pending |
| C13 | Program binds call `args_dirty_all`. Dirty stage `st` only when `pr->sh[st]` changed (graphics). The compute half saves nothing: stage 5 never reuses, and a dispatch ends the pass | 8444-8446, 7946 | not supported by any count | low-medium | review: holds, caveat | S2b | pending |

## Per pass / submission

| ID | Item | Where | Cost (estimate) | Risk | Checked | Stage | State |
|---|---|---|---|---|---|---|---|
| P1 | `cs_hoist_try` copies `S` / `R` twice and runs `csh_draw_reads` at every pass open. Prefilter on op headers through `fz_next`, following JUMP / CALL; skip only when no `OP_DISPATCH` comes before a non-state op, a barrier with bits, or `OP_TF_STATE` | 10369-10404, 10529 | up to 0.1-0.2 ms | pixels unaffected, but it drops side effects of today's scan (composites made early, `serial_put` bumps, deferred handles rewritten at 5063, counters) | review: holds, caveats | S2b | pending |
| P2 | `geo_draw_` copies `S` / `R` unconditionally but restores them only when `n > 1` | `nvn_geometry.inc` 815-830, 761 | 5-10 µs per geometry run (DK) | none | read | S2 | pending |
| P3 | Every commit copies the handler array and adds a handler. `cctx_snap` (a lock, an `snprintf`, an `NSString`) builds a message used only on `cb.error`. Capture the counters at commit and format on error (`cctx_snap` diffs against statics, 11520-11525) | 1617-1621 | 25-50 µs | low | review: holds, caveat | S2 | pending |
| P4 | `rp_begin_ex_` → `rt_dims` resolves the first target again, and `pd.colorAttachments[i]` is sent in about 7 loops | 4136, 4257, 4039-4255 | 5-15 µs | low | agent | S2b | pending |
| P5 | `m4_end` sends `conformsToProtocol:` at every encoder end | 875 | 6-10 µs | none | agent | S2 | pending |
| P6 | `pend_last` hashes every page even when nothing is pending; `ubo_read` calls `pend_hits` twice | 742, 7904 | bindless games only | none | agent | S2b | pending |

## Encode thread (on the Mac: DK only)

| ID | Item | Where | Cost (estimate) | Risk | Checked | Stage | State |
|---|---|---|---|---|---|---|---|
| E1 | Block handoffs wake a sleeping thread. `os_sync_wait_on_address` still needs a wake call; only spinning avoids it | `nvn_rec.h` 184, 197-224 | 0.1-0.25 ms | medium | review: holds, caveats | S2b | pending |
| E2 | `RO_RE_BEGIN` deep-copies the pass descriptor. Settled: no caller reuses or mutates it, and the line's comment is wrong. Keep the copy while `DM_NVN_GPUPROF` or `DM_NVN_ENC_LABEL` is on, because their reads at `gp_begin` and 4253 would race | `nvn_rec.h` 322 | 50-150 µs | low | review: holds | S2 | pending |
| E3 | PSO / DSS / compute PSO records retain on one thread and release on the other. A duplicate `hm_put_id` releases at once (1733), so unretained records would turn it into a use-after-free. Some tests clear `g_pso` | `nvn_rec.h` 265, 266, 292 | 30-100 µs | medium | review: holds, caveats | S2b | pending |
| E4 | `rec_t` takes 128 B for every record | `nvn_rec.h` `rec_t` | 0.05-0.2 ms | medium (format change) | agent | S2b | pending |

## NVN entry points

| ID | Item | Where | Cost (estimate) | Risk | Checked | Stage | State |
|---|---|---|---|---|---|---|---|
| N1 | Every implemented non-`nvnCommandBuffer*` function goes through the big-stack switch, leaf setters and getters included (~2,500 a frame in a light DK scene) | `hle_nvn.c` 1332-1337, `hle_bigstack.c` 27-89 | 0.05-0.8 ms; DK's controller counts it | low, as long as exempt leaves call no `LOG`, Metal or lock | read | S2b | pending |
| N2 | Texture geometry computes the full layout 4 times per call, and `fmt_of` scans 37 ranges | `nvn_deswizzle.c` 37-49, `nvn_tex.c` 12-30 and 171-219, `nvn_deswizzle_gpu.m` 77-79 | 1-3 µs a call | low (pure functions) | review: holds | S2b | pending |
| N3 | `nvn_sparse_alias` / `nvn_host_readable` lock `g_vp_mu` and scan every virtual pool | `hle_nvn.c` 2621-2641 | MKW | medium: `g_vp` is realloc'd, `vpool_drop` frees, `vrun_set` rewrites `run[]`, and `nvn_sparse_copy` holds the lock across memcpys | review: holds, caveats | S2b | pending |
| N4 | Dirty tracking scans every slot outside the hinted path | `nvn_dirty.c` 65-199 | 20-60 µs a scan, in bursts | medium | agent | S2b | pending |
| N5 | The call counter and the function pointer share one 16 B slot | `hle_nvn.c` 45-47 | only with several recording threads (MKW) | medium: the slot layout is an ABI (`nvn_entry.S` `lsr #4`, `gen_protos.py`, `nvn_unimpl_c`) | review: holds, caveats | S2b | pending |
| N6 | `rec` zeroes the payload before draws `memcpy` over it, and writes the header twice | `hle_nvn.c` 903-983 | 10-50 µs | medium | agent | S2b | pending |
| N7 | `thr_sys_ns` makes two Mach traps and a MIG call per measurement; use `pthread_mach_thread_np` | `hle_nvn.c` 1243-1247 | 10-20 µs | none | agent | S2 | pending |
| N8 | `getenv("DM_NVN_VLOG")` runs on every pool initialize | `hle_nvn.c` 249 | per pool create | none | agent | S2 | pending |

## Host threads and frontend

| ID | Item | Where | Cost (estimate) | Risk | Checked | Stage | State |
|---|---|---|---|---|---|---|---|
| H1 | Redundant wait-list scans: `SignalProcessWideKey` scans for `left` after a wake-all that leaves none, `SignalToAddress` counts `nw` for every type, and `lock_handoff` scans twice | `hle_thread.c` 1067, 1090, 280-282 | one ~55-waiter scan per sync SVC | none | read | S2 | pending |
| H2 | One global `g_wait` list. Use per-key buckets, doubly linked. Wkind 4 waiters match through handle arrays and need their own index; `lock_acquire_for` rekeys in place (293-294); `dm_guest_clock_advanced` walks every waiter (575) | `hle_thread.c` 98-103, 218-231, 551-575 | 1-2 % of a core at 75-90 k thread SVCs/s | medium | review: holds, caveats | HT | pending |
| H3 | `pthread_cond_signal` runs under `G`. Deferred signals must also be flushed before every implicit release of `G` in `pthread_cond_wait` (`block` 266-269, `thread_main`), and `thr_free` destroys the condvar | `hle_thread.c` 245-248, 343-351 | not measured | medium | review: holds, caveats | HT | pending |
| H4 | `dm_thread_service_request` locks `G` just to read `nhand` | `hle_thread.c` 150-154 | 20-50 ns per FS call | none | agent | S2b | pending |
| H5 | `dm_yield_to_core_peers` polls every 50 µs | `hle_thread.c` 160-205 | MKW ~13 handoffs/s | medium | agent | HT | pending |
| H6 | `SystemEvent` bindings: a linear scan of 512 entries under a nested lock | `hle_thread.c` 38-50, 1222-1251 | < 1 µs, ~200/s | low | agent | S2b | pending |
| H7 | The gate return writes `fpcr` / `fpsr` / `nzcv` unconditionally | `entry.S` 116-121 | < 0.5 % of a core | low with a compare | agent | S2b | pending |
| H8 | The cursor is hidden through AppKit on every controller event | `front_mac.m` 106-110, 152-156 | 60-250 calls/s per controller | cosmetic | agent | S2b | pending |

## Checked and fine

All reviews found these already efficient:
- `pc_get` / `pool_find` / `mtl_addr` at the fork's pool counts;
- the vertex / fragment / compute table caches;
- `prog_get`'s one-entry cache;
- `g_enc_pso` elision;
- the `mtl_exec` op loop and `state_op` elision;
- `res_commit`'s early out and `sub_cut`'s fast returns;
- `present_now` and `nvn_fmt_to_mtl`;
- the deswizzle inner loop;
- the gate hash dispatch, the FS image lookup and HID fill;
- the audio renderer (0.07-0.08 ms a frame).
