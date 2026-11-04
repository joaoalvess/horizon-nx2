# NVN translation state

Written against commit `b0d98ee7`. Every `file:line` below is at that commit. Unless a path is given, lines are in `dm/gfx/nvn/nvn_mtl.m`.

This is the input of stage S3b (`agents/refactor/plan.md`, row S3): the translation state moves into one context struct, one group of globals per commit, in the order below, with the command-stream digest identical after each step. The file lists every global and static of `dm/gfx/nvn`: `nvn_mtl.m` with the files it includes (`nvn_geometry.inc`, `nvn_capture.inc`, `nvn_feedback.inc`, `rt_range_check.inc`, `nvn_rec.h`), `hle_nvn.c`, `nvn_dirty.c`, `nvn_tex.c`, `host_msl.m` and the headers. `nvn_capture.c` and `nvn_refl.m` have none.

Other files of this folder: [nvn-pipeline.md](nvn-pipeline.md) (the frame these globals serve), [lifetimes.md](lifetimes.md) (fences, deferred release, serials), [locks.md](locks.md) (every lock and its order), [overview.md](overview.md) (the threads).

## How the inventory was made

1. Each translation unit was parsed with clang at BASE (`-fsyntax-only -fobjc-arc -Xclang -ast-dump`, with Pokopia's generated profile header).
2. Every reference to a static variable was classified as a write (assignment, `++` / `--`, atomic store or exchange, an address or array passed to a call) or a read, and attributed to its function. An address or array passed to a call is a read when the callee's parameter is a pointer to `const` (for example `gw_live_in(const gw_ent *, ...)`, `:1224`) or the argument is one a C library function only reads (`memcmp`, the source of `memcpy`, a `%s` argument); 136 references were resolved that way. Where the callee could not be found (a macro, an Objective-C message, a call split across lines, a library function not in the list), the reference stays a write, so a Written by column can still name a function that only reads. A redeclared tentative definition is listed under its first line: `g_seg` (`:618`, `:900`), `g_cur_frame` (`:900`, `:1416`), `g_stat_pass`, `g_stat_draw`, `g_bw_load`, `g_bw_store` (`:899-900`, `:3502`), `g_ghost` (`:1804`, `:1842`).
3. Thread roots: `h_nvnQueueSubmitCommands` (`sub`); every other `h_*` entry (`api`); `rec_thread` (`enc`); `ubc_thread` (`ubc`); `link_main` and `-metalDisplayLink:needsUpdate:` (`link`); `present_main` (`present`); blocks given to Metal handlers or to `g_commit_blocks` (`mtlcb`); blocks given to GCD (`gcd`). A function's threads are the roots that reach it through direct calls.
4. Lock at a write: the locks held there, including the locks every caller of the function holds at the call. A row shows the locks held at all of its writes.

Limits. The call graph counts every call whatever its condition, so a thread in a Threads column is a possible path, not a proven one: it is (unverified) unless a row or the [cross-thread table](#cross-thread-touches-of-moving-state) says it was checked. Calls through function pointers are not in the graph, and a lock held only by a caller reached through a pointer is missed.

## The submit path

1. `h_nvnQueueSubmitCommands` (`hle_nvn.c:1278`) takes `g_sub_mu` (`hle_nvn.c:1279`), then calls `mtl_prepare`, enters the suspend gate (`gfx_enter`, `hle_nvn.c:1281`), and calls `mtl_queue_activate` (`hle_nvn.c:1284`), `mtl_set_queue_origin_lower_left` (`:1285`), `nvn_cap_submit` (`:1286`), `mtl_sub_begin` (`:1287`), `nvn_ft_poll` (`:1288`), `mtl_sub_index` (`:1289`), the `mtl_exec_rest` / `mtl_exec` loop (`:1290-1291`) and `mtl_sub_commit` (`:1292`). It releases `g_sub_mu` at `hle_nvn.c:1293`.
2. `h_nvnQueueFinalize` takes `g_sub_mu` around `mtl_queue_forget` (`hle_nvn.c:785`). No other code takes `g_sub_mu`.
3. `mtl_sub_begin` records the calling thread as the submit thread (`:819`). The upload batch checks it (`on_sub_thread` `:784`, `up_owner_check` `:785-791`).
4. The present (`h_nvnQueuePresentTexture` → `mtl_present` `:12845` → `present_enqueue` `:12970`) runs on the game's thread without `g_sub_mu`. It enters only the suspend gate (`hle_nvn.c:1922`).
5. `nvn_replay` calls `mtl_sub_begin`, `mtl_exec` and `mtl_sub_commit` itself, without `g_sub_mu` (`agents/refactor/plan.md`, Oracles; `mtl_sub_begin` calls `mtl_prepare` for it, `:816`).

"Submit path" below means the functions these calls reach. The translator takes no lock of its own around its state: the Lock column of a moving group says `g_sub_mu` for that reason, and names any other lock held at every write.

## S3b order

Each step moves every global of one group, and the function-local statics assigned to it in [Function-local statics](#function-local-statics), into the context struct, with the digest identical after it. Small groups that only the submit path touches come first. Groups whose state other code reads come after the groups they read, `R` and `S` move with every copy of them, and the encoders and command buffer move last, next to the step that makes the translator write through the sink.

| Step | Group | Declarations | Globals | References | Tests naming them | Touched off the submit path | Why here |
|---|---|---|---|---|---|---|---|
| 1 | [T1 Replay cursor](#t1-replay-cursor) | 5 | 7 | 123 | 3 | no | small; the op walk that later groups read |
| 2 | [T2 Submission bookkeeping](#t2-submission-bookkeeping) | 9 | 15 | 123 | 5 | `mtl_init`; diagnostics; `sp_reconcile`, `sp_resolve` | the submission lifecycle every later group resets in |
| 3 | [T3 Queries and conditional rendering](#t3-queries-and-conditional-rendering) | 7 | 19 | 120 | 6 | no | submit path only, reset in `mtl_sub_begin` |
| 4 | [T4 Write tracking](#t4-write-tracking) | 16 | 43 | 292 | 3 | no | submit path only; T5 and T7 read its generations and epochs |
| 5 | [T5 Inline uniform updates and uniform shadows](#t5-inline-uniform-updates-and-uniform-shadows) | 10 | 13 | 106 | 1 | no | reads T4 (`ubp_get` checks `g_sbw_gen` and `g_pend_gen`) |
| 6 | [T6 Upload batch](#t6-upload-batch) | 13 | 22 | 166 | 2 | `present_enqueue` and texture resolution, on the submit thread only | used outside `g_sub_mu` by `present_enqueue` |
| 7 | [T7 Index, vertex and indirect conversions](#t7-index-vertex-and-indirect-conversions) | 15 | 49 | 250 | 2 | no | keyed on T2's `g_sub_serial` and T4's epochs |
| 8 | [T8 Store lookahead, attachment ledger, zero-source skip, lazy clears](#t8-store-lookahead-attachment-ledger-zero-source-skip-lazy-clears) | 17 | 49 | 371 | 3 | `h_nvnWindowInitialize`, `mtl_ext_tex`, `present_enqueue` | the ledger is written by API and present calls |
| 9 | [T9 Replay rewrites: load elision, deferred draws, fusion, hoists](#t9-replay-rewrites-load-elision-deferred-draws-fusion-hoists) | 15 | 38 | 455 | 6 | a commit feedback block; a stats reader | saves and restores `S` and `R`; a feedback block writes two counters |
| 10 | [T10 Geometry emulation and transform feedback](#t10-geometry-emulation-and-transform-feedback) | 14 | 18 | 141 | 2 | no | self-contained; reads `S`, `R`, `g_enc` |
| 11 | [T11 Render pass state (R)](#t11-render-pass-state-r) | 32 | 57 | 1074 | 39 | `mtl_queue_forget` (under `g_sub_mu`); `m4_end`, `sp_emit` | `R` and every copy of it |
| 12 | [T12 Draw state (S) and queue states](#t12-draw-state-s-and-queue-states) | 10 | 13 | 775 | 23 | `mtl_queue_forget` (under `g_sub_mu`); GCD pipeline builds (no `S` read) | `S` with its copies, the queue states and the program ring |
| 13 | [T13 Argument encoding](#t13-argument-encoding) | 10 | 23 | 116 | 15 | `mtl_init`; upload batch | compares against the G4 and G5 generations, which stay global |
| 14 | [T14 Encoders and command buffers](#t14-encoders-and-command-buffers) | 8 | 10 | 276 | 10 | upload batch, on the submit thread only | last: the next step replaces these with the sink |

What stays global after T14 is in [Groups that stay global](#groups-that-stay-global), each group with its reason.

## Constraints for every step

1. `S` and `R` are copied whole. `queue_state` holds `typeof(S)` and `typeof(R)` (`:5678`), and `mtl_queue_activate` swaps them per queue (`:5680-5691`). Saved copies: static `typeof(S) Ssave` in `pso_predict_rest_` (`:8556`), `fz_probe_cov2` (`:8611`), `fz_check_run` (`:9071`) and `cs_hoist_try` (`:10375`), all four moving with T12; stack `typeof(R) Rsave` in `fz_probe_cov2` (`:8611`), `fz_check_run` (`:9071`) and `cs_hoist_try` (`:10375`); stack copies in `defer_replay` (`:9199`), `defer_fallback` (`:9214`), `lc_land` (`:10235`, `R` only), `geo_run_walk` (`nvn_geometry.inc:761`, `S` and `R`) and `geo_draw_` (`nvn_geometry.inc:815`, `S` and `R`); heap copies of `sizeof S` in `fz_snap_take` (`:9056`) and `defer_take` (`:9170`); in the unbuilt range checker, `rr_snapshot` (`rt_range_check.inc:2`) and `rr_finish`'s `ss` / `rs` (saved at `rt_range_check.inc:37`, restored at `:51`; snapshots loaded at `:45`). Each step keeps these copies the same type and size.
2. After a restore, `prog_resolve` (`:5659`) takes `S.prog` again from the ring of combined programs in `bind_stages` (`:5638`), because the slot a saved `S.prog` points to can be reused (`:5655-5658`). The ring moves with `S` (T12).
3. 73 of the 106 test sources include `nvn_mtl.m` (`agents/refactor/plan.md`, S3): a test that names a moved global must still compile. Each group lists the tests that name its globals.
4. Code off the submit path that touches moving state ([cross-thread table](#cross-thread-touches-of-moving-state)) must reach the same state after the move. With one global context instance it does. Thread-local variables stay out of the context, since one shared instance would make each thread see the others' values: `t_pc` (`:504`, G4), `t_tex_sampled` (`:2670`, G5), `t_lib_layer` (`:4491`, G6), `g_cp_*` (`:139-141`, G12). `nvn_replay` runs on one thread, so the digest would not show such a change.
5. A counter declared on the same line as moving state (for example `g_fd_n`, `:3821`) moves with that line; counters on lines of their own stay in G12.
6. A moving global with a non-zero initializer keeps it in the context instance's initializer: T3 `g_vis_ring_i = -1` (`:666`), `g_vis_cur = -1` (`:669`); T4 `g_pend_gen = 1` (`:684`), `g_drain_sub = ~0ull` (`:1070`); T7 `g_vbuf_unaligned = {.klen = 24}` (`:5427`), `g_ir = {.klen = sizeof(ir_key)}` (`:5921`), `g_mdi_epoch = ~0ull` (`:10097`), `g_mdx_tag = 1`, `g_mdx_ep = ~0ull` (`:10134`); T9 `g_defer_cur = &g_defer_slots[0]` (`:8298`, which becomes the context's own slot array); T10 `g_geo_ix = {.klen = sizeof(geo_ix_key)}` (`nvn_geometry.inc:227`); T11 `g_fb_pass = UINT64_MAX` (`:9816`); T12 `g_pso_dirty = 1`, `g_dss_dirty = 1` (`:3500`); T13 `g_psnap_gen = 1` (`:7629`), `g_args_dirty[6] = {1, 1, 1, 1, 1, 1}` (`:7759`). An `nvn_hmap` with `klen` 0 does not work as a map. A function-local static that moves keeps its initializer the same way.
7. Each field keeps the type of the global it replaces. Object pointers keep their ownership qualifier, since a field without one is `__strong` and keeps the object alive past the deferred-release scheme: `__unsafe_unretained` on `g_sp_relaxed` (`:869`), `range_color` / `range_depth` of `g_pass` (`:3482`), `g_fb_src` (`:7758`), `g_c0_dim_buf` (`:7919`), the texture fields of the T7 caches at `:4917` and `:7590` and the `fn` / `lean` fields of `g_geo_mesh` (`nvn_geometry.inc:371`); `__strong` in `vis_buf` (`:663`), `g_up_slot_blk` / `g_up_slot_over` (`:2111`), `g_bcrt_sh` / `g_bcrt_buf` (`:3937`) and `g_fb_use` (`:7758`). Arrays stay arrays: 19 `sizeof` expressions over 13 moving arrays depend on it, for example `sizeof g_pend_hgen` (`:729`) and `sizeof(*g_ret)` (`:9944`, `:10019`, `:10160`, `nvn_geometry.inc:762`, `:817`).
8. The `NVN_RT_RANGE_TEST` blocks (`:3473`, `:3510`, `:3889`, `:3897`, `:10519`, `:10695`, `:11765`, `:13097`) and `rt_range_check.inc` name T1, T3, T11 and T12 globals (`g_exec_next`, `g_exec_cur`, `g_vis_*`, `S`, `R`). No build defines the macro (it appears only in `nvn_mtl.m`), so a rename there breaks without an error: rename them in the same commit as their group, or mark them unbuilt ([Test-only: the range checker](#test-only-the-range-checker)).

## Generation counters and invalidation

Cached results are checked against these counters instead of being flushed. "Bumped at" lists the write sites from the AST; "Read by" the functions that read the counter.

| Counter | Declared | Bumped at | Read by | What a change invalidates |
|---|---|---|---|---|
| `g_pool_gen` | `:502` | `mtl_pool_add` `:551`, `mtl_pool_del` `:569` | `bind_vbufs`, `gmem_map_gpu`, `pc_get`, `pc_put`, `vbuf_prepare` | the pool table changed: the per-thread pool lookup `t_pc` (`:504`), the `bind_vbufs` cache (`:5503-5504`), `vbuf_prepare` (`:5491`), the GPU address table (`gmem_map_gpu`, `:7795-7802`) |
| `g_reg_gen` | `:519` | `mtl_pool_add` `:529`, `mtl_pool_del` `:559`, `mtl_reg_tex` `:5011`, `mtl_reg_tex` `:5013`, `mtl_reg_samp` `:5057` | `args_sync_dirty`, `draw_`, `pool_gpu`, `rp_begin_ex_`, `rt_range_same` | a pool, texture or sampler registration changed (`:519`): argument-buffer reuse (`args_sync_dirty`, `:7765`), the render-target range state of the open pass (`g_pass.reg_gen`, stored by `rp_begin_ex_` `:4047`, checked by `rt_range_same` `:8769`, `:8775` and `draw_` `:10622`), pool snapshots (`pool_gpu`, `:7642`) |
| `g_ser_gen` | `:1739` | `mtl_alias_drop_pool` `:1789`, `alias_take_over` `:1828`, `serial_put` `:1831`, `serial_del` `:1832`, `tex_put` `:1865`, `tex_upgrade` `:2055`, `tex_upgrade` `:2073`, `up_flush` block `:2170` `:2174`, `mtl_tex_cpu_written` `:2639`, `sp_view` `:2927`, `sp_upgrade` `:3119`, `tex_mtl_` `:3310` | `args_sync_dirty`, `cctx_snap`, `draw_`, `pool_gpu`, `prog_get`, `rp_begin_ex_`, `rt_range_same`, `tex_by_id`, `tex_fast`, `tex_rid_` | serial table entries added or removed, or a packaged texture replaced (`:1738`): `prog_get`'s one-entry cache (`:4767`), the texture registry's view caches (`view_ser`), `pool_gpu` (`:7642`), `args_sync_dirty` (`:7765`), the range state of the open pass (`g_pass.ser_gen`: `:4047`, `:8769`, `:8775`, `:10622`), `cctx_snap` (`:11524-11525`). The upload batch's feedback block bumps it too (`:2170-2174`) |
| `g_now` | `nvn_dirty.c:35` | `stamp_page` `nvn_dirty.c:71`, `stamp_page` `nvn_dirty.c:74` | `nvn_dirty_now` | the dirty clock (`nvn_dirty_now`, `nvn_dirty.c:200`): with `g_ser_gen` it decides argument reuse (`args_sync_dirty`), view reuse and the pass's `range_dirty` |
| `g_psnap_gen` | `:7629` | `pool_gpu` `:7667` | `encode_args_` | the pool snapshot was rebuilt: an argument block holding a pool address is not reused past it (`:7629`) |
| `g_gmem_gen` | `:7793` | `gmem_map_gpu` `:7815` | `gmem_map_gpu` | the pool GPU-address table was rebuilt |
| `g_sbw_gen` | `:705` | `sbw_note` `:708` | `ubp_get`, `vbuf_unaligned` | a write noted that uniform shadows must respect (`:705`): `ubp_get`, `vbuf_unaligned` |
| `g_pend_gen` | `:684` | `pend_reset` `:729` | `gw_commit`, `pend_add`, `pend_last`, `pend_since`, `sbw_slot`, `ubp_get` | a new submission: the pending-write buckets of the last one are stale (`pend_reset`, `:729`) |
| `g_wr_epoch` | `:1061` | `blit_buf` `:1085`, `dispatch` `:10845`, `copy_t2b` `:10936`, `tf_state_gpu` `nvn_feedback.inc:19`, `tf_note` `nvn_feedback.inc:56`, `geo_mesh_draw` `nvn_geometry.inc:469`, `geo_gs_one` `nvn_geometry.inc:721` | `drw_drained`, `drw_valid`, `ixc_find`, `ixc_run`, `mdi_live`, `vbuf_unaligned`, `wide_find`, `wide_run` | a buffer write outside a render pass: indirect-draw and 8-bit index conversions, the drain list (`:1061`) |
| `g_mdx_epoch` | `:1062` | `mtl_sub_copy` `:1107`, `mtl_sub_fill` `:1362`, `dispatch` `:10845`, `copy_t2b` `:10936`, `mtl_exec` `:11777`, `tf_state_gpu` `nvn_feedback.inc:19`, `tf_note` `nvn_feedback.inc:56`, `geo_mesh_draw` `nvn_geometry.inc:469`, `geo_gs_one` `nvn_geometry.inc:721` | `mdx_find`, `mdx_run` | a GPU write that can change a multi-draw's records or count (`:1062`) |
| `g_vbuf_write_epoch` | `:5428` | `swrite_note` `:5596`, `swrite_note` `:5597` | `vbuf_unaligned` | a shader write: vertex-stream snapshots (`:5428`) |
| `g_sub_serial` | `:806` | `mtl_sub_begin` `:813` | `drw_drained`, `drw_note`, `drw_valid`, `fb_snap`, `ixc_find`, `ixc_run`, `mdi_live`, `mdx_find`, `mdx_run`, `pso_get_`, `sp_reconcile`, `sp_resolve`, `sp_sub_begin`, `sp_tiles_drain`, `sub_cut`, `tex_by_id`, `treg_finish_submission`, `vbuf_prepare`, `vc_stat`, `vconv_bind`, `wide_find`, `wide_run` | a new submission: every per-submission cache keyed on it |
| `g_vp_gen` | `hle_nvn.c:2114` | `vpt_set` `hle_nvn.c:2165` | `nvn_sparse_gen` | a virtual-pool mapping request (`hle_nvn.c:2114`, read through `nvn_sparse_gen` `hle_nvn.c:2650`) |
| `g_fence` | `:129` | `mtl_sub_commit` `:1610` | `alias_take_over`, `arena_begin`, `defer_obj_release_ex`, `gml_take`, `gp_periodic_finish`, `ms_after`, `mtl_exec`, `mtl_finish_gpu_at`, `mtl_last_fence`, `mtl_sub_begin`, `mtl_wait`, `mtl_wait_at`, `mtl_wait_state_dump`, `sp_tile_free`, `tbuf_rows_copy`, `tbuf_shadow`, `tex_mtl_`, `ubp_get` | the last committed fence, bumped only by the submit thread (`:129`) |
| `g_done` | `:133` | `post_complete` `:1600` | `arena_begin`, `arena_new`, `defer_drain`, `gw_commit`, `gw_live_in`, `ms_poll`, `mtl_sub_begin`, `mtl_wait_at`, `mtl_wait_state_dump`, `post_complete`, `sp_tiles_drain`, `tex_mtl_`, `um_overlay` | the last completed fence: gates reuse of allocators, visibility buffers, arenas and deferred releases |

`g_args_reg_seen`, `g_args_dirty_seen` and `g_args_ser_seen` (`:7760`) hold the `g_reg_gen`, dirty-clock and `g_ser_gen` values seen when the argument blocks were last valid; `args_sync_dirty` (`:7764-7768`) marks every stage dirty when one moved. The generations of G4 and G5 stay global; the seen values move with T13.

## Cross-thread touches of moving state

| Globals | Group | Function | How it is reached | Lock there | Checked |
|---|---|---|---|---|---|
| `g_alloc4`, `g_alloc_n`, `g_up_alloc4`, `g_vt`, `g_ft`, `g_ct`, `g_up_ct`, `g_vt_valid`, `g_ft_valid`, `g_ct_valid` | T2, T6, T13 | `mtl_init` (`:391`) | the first NVN call on any thread; the guard `if (g_dev) return` (`:392`) takes no lock | none | the guard; which thread calls first (unverified) |
| `g_alloc4`, `g_alloc_n`, `g_alloc_waits`, `g_alloc_grown`, `g_up_alloc4` | T2, T6 | `mtl_mem_stat`, `mtl_alloc_stats` | diagnostic reports | none | reads only; their callers (unverified) |
| `g_sub_serial` | T2 | `sp_reconcile`, `sp_resolve` | sparse texture resolution, reached from API, link and present roots in the call graph | `g_sp_mu` | (unverified) |
| upload batch (T6), `g_up_ct`, `g_cb` | T6, T13, T14 | `up_begin`, `up_flush`, `pkg_upload_`, `tex_zero_fill`, `tex_init_fill`, `sp_upload` | texture resolution (`tex_mtl`) on any thread | `up_owner_check` aborts off the submit thread (`:2144`, `:2203`); `tex_zero_fill` and `tex_init_fill` return off it (`:2513`, `:2577`); `present_enqueue` uploads only when `on_sub_thread()` (`:12977`), without `g_sub_mu` | yes |
| `g_xv`, `g_xv_n`, `g_xv_disabled`, `g_xv_ndis`, `g_xv_viol`, `g_xv_present`, `g_xv_npresent` | T8 | `mtl_xv_window_tex` (`:3815`), `present_enqueue` (`:12973`) | `h_nvnWindowInitialize` (`hle_nvn.c:1361`), `mtl_ext_tex` (`:12851`) and the present, on game threads | none | yes |
| `g_fzc_same`, `g_fzc_diff` | T9 | the block of `fz_check_run` at `:9085`, added to `g_commit_blocks` | runs in the commit feedback handler (`:1619`) | none | yes |
| `g_csh_moved`, `g_csh_depth`, `g_csh_stop` | T9 | `mtl_cshoist_stats` | statistics read | none | its callers (unverified) |
| `S`, `R`, `g_pso_dirty`, `g_dss_dirty`, `g_state_inited`, `g_queue_states`, `g_active_queue`, `g_args_dirty` | T11, T12, T13 | `mtl_queue_forget` (`:5693-5700`) → `state_reset`, `args_dirty_all` | `h_nvnQueueFinalize` | `g_sub_mu` (`hle_nvn.c:785`) | yes |
| `S` | T12 | `vin_fmt` (`:5865`), `vconv_wanted` (`:5883`) | GCD pipeline builds through `pso_desc`, which passes a key (`:6338-6352`); `S` is read only when the key is NULL, from the submit path (`:5975-5978`, `nvn_geometry.inc:63`) | none needed | yes |
| `g_last_end_relaxed`, `g_blit`, `g_blit_alias` | T11, T14 | `m4_end` (`:872-877`) | every encoder end, including the upload batch's (`:2147`, `:2155`, `:2520`, `:2529`), which runs on the submit thread only | none | the upload paths |
| `g_sp_mapped`, `g_sp_relaxed` | T11 | `sp_emit` (`:2840`) | sparse mapping (`:3006`, `:3028`, `:3115`), reached from API, link and present roots in the call graph | `g_sp_mu` | (unverified) |
| `g_enc` | T14 | `enc_open` (`:3480`) | readers such as `blit_note` (`:1044`), `mtl_sub_update` (`:1338`) and `sp_emit` (`:2855`), reached from API, link and present roots in the call graph | none | (unverified) |

With one context instance every row keeps working. S5 moves translation to its own thread (`agents/refactor/plan.md`, S5); these rows are what it has to hand over.

## Groups that move

In each table, Line is the declaration; Written by and Read by are the functions from the AST (five, then a count); Read by lists only the functions that do not also write, so "—" there means every function that reads also writes; Invalidated by is what resets or ages the state.

### T1 Replay cursor

The replay's position. `mtl_exec` (`:11719`) walks a command list; draws look ahead through `g_exec_next` (store lookahead, deferred draws, fusion, multi-draw chains). The unbuilt range checker saves `g_exec_next` and `g_exec_cur` (`rt_range_check.inc:37`) and restores them (`rt_range_check.inc:51`); see constraint 8.

Tests naming these globals (3): `t_perf_order.m`, `t_pso_depth_stencil.m`, `t_pso_pending.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:8238` | `g_exec_next` | the op after the current draw in the replay | `defer_replay`, `fz_check_run`, `mtl_exec` | `cs_hoist_try`, `defer_try`, `draw_`, `fuse_try`, `fz_probe_cov2` +13 | `g_sub_mu` | set per op by `mtl_exec` |
| `:8239` | `g_exec_cur` | the current draw's own op | `mtl_exec` | `defer_pre`, `fz_prefilter`, `geo_draw_`, `mdx_next`, `sdx_decide` | `g_sub_mu` | set with `g_exec_next` |
| `:8240` | `g_ret`, `g_ret_n` | replay call-return stack: at `OP_CALL` the caller's next op is pushed | `mtl_exec` | `cs_hoist_try`, `defer_cont`, `geo_draw_`, `geo_run_walk`, `ixc_run` +3 | `g_sub_mu` | per `mtl_exec` call |
| `:8241` | `g_rest`, `g_nrest` | handles of this submission still to replay after the current one | `mtl_exec_rest` | `defer_cont`, `fz_next`, `mtl_exec`, `pass_ds_need` | `g_sub_mu` | set per submission by `mtl_exec_rest` (`:8242`) |
| `:8848` | `g_exec_seq` | sequence number of the current op | `mtl_sub_index_`, `sdx_seq` | `defer_pre`, `fz_prefilter`, `sdx_decide` | `g_sub_mu` | per op (`mtl_sub_index_`, `sdx_seq`) |

### T2 Submission bookkeeping

What one submission owns between `mtl_sub_begin` (`:812`) and `mtl_sub_commit` (`:1602`). `g_sub_thread` (`:783`) is not here: `on_sub_thread` reads it on every thread, so it stays in G2.

Tests naming these globals (5): `nvn_replay.m`, `t_geometry.m`, `t_geometry_hazards.m`, `t_pso_pending.m`, `t_readback.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:96` | `g_alloc4`, `g_alloc_n`, `g_alloc_cur` | command allocator pool of the main command buffer, its size and the one in use | `mtl_init`, `mtl_sub_begin` | `mdi_wait`, `mtl_alloc_stats`, `mtl_mem_stat`, `mtl_sub_commit`, `sub_cut` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | an allocator is reused when its `g_alloc_fence` ≤ `g_done` (`mtl_sub_begin` `:825-830`) |
| `:130` | `g_cut_copy` | a buffer-to-texture copy was encoded since the last commit: the next pass boundary commits the segment | `copy_b2t`, `mtl_sub_commit`, `sub_cut` | — | `g_sub_mu` | cleared at commit (`mtl_sub_commit` `:1608`, `sub_cut`) |
| `:618` | `g_seg` | index of the segment being encoded in this submission | `mtl_sub_begin`, `sub_cut` | `gp_begin`, `mtl_sub_commit`, `mtl_sub_counter` | `g_sub_mu` | 0 at `mtl_sub_begin` (`:813`) |
| `:619` | `g_sclk` | counter timestamps per segment | `mtl_sub_begin`, `mtl_sub_commit`, `sub_cut` | — | `g_sub_mu` | returned at `mtl_sub_begin` (`:813`) and `mtl_sub_commit` |
| `:770` | `g_commit_blocks` | blocks run in the commit feedback handler of this submission | `mtl_sub_begin`, `mtl_sub_commit` | `draw_`, `fz_check_run`, `gml_take`, `ixc_run` | `g_sub_mu` | new array per submission (`:834`); copied and attached at commit (`:1617-1619`), nil after (`:1645`) |
| `:777` | `g_alloc_fence`, `g_alloc_waits`, `g_alloc_grown` | fence of each allocator's last submission; wait and growth counters | `mtl_sub_begin`, `mtl_sub_commit` | `mtl_alloc_stats`, `mtl_wait_state_dump` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | set at commit (`:1643`) |
| `:798` | `g_post`, `g_npost`, `g_postcap` | post-ops of this submission (events, queries), copied at commit for completion | `mtl_sub_begin`, `post` | `mtl_sub_commit` | `g_sub_mu` | `g_npost = 0` at `mtl_sub_begin` (`:837`) |
| `:802` | `g_sub_pool` | the submission's autorelease pool (`:798-802`) | `mtl_sub_begin`, `mtl_sub_commit` | — | `g_sub_mu` | pushed in `mtl_sub_begin` (`:821`), popped at commit (`:1646`) |
| `:806` | `g_sub_serial` | submission index | `mtl_sub_begin` | `drw_drained`, `drw_note`, `drw_valid`, `fb_snap`, `ixc_find` +17 | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | incremented by `mtl_sub_begin` (`:813`); keys every per-submission cache |

### T3 Queries and conditional rendering

Conditional rendering (`:620`) and occlusion queries (`:655`), reset in `mtl_sub_begin` (`:813`, `:837-845`).

Tests naming these globals (6): `t_defer_chain.m`, `t_reorder_chain.m`, `t_rt_range.m`, `t_sbw.m`, `t_xv.m`, `t_zskip.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:630` | `g_rc_skip` | a render-enable block evaluated false is active | `mtl_exec`, `mtl_sub_begin` | `draw_tex` | `g_sub_mu` | 0 at `mtl_sub_begin` (`:813`) |
| `:633` | `g_rc_pend`, `g_rc_npend`, `g_rc_pcap` | timestamp reports replayed in this submission: their counter is known 0 | `mtl_sub_begin`, `rc_note` | `rc_value` | `g_sub_mu` | `g_rc_npend = 0` at `mtl_sub_begin` (`:813`) |
| `:634` | `g_rc_occ`, `g_rc_ocap`, `g_rc_on` | addresses ever written by a non-timestamp report (open addressing): conditions on them keep drawing | `rc_occ_add` | `rc_occ_has` | `g_sub_mu` | never cleared: `rc_occ_add` is the only writer |
| `:666` | `g_vis_ring`, `g_vis_ring_n`, `g_vis_ring_i` | ring of 32 visibility buffers with the fence of their last use | `mtl_sub_begin`, `mtl_sub_commit` | `vis_in_ring` | `g_sub_mu` | a slot is reused once its fence ≤ `g_done` (`:840-843`) |
| `:667` | `g_vis`, `g_vis_n` | this submission's visibility buffer and the slots used | `draw_`, `mtl_sub_begin`, `rp_begin_ex_` | — | `g_sub_mu` | reset at `mtl_sub_begin` (`:837`) |
| `:669` | `g_vis_on`, `g_vis_counting`, `g_vis_cur`, `g_vis_cur_pass` | visibility counting on, counting mode, current slot and its pass | `defer_replay`, `draw_`, `mtl_exec`, `mtl_sub_begin`, `vis_clear` | `rp_begin_ex_`, `rt_range_same`, `zskip_vis_dead` | `g_sub_mu` | `g_vis_cur = -1` at `mtl_sub_begin` (`:837`) |
| `:670` | `g_vs`, `g_nvs`, `g_vscap` | visibility slots since the last reset | `draw_`, `vis_clear` | `vis_snapshot` | `g_sub_mu` | `vis_clear` |

### T4 Write tracking

What the submission has written so far, for CPU reads of guest memory and for uniform shadows: pending writes (`:683-688`, reset by `pend_reset` `:729`), shader-buffer writes (`:695-705`), copy-encoder ranges (`:1035`), epochs (`:1061-1062`), writes since the last drain (`:1070`) and GPU-written pages per fence (`:1198-1207`).

Tests naming these globals (3): `t_geometry.m`, `t_geometry_hazards.m`, `t_sbw.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:683` | `g_pend_lo`, `g_pend_hi`, `g_npend`, `g_pend_over`, `g_pend_kind`, `g_pend_upd` | pending writes of this submission (inline updates, copies, fills): ranges and kinds | `mtl_sub_update`, `pend_add`, `pend_reset` | `geo_index_wait`, `gw_commit`, `pend_last`, `pend_read`, `pend_since` +2 | `g_sub_mu` | `pend_reset` (`:729`), called by `mtl_sub_begin` (`:837`) |
| `:684` | `g_pend_head`, `g_pend_hgen`, `g_pend_gen` | hash buckets of the pending writes; a bucket counts when its generation is `g_pend_gen` | `pend_add`, `pend_reset` | `gw_commit`, `pend_last`, `pend_since`, `sbw_slot`, `ubp_get` | `g_sub_mu` | `++g_pend_gen` in `pend_reset` (`:729`) |
| `:685` | `g_pend_node`, `g_npnode` | chain nodes of those buckets | `pend_add`, `pend_reset` | `pend_last`, `pend_since` | `g_sub_mu` | `pend_reset` |
| `:686` | `g_pend_wide`, `g_nwide` | pending writes too wide for the buckets | `pend_add`, `pend_reset` | `pend_last`, `pend_since` | `g_sub_mu` | `pend_reset` |
| `:688` | `g_upd`, `g_nupd` | inline updates recorded in this submission | `gw_commit`, `mtl_sub_update`, `pend_read`, `pend_reset`, `ubp_get` | — | `g_sub_mu` | `pend_reset` |
| `:695` | `g_sbwp`, `g_nsbw`, `g_sbw_over` | pages shader buffers write in this submission (`SBW_*` bits); overflow flag | `pend_reset`, `sbw_note`, `sbw_slot` | `copy_b2t`, `geo_cpu_hazard`, `gw_commit`, `sbw_hits`, `ubp_get` +1 | `g_sub_mu` | `pend_reset`; `g_sbw_gen` |
| `:696` | `g_sbw_wlo`, `g_sbw_whi`, `g_nsbw_w` | the wide shader-buffer writes of this submission | `pend_reset`, `sbw_note` | `gw_commit`, `sbw_hits` | `g_sub_mu` | `pend_reset` |
| `:705` | `g_sbw_gen` | generation bumped by every noted write that uniform shadows must respect | `sbw_note` | `ubp_get`, `vbuf_unaligned` | `g_sub_mu` | bumped by `sbw_note`; readers `ubp_get`, `vbuf_unaligned` |
| `:1035` | `g_bw_lo`, `g_bw_hi`, `g_br_lo`, `g_br_hi`, `g_bw_n`, `g_br_n`, `g_blit_ops`, `g_blit_barriers` | write and read ranges of the open copy encoder; op and barrier counts | `blit`, `blit_barrier`, `blit_buf`, `blit_open`, `dispatch_enc` | `br_hit`, `bw_hit`, `mtl_blit_barriers` | `g_sub_mu` | reset at each copy-encoder barrier (`blit_barrier` `:1055`) |
| `:1061` | `g_wr_epoch` | epoch bumped by every buffer write outside a render pass | `blit_buf`, `copy_t2b`, `dispatch`, `geo_gs_one`, `geo_mesh_draw` +2 | `drw_drained`, `drw_valid`, `ixc_find`, `ixc_run`, `mdi_live` +3 | `g_sub_mu` | invalidates indirect-draw conversions (`ixc_run`, `wide_run`, `drw_valid`) |
| `:1062` | `g_mdx_epoch` | epoch bumped by GPU writes that can change a multi-draw's records or count | `copy_t2b`, `dispatch`, `geo_gs_one`, `geo_mesh_draw`, `mtl_exec` +4 | `mdx_find`, `mdx_run` | `g_sub_mu` | invalidates `g_mdx` entries (`mdx_find`, `mdx_run`) |
| `:1070` | `g_drw_lo`, `g_drw_hi`, `g_drain_sub`, `g_drain_other`, `g_wr_geo`, `g_ndrw`, `g_drw_over` | writes since the last drain (`:1063-1068`), drain submission and epochs | `drw_drained`, `drw_note`, `geo_gs_one`, `geo_mesh_draw` | `drw_hits`, `drw_valid` | `g_sub_mu` | `drw_drained` (`:1080`) |
| `:1198` | `g_gw` | GPU-written pages per fence (page ~0: two live pages met in the slot) | `gw_commit`, `gw_put` | `gw_live` | `g_sub_mu` | an entry is live until its fence completes (`gw_live`) |
| `:1199` | `g_gwx` | the same, without the inline updates the host remembers (`um_ent`) | `gw_commit`, `gw_put`, `um_put` | `ubp_get` | `g_sub_mu` | as `g_gw` |
| `:1200` | `g_gw_all` | fence until which every page counts as written | `gw_commit`, `gww_put` | `gw_live_in` | `g_sub_mu` | that fence completing |
| `:1207` | `g_gww` | writes of `GW_PAGES` pages or more, kept whole (`:1204-1205`) | `gww_put` | `gw_live_in` | `g_sub_mu` | their fence completing |

### T5 Inline uniform updates and uniform shadows

Inline uniform updates (`UpdateUniformBuffer`) deferred into the host ring (`:1118`), and uniform shadows built by `ubp_get` (`:1286-1289`).

Tests naming these globals (1): `t_ubp_running.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:1041` | `g_nubd` | number of inline uniform updates deferred | `mtl_sub_update`, `ubd_flush` | `blit_raw`, `dispatch`, `draw_`, `encode_args_`, `rp_end` +7 | `g_sub_mu` | `ubd_flush` |
| `:1042` | `g_ubd_landing` | deferred updates are being landed | `blit_raw`, `ubd_land` | `ubd_land_compute` | `g_sub_mu` | `ubd_land` |
| `:1118` | `g_ubs_buf`, `g_ubs_off`, `g_ubs_size` | host ring for inline uniform-update data: buffer, offset, size | `mtl_sub_update` | — | `g_sub_mu` | — |
| `:1128` | `g_ubd` | the deferred inline updates | `mtl_sub_update`, `ubd_flush`, `ubd_read`, `ubd_shadow` | `ubd_covers`, `ubd_hits` | `g_sub_mu` | `ubd_flush` |
| `:1140` | `g_ubd_pf` | page filter of the deferred updates (open addressing) | `ubd_pf_add` | `ubd_flush`, `ubd_pf_hit` | `g_sub_mu` | cleared when the list is landed |
| `:1141` | `g_ubd_wide` | an update spans more than 16 pages: the filter is skipped | `ubd_flush`, `ubd_pf_add` | `ubd_pf_hit` | `g_sub_mu` | `ubd_flush` |
| `:1238` | `g_um` | inline updates of submissions still running, by byte (`:1231-1235`) | `um_put` | `um_overlay` | `g_sub_mu` | a byte counts while its fence runs |
| `:1286` | `g_ubp_idx` | scratch index list of `ubp_get` lookups | `ubp_get` | — | `g_sub_mu` | — |
| `:1288` | `g_ubp_ready` | ready fence of the uniform shadow `ubp_get` returned last | `ubp_get` | `ubo_read`, `ubp_check` | `g_sub_mu` | per `ubp_get` |
| `:1289` | `g_ubpc`, `g_ubpc_i` | cache of 16 uniform shadows and its cursor | `ubp_get` | — | `g_sub_mu` | `g_sbw_gen`, `g_pend_gen` (checked in `ubp_get`) |

### T6 Upload batch

The upload batch, which belongs to the submit thread only (`:780-781`). Stays global: `g_up_pending` (`:169`), `g_up_alloc_busy` (`:2092`), `g_up_wmu` / `g_up_wcv` (`:2095`), `g_up_lost*` (`:2138`) and `g_upload_gpu_ns` (`:2089`), which the batch's feedback block writes (`:2170`). `g_direct_upload_on` (`:2318`) is a switch (G9).

Tests naming these globals (2): `t_upload_budget.m`, `t_upload_slots.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:97` | `g_up_alloc4` | command allocators of the upload batch, one per slot | `mtl_init` | `mtl_mem_stat`, `up_begin` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | reused per slot after its fence |
| `:2090` | `g_up_cb` | the upload batch's command buffer | `up_begin`, `up_flush` | `mtl_wait_state_dump`, `tex_zero_fill` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | nil after `up_flush` |
| `:2091` | `g_up_ce` | the upload batch's compute encoder | `tex_zero_fill`, `up_begin`, `up_flush` | `pkg_upload_`, `sp_upload` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | ended in `up_flush` (`:2147`, `:2155`) |
| `:2105` | `g_up_seq` | upload batch sequence number | `up_begin` | `mtl_wait_state_dump`, `pkg_upload_`, `sp_stage`, `sp_upload`, `up_flush` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | incremented by `up_begin` |
| `:2111` | `g_up_slot_blk`, `g_up_slot_over`, `g_up_cur_slot` | staging block per slot, overflow block, current slot | `up_alloc`, `up_begin` | `up_retained` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | per batch |
| `:2112` | `g_up_slot_want`, `g_up_batch_bytes`, `g_up_over_used` | bytes wanted per slot, bytes in the batch, overflow used | `up_alloc`, `up_begin`, `up_flush` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | per batch |
| `:2123` | `g_up_blits`, `g_nup_blits`, `g_up_blitcap` | buffer-to-texture copies queued in the batch | `pkg_upload_`, `up_blit_at`, `up_flush` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `up_flush` |
| `:2124` | `g_up_texs`, `g_up_views` | target textures and temporary integer-write views kept through their upload | `pkg_upload_`, `up_begin`, `up_flush` | `sp_upload`, `tex_zero_fill` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `up_flush` |
| `:2125` | `g_up_block` | current staging block | `up_alloc`, `up_flush` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `up_flush` |
| `:2126` | `g_up_block_off`, `g_up_block_size` | offset and size in it | `up_alloc`, `up_flush` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `up_flush` |
| `:2127` | `g_up_keep` | objects kept until the batch completes | `up_alloc`, `up_begin`, `up_flush` | `pkg_upload_`, `sp_stage`, `up_src` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `up_flush` |
| `:2131` | `g_up_staging_bytes` | staging bytes in use (`:2128-2130`) | `up_alloc`, `up_flush` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `up_flush` |
| `:2284` | `g_up_pblock`, `g_up_pblock_off` | deswizzle parameter block and offset: 64-byte cells from a 64 KB shared block (`:2283`) | `up_param_alloc` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | full block replaced, old one released by fence |

### T7 Index, vertex and indirect conversions

Conversions of indices, vertices and indirect arguments, cached within a submission and keyed on `g_sub_serial` and the T4 epochs. The texture-buffer shadows (`:7589-7591`) and row staging (`:4917`) are written under `g_rmu`. Moves with it: `vbuf_prepare`'s statics (`:5490`) and `mdx_run`'s queue (`:10154`).

Tests naming these globals (2): `t_geometry.m`, `t_vbuf.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:4917` | `g_tb2_stage` | staging of texture-buffer row copies; the view lives until the submission is done | `tbuf_rows_copy` | — | `g_sub_mu`, `g_rmu` | `defer_obj_release` |
| `:5427` | `g_vbuf_unaligned` | vertex streams copied because their address is not aligned (`vbuf_copy`, `:5426`) | `vbuf_prepare`, `vbuf_unaligned` | — | `g_sub_mu` | guest writes and pool remaps (`:5420`); `g_vbuf_write_epoch` |
| `:5428` | `g_vbuf_write_epoch` | epoch bumped by shader writes: invalidates vertex-stream snapshots | `swrite_note` | `vbuf_unaligned` | `g_sub_mu` | bumped by `swrite_note` |
| `:5429` | `g_vbuf_need` | per stream: the bytes the draw reads when more than the bound size, else 0 | `vbuf_need` | `bind_vbufs`, `geo_capture_one`, `pull_layout_fill`, `vbuf_prepare` | `g_sub_mu` | per draw (`vbuf_need`) |
| `:5921` | `g_ir` | index ranges seen (hash map) | `ix_range` | `vc_gpu_write`, `vc_stat` | `g_sub_mu` | — |
| `:5922` | `g_vc_rgn`, `g_vc_stat`, `g_vc_conv`, `g_vc_whole`, `g_vc_checks`, `g_vc_bad` | 1 MB regions holding a kept index range; vertex conversion counters | `ix_range`, `vc_rgn_mark`, `vc_stat`, `vconv_bind` | `vc_rgn_hit` | `g_sub_mu` | — |
| `:5973` | `g_vconv`, `g_vconv_next` | one vertex conversion per (range, format, layout) in this submission (`:5972`) | `vconv_bind` | `geo_sync_cpu` | `g_sub_mu` | `g_sub_serial` |
| `:7589` | `g_tbs_blk`, `g_tbs_off`, `g_tbs_views` | texture-buffer shadow block, offset and views | `tbuf_shadow` | — | `g_sub_mu`, `g_rmu` | — |
| `:7590` | `g_tbs_cache` | texture-buffer shadow cache | `tbuf_shadow` | — | `g_sub_mu`, `g_rmu` | — |
| `:7591` | `g_tbs_copies` | texture-buffer shadow copy counter | `tbuf_shadow` | — | `g_sub_mu`, `g_rmu` | — |
| `:9919` | `g_ixc`, `g_ixc_n`, `g_ixc_epoch`, `g_ixc_sub`, `g_ixc_runs`, `g_ixc_splits` | indirect-draw conversions (128), with epoch and submission | `ixc_find`, `ixc_run`, `ixc_take` | — | `g_sub_mu` | `g_wr_epoch`, `g_sub_serial` |
| `:10000` | `g_wide`, `g_wide_n`, `g_wide_epoch`, `g_wide_sub`, `g_wide_runs`, `g_wide_draws`, `g_wide_splits` | 8-bit index conversions (256), with epoch and submission | `wide_find`, `wide_run`, `wide_take` | — | `g_sub_mu` | `g_wr_epoch`, `g_sub_serial` |
| `:10097` | `g_mdi_ev`, `g_mdi_v`, `g_mdi_waits`, `g_mdi_epoch`, `g_mdi_sub`, `g_mdi_addr`, `g_mdi_count` | event, value and keys of the multi-draw-indirect CPU wait | `mdi_live`, `mdi_wait` | `geo_sync_cpu`, `mdx_run` | `g_sub_mu` | `g_wr_epoch`, `g_sub_serial` |
| `:10134` | `g_mdx`, `g_mdx_n`, `g_mdx_tag`, `g_mdx_ep`, `g_mdx_sub`, `g_mdx_runs`, `g_mdx_splits`, `g_mdx_draws`, `g_mdx_fast`, `g_mdx_stop` | indirect-count multi-draw records (16384) with tag, epoch and submission | `mdx_next`, `mdx_run`, `mdx_slot`, `mtl_exec` | `mdx_find` | `g_sub_mu` | `g_mdx_epoch`, `g_sub_serial` |
| `:10195` | `g_mdxc` | chain of back-to-back draws of one multi-draw (`:10193-10194`) | `draw_`, `mdx_chain`, `mdx_next` | — | `g_sub_mu` | any op between them |

### T8 Store lookahead, attachment ledger, zero-source skip, lazy clears

Store lookahead (`:3668`, its index `:8827`), the cross-submission attachment validity ledger (`:3754`), the zero-source skip (`:3452`) and lazy clears (`:10220`).

Tests naming these globals (3): `t_attachment_capacity.m`, `t_image_attachment_store.m`, `t_xv.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:760` | `g_zskip_zero`, `g_zskip_n`, `g_zskip_count` | textures known to be all zero (zero-source skip), count | `draw_`, `mtl_sub_begin`, `zskip_add`, `zskip_clear`, `zskip_del` | `zskip_can_draw`, `zskip_has`, `zskip_test_count` | `g_sub_mu` | `zskip_clear` at `mtl_sub_begin` (`:838`) |
| `:761` | `g_zskip_cand`, `g_zskip_cand_ok` | zero clears of the pass being opened (candidates) | `clr_note`, `rp_begin_ex_`, `udc_note_draw` | `zskip_can_draw`, `zskip_clear`, `zskip_commit_clears` | `g_sub_mu` | per pass |
| `:3456` | `g_zskip_facts` | zero-source facts added by tests (`zskip_test_add`) | `zskip_test_add` | `zskip_fact_for` | `g_sub_mu` | — |
| `:3457` | `g_zskip_nf` | their count | `zskip_test_add` | `zskip_fact_for` | `g_sub_mu` | — |
| `:3675` | `g_sd`, `g_nsd` | store-lookahead decision per attachment of the open pass | `clr_note`, `rp_begin_ex_`, `sd_finish`, `sdx_decide`, `udc_note_draw` | — | `g_sub_mu` | per pass (`sd_finish`) |
| `:3767` | `g_xv`, `g_xv_n`, `g_xv_block`, `g_xv_init` | cross-submission attachment validity ledger (`xv_ent`) | `mtl_sub_index_`, `xv_drop`, `xv_drop_all_of`, `xv_find`, `xv_forward` +2 | `rp_begin_ex_` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | entries dropped by `xv_drop`, `xv_drop_all_of` |
| `:3768` | `g_xv_disabled`, `g_xv_ndis` | ledger keys disabled after a violation | `xv_init`, `xv_violation` | `xv_disabled` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | — |
| `:3769` | `g_xv_trial`, `g_xv_ntrial` | consecutive compliant touches per key | `xv_trial_get` | — | `g_sub_mu` | — |
| `:3771` | `g_xv_present`, `g_xv_npresent` | window and external textures that never enter the ledger | `mtl_xv_window_tex`, `present_enqueue` | `xv_present` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | — |
| `:3772` | `g_xv_dc`, `g_xv_viol` | ledger counters: don't-care stores, violations | `sd_finish`, `xv_violation` | `xv_test_counts` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | — |
| `:3774` | `g_xv_touch`, `g_xv_ntouch` | ledger touches of this submission | `mtl_sub_index_`, `xv_touch_add` | `xv_first_good` | `g_sub_mu` | `mtl_sub_index_` |
| `:8835` | `g_sdx`, `g_sdx_tmp`, `g_sdx_n`, `g_sdx_cap`, `g_sdx_ok` | store-lookahead index of this submission: events, valid flag | `mtl_sub_index_`, `sdx_bucket`, `sdx_ev_add`, `sdx_seq`, `sdx_walk` | `defer_pre`, `fz_prefilter`, `sdx_decide`, `xv_forward` | `g_sub_mu` | rebuilt by `mtl_sub_index_` |
| `:8838` | `g_sdx_hk`, `g_sdx_hb`, `g_sdx_nb`, `g_sdx_bcnt`, `g_sdx_bst` | hash buckets of that index | `mtl_sub_index_`, `sdx_bucket` | `defer_pre`, `fz_prefilter`, `sdx_decide`, `xv_forward` | `g_sub_mu` | rebuilt by `mtl_sub_index_` |
| `:8847` | `g_sdx_op`, `g_sdx_nop`, `g_sdx_opcap` | op pointers of that index | `mtl_sub_index_`, `sdx_walk` | `defer_pre`, `fz_prefilter`, `sdx_decide`, `sdx_seq` | `g_sub_mu` | rebuilt by `mtl_sub_index_` |
| `:8849` | `g_pp_slot`, `g_pp_prog`, `g_pp_cprog`, `g_pp_rt`, `g_pp_rtseq` | per-slot texture, image, program and target tables of that index | `mtl_sub_index_`, `sdx_walk` | — | `g_sub_mu` | rebuilt by `mtl_sub_index_` |
| `:8850` | `g_rtx_seq`, `g_drx_seq`, `g_rtx_n`, `g_rtx_cap`, `g_drx_n`, `g_drx_cap` | this submission's SET_RT and draw sequence tables (readable tile merge pre-screen) | `mtl_sub_index_`, `sdx_walk` | `fz_prefilter` | `g_sub_mu` | rebuilt by `mtl_sub_index_` |
| `:10220` | `g_lc`, `g_nlc` | clears waiting for the next pass that attaches the same subresource (`:10212-10217`) | `lc_land`, `lc_push`, `lc_sampled`, `lc_take` | `cs_hoist_try`, `draw_`, `mtl_exec` | `g_sub_mu` | landed by `lc_land` |

### T9 Replay rewrites: load elision, deferred draws, fusion, hoists

Replay rewrites that look ahead and re-encode: first-draw load elision (`:3820-3822`), deferred draws (`:8297-8303`), pass fusion (`:8284`, its check `:9051`) and hoists (`:8248`, compute `:10309`). They save and restore `S` and `R` (constraint 1). Moves with it: `fuse_try`'s scratch (`:9425`, `:9445`), `cs_hoist_try`'s ranges (`:10372`, `:10389`), `defer_replay`'s `lm` (`:9204`).

Tests naming these globals (6): `t_defer_chain.m`, `t_fuse_check.m`, `t_image_attachment_store.m`, `t_perf_order.m`, `t_pso_warm.m`, `t_queue_origin.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:3820` | `g_fd_dw`, `g_fd_di` | the draw that opens the pass, while `draw` opens it (first-draw load elision) | `draw_`, `fz_probe_cov2` | `first_draw_covers`, `rp_begin_ex_` | `g_sub_mu` | per pass |
| `:3821` | `g_fd_n` | attachments judged elidable (cumulative counter) | `rp_begin_ex_` | — | `g_sub_mu` | — |
| `:3822` | `g_fd_why` | reason of the last elision failure (PASSDUMP `Q` line) | `first_draw_covers`, `fz_probe_cov2` | `rp_begin_ex_` | `g_sub_mu` | — |
| `:3848` | `g_defer_replaying` | a deferred-draw group is being replayed | `defer_fallback`, `defer_replay`, `defer_reset` | `cs_hoist_try`, `defer_try`, `draw_`, `fb_prepare`, `geo_run_walk` +2 | `g_sub_mu` | `defer_replay`, `defer_reset` |
| `:6093` | `g_pso_lmap`, `g_pso_fsfn`, `g_pso_fz`, `g_fz_desc` | pipeline-key overrides used while deferred or fused draws replay: layout map, fragment function, fusion descriptors | `defer_fallback`, `defer_replay`, `draw_`, `fz_p2_draw` | `draw_color_writes`, `pso_get_`, `pso_key_fill` | `g_sub_mu` | set and cleared around the replay (`defer_replay` `:9208`) |
| `:8248` | `g_hoist_skip`, `g_hoist_n`, `g_hoist_groups` | ops hoisted ahead and to skip later, and their groups | `fuse_try`, `fz_unskip`, `hoist_take`, `hoist_try`, `mtl_exec` | `defer_pre`, `defer_try`, `ds_scan`, `fz_next`, `fz_prefilter` +3 | `g_sub_mu` | per submission |
| `:8284` | `g_fz`, `g_fz_n`, `g_fz_draws`, `g_fz_fallback` | the open pass fusion (`fuse_t`) and its counters | `draw_`, `fuse_try`, `fz_end`, `fz_p2_draw`, `fz_probe_cov2` +1 | `defer_try`, `fb_prepare`, `fz_load_covers`, `fz_reuse_op`, `fz_unskip` +2 | `g_sub_mu` | `fz_end` |
| `:8297` | `g_defer_slots` | deferred-draw groups (4 slots) | `defer_begin_q`, `defer_clear_all`, `defer_fallback`, `defer_next`, `defer_replay` +2 | `defer_slot_free` | `g_sub_mu` | `defer_clear_all` |
| `:8298` | `g_defer_cur` | the group being recorded | `defer_begin_q`, `defer_fallback`, `defer_replay`, `defer_try` | `defer_apply_p_clear`, `defer_q_superset`, `defer_release`, `defer_rt_hits_reads`, `defer_take` +1 | `g_sub_mu` | `defer_reset` |
| `:8301` | `g_defer_n`, `g_defer_draws`, `g_defer_fallbacks` | deferred-draw counters | `defer_fallback`, `defer_take`, `defer_try` | — | `g_sub_mu` | — |
| `:8302` | `g_defer_pend` | end op of the group in its P range (NULL if none) | `defer_clear_all`, `defer_release_one`, `defer_try`, `mtl_exec` | `defer_has_in_p`, `sub_cut` | `g_sub_mu` | `defer_release_one`, `defer_clear_all` |
| `:8303` | `g_defer_nact`, `g_defer_natq` | active groups; groups waiting for replay | `defer_begin_q`, `defer_clear_all`, `defer_release_one`, `defer_try` | `defer_has_active`, `draw_`, `sub_cut` | `g_sub_mu` | `defer_clear_all` |
| `:8321` | `g_ds_why`, `g_ds_scanned`, `g_ds_need` | depth-stencil use scan: need, and diagnostics of the last verdict | `ds_scan`, `pass_ds_need` | — | `g_sub_mu` | per scan (`ds_scan`) |
| `:9051` | `g_fzs`, `g_nfzs`, `g_fzs_bad`, `g_fz_checking`, `g_fzc_same`, `g_fzc_diff` | fusion check snapshots (8), checking flag, same / different counters | `fz_check_run` block `:9085`, `fz_check_run`, `fz_end`, `fz_snap_take` | `cs_hoist_try`, `defer_try`, `draw_` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `fz_check_run` |
| `:10309` | `g_csh_op`, `g_csh_n`, `g_csh_moved`, `g_csh_depth`, `g_csh_stop` | compute hoist: dispatches run ahead and not yet met by replay; counters | `cs_hoist_try`, `csh_take` | `mtl_cshoist_stats`, `mtl_exec` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `csh_take` |

### T10 Geometry emulation and transform feedback

`nvn_geometry.inc` emulates geometry shaders; `nvn_feedback.inc:4` holds the transform-feedback state. Its switches (`nvn_geometry.inc:212`, `:231`, `:527-528`) are in G9, its pipelines (`nvn_geometry.inc:9`) in G7, its counters in G12 and the mesh pipeline cache (`nvn_geometry.inc:404-405`) in G6. Moves with it: `geo_color_omit` (`nvn_geometry.inc:271`), `geo_mesh_prims` (`nvn_geometry.inc:374`), `geo_run_walk`'s scratch (`nvn_geometry.inc:764`).

Tests naming these globals (2): `t_geometry.m`, `t_geometry_hazards.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `nvn_geometry.inc:3` | `g_geo_program` | program of the geometry draw being emulated | `geo_mesh_draw`, `geo_raster` | `draw_` | `g_sub_mu` | per draw (`geo_raster`) |
| `nvn_geometry.inc:4` | `g_geo_indices`, `g_geo_index_bytes`, `g_geo_args` | index buffer address, bytes and indirect arguments of that draw | `geo_raster` | `draw_` | `g_sub_mu` | per draw |
| `nvn_geometry.inc:5` | `g_geo_vrange` | its vertex-range draw | `geo_raster` | `draw_` | `g_sub_mu` | per draw |
| `nvn_geometry.inc:6` | `g_geo_count` | its primitive count | `geo_raster` | `draw_` | `g_sub_mu` | per draw |
| `nvn_geometry.inc:160` | `g_geo_split_depth` | > 0 while `geo_split` draws its runs: they skip the GPU wait | `geo_split` | `geo_draw_`, `geo_prep`, `geo_run_walk` | `g_sub_mu` | `geo_split` |
| `nvn_geometry.inc:227` | `g_geo_ix` | CPU primitive maps keyed by the original index bytes (`:216-219`) | `geo_ix_drop`, `geo_ix_get`, `geo_ix_put` | — | `g_sub_mu` | every reuse compares the original bytes |
| `nvn_geometry.inc:228` | `g_geo_ix_first`, `g_geo_ix_last` | LRU list of those entries | `geo_ix_front`, `geo_ix_unlink` | `geo_ix_put` | `g_sub_mu` | — |
| `nvn_geometry.inc:229` | `g_geo_ix_bytes` | bytes they hold | `geo_ix_drop`, `geo_ix_put` | — | `g_sub_mu` | — |
| `nvn_geometry.inc:230` | `g_geo_ix_hits`, `g_geo_ix_misses` | hit and miss counters | `geo_ix_get` | — | `g_sub_mu` | — |
| `nvn_geometry.inc:371` | `g_geo_mesh` | mesh-path state of the current draw | `draw_`, `geo_mesh_draw` | `geo_mesh_encode`, `geo_mesh_pso` | `g_sub_mu` | per draw |
| `nvn_geometry.inc:379` | `g_geo_mesh_last` | one-entry cache: vertex shader and lean kernel to mesh function | `geo_mesh_fn`, `geo_mesh_pso` | — | `g_sub_mu` | a different shader pair |
| `nvn_geometry.inc:487` | `g_geo_run` | geometry jobs queued in the current run (64) | `geo_draw_`, `geo_run_walk` | — | `g_sub_mu` | `geo_draw_` |
| `nvn_geometry.inc:525` | `g_geo_nrun` | their count | `geo_draw_` | — | `g_sub_mu` | `geo_draw_` |
| `nvn_feedback.inc:4` | `g_tf_state` | transform-feedback state buffer | `tf_state_gpu` | `tf_prepare` | `g_sub_mu` | — |

### T11 Render pass state (`R`)

`R` (`:3445-3450`) and the state of the open render pass. `queue_state` copies `R` per queue (`:5678`).

Tests naming these globals (39): `t_alpha.m`, `t_attachment_capacity.m`, `t_clear_ds.m`, `t_clear_layers.m`, `t_clear_tex.m`, `t_cpu_tex.m`, `t_defer_chain.m`, `t_depth16_clear.m`, `t_feedback.m`, `t_fuse_check.m`, `t_geometry.m`, `t_geometry_feedback.m`, `t_geometry_hazards.m`, `t_geometry_primitive_id.m`, `t_image_alias.m`, `t_image_attachment_store.m`, `t_image_primitive_id.m`, `t_image_usage.m`, `t_linear_readback.m`, `t_logic.m`, `t_mip_extent.m`, `t_perf_order.m`, `t_present_snap.m`, `t_primitive_restart.m`, `t_pso_depth_stencil.m`, `t_pso_pending.m`, `t_pso_warm.m`, `t_queue_origin.m`, `t_rast_discard.m`, `t_readback.m`, `t_reorder_chain.m`, `t_rt_depth_ro.m`, `t_rt_range.m`, `t_sparse_tex.m`, `t_transform_feedback.m`, `t_ubp_running.m`, `t_unwritten_store.m`, `t_xv.m`, `t_zskip.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:3450` | `R` | `R`: the render targets set, pending clears and scissor (`:3445-3450`) | `clear_color_tri`, `clear_rect_zero`, `cs_hoist_try`, `defer_apply_p_clear`, `defer_begin_q` +19 | `bare_dims`, `clear_ds_tri`, `clr_note`, `clr_scissor`, `csh_attachment_hit` +28 | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | copied per queue (`mtl_queue_activate` `:5680`) |
| `:862` | `g_pass_swrite` | the open draw pass has shader writes | `rp_begin_ex_`, `swrite_note` | `mtl_exec` | `g_sub_mu` | per pass (`rp_begin_ex_`) |
| `:863` | `g_pass_order` | ordering barriers came after the pass's draws, none of which wrote | `mtl_exec`, `order_draw`, `rp_begin_ex_` | — | `g_sub_mu` | per pass |
| `:864` | `g_pass_late_res` | a draw of the open pass reads memory after the vertex stage | `order_note`, `rp_begin_ex_` | `order_draw` | `g_sub_mu` | per pass |
| `:865` | `g_order_vbar` | ordering barriers kept inside the pass as vertex-to-vertex barriers (counter) | `order_draw` | — | `g_sub_mu` | — |
| `:866` | `g_imfit_npend` | textures an image slot needs a format view of, upgraded before the next pass | `img_fit`, `img_fit_upgrade` | `rp_begin_ex_` | `g_sub_mu`, `g_rmu` | per pass (`img_fit_upgrade`) |
| `:867` | `g_last_end_relaxed`, `g_game_barrier` | the last encoder ended was a relaxed draw pass; the game issued a barrier since the last pass began | `enc_r_begin_pass`, `enc_r_end_pass`, `m4_end`, `mtl_exec` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `m4_end` clears the first (`:876`) |
| `:868` | `g_sp_mapped` | a sparse mapping was emitted for the open pass | `enc_r_begin_pass`, `sp_emit` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | per pass (`enc_r_begin_pass`) |
| `:869` | `g_sp_relaxed` | the open render encoder, for sparse-mapping barriers (unretained) | `enc_r_begin_pass` | `sp_emit` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | per pass |
| `:3482` | `g_pass` | target info of the current render pass, computed once at `rp_begin` | `draw_`, `rp_begin_ex_`, `rt_range_note_depth`, `sm_plan` | `at_bind`, `clear_color_tri`, `clear_ds_tri`, `clr_scissor`, `encode_args_` +7 | `g_sub_mu` | per pass; `reg_gen` / `ser_gen` / `range_dirty` fields checked against the generations (`:4047`) |
| `:3483` | `g_rp_layered` | the pass about to open is for a vertex shader that writes the layer | `draw_` | `rp_begin_ex_` | `g_sub_mu` | per pass |
| `:3489` | `g_sm_plan` | slice-merge plan of the pass about to open | `draw_`, `sm_plan` | `rp_begin_ex_` | `g_sub_mu` | per pass |
| `:3490` | `g_sm_pass`, `g_sm_lo`, `g_sm_hi`, `g_sm_cur`, `g_sm_applied` | the open pass is slice-merged: layers, current layer, offset applied | `draw_`, `mtl_exec`, `rp_begin_ex_`, `rp_end` | — | `g_sub_mu` | per pass |
| `:3492` | `g_pso_amp` | pipeline of a slice-merged pass | `draw_`, `sm_plan` | `pso_get_` | `g_sub_mu` | per pass |
| `:3835` | `g_enc_mode` | how the current encoder was opened (all, clears only, depth omitted) | `rp_begin_ex_` | `clear_color_tri`, `clear_ds_tri`, `draw_`, `fuse_try`, `mtl_exec` +1 | `g_sub_mu` | per pass |
| `:3838` | `g_geo_omit_colors`, `g_enc_geo_nocolor` | the synthetic geometry raster pass omits colours | `geo_mesh_draw`, `geo_raster`, `rp_begin_ex_`, `rp_end` | `draw_` | `g_sub_mu` | per pass |
| `:3839` | `g_rt_range_active`, `g_rt_range_pending` | render-target range state of the open pass | `draw_`, `mtl_exec`, `rp_end` | — | `g_sub_mu` | per pass |
| `:3843` | `g_rp_aw`, `g_rp_ah` | area of a scissored pass (`:3840-3842`) | `rp_begin_ex_` | `draw_`, `rp_begin` | `g_sub_mu` | per pass |
| `:3845` | `g_rp_whole` | the pass about to open must cover the whole target | `rp_begin` | `rp_begin_ex_` | `g_sub_mu` | per pass |
| `:3846` | `g_rt_merged` | the current pass has been continued by a same-target SET_RT | `mtl_exec`, `rp_end` | `draw_`, `sub_cut` | `g_sub_mu` | per pass |
| `:3853` | `g_el_w`, `g_el_h`, `g_el_draws`, `g_el_key` | encoder label of the open pass (`DM_NVN_ENC_LABEL`) | `draw_`, `rp_begin_ex_` | `rp_end` | `g_sub_mu` | per pass |
| `:3855` | `g_nbcrt` | shadows of block-compressed render targets of the open pass | `bcrt_attach`, `bcrt_flush` | `bcrt_is`, `defer_fallback`, `rp_end` | `g_sub_mu` | `bcrt_flush` |
| `:3861` | `g_rtm`, `g_nrtm` | render-target mirrors of the open pass (`:3856-3860`) | `rt_mirror_add`, `rt_mirror_flush`, `rt_mirror_layers` | `rp_begin_ex_`, `rp_end` | `g_sub_mu` | `rt_mirror_flush` |
| `:3936` | `g_bcrt` | block-compressed render-target shadows | `bcrt_attach`, `bcrt_flush` | `bcrt_is` | `g_sub_mu` | `bcrt_flush` |
| `:3937` | `g_bcrt_sh`, `g_bcrt_buf` | their textures and buffers | `bcrt_attach` | — | `g_sub_mu` | `bcrt_flush` |
| `:5262` | `g_imfit_pend` | image slots waiting for a format-view upgrade | `img_fit` | `img_fit_upgrade` | `g_sub_mu`, `g_rmu` | `img_fit_upgrade` |
| `:7757` | `g_draw_seq`, `g_fb_seq`, `g_fb_count`, `g_fb_n`, `g_fb_rebind` | same-pass feedback snapshot substitution: sequence numbers and counts | `fb_prepare` | `encode_args_` | `g_sub_mu` | per pass (`fb_prepare`) |
| `:7758` | `g_fb_src`, `g_fb_use`, `g_fb_rid` | the snapshot textures used for it (unretained) | `fb_prepare` | `encode_args_` | `g_sub_mu` | per pass |
| `:8785` | `g_samples_fb_left` | a fragment texture that is a colour attachment does not count (`draw_samples_rt`) | `draw_` | `draw_samples_rt` | `g_sub_mu` | per draw |
| `:9815` | `g_fb_bar`, `g_fb_reuse`, `g_fb_split` | game barriers, snapshot reuses and passes ended before an attachment write (counters) | `fb_prepare`, `mtl_exec` | `fb_snap` | `g_sub_mu` | — |
| `:9816` | `g_fb_pass`, `g_fb_wmask`, `g_fb_rmask`, `g_fb_dread` | the current Metal pass: colour attachments written, sampled, depth read | `fb_pass_sync`, `fb_prepare` | — | `g_sub_mu` | per pass (`fb_pass_sync`) |
| `:9818` | `g_fbc`, `g_fbc_next` | snapshot cache of feedback sampling (8) | `fb_snap` | — | `g_sub_mu` | — |

### T12 Draw state (`S`) and queue states

`S` (`:5387-5403`), the per-queue copies (`:5678-5700`), and per-draw values `encode_args_` reads (`:7917-7938`). Moves with it: the ring of combined programs in `bind_stages` (`:5638`), `prog_get`'s one-entry cache (`:4766`), the static `Ssave` copies of `pso_predict_rest_`, `fz_probe_cov2`, `fz_check_run` and `cs_hoist_try` (constraint 1) and `pso_predict_rest_`'s scratch (`:8563`). `g_origin_ll` (`:5079`, the device origin, atomic, set by `mtl_set_origin_lower_left` `:5080`) stays in G9; `g_queue_origin_ll` (`:5081`) moves.

Tests naming these globals (23): `t_alpha.m`, `t_feedback.m`, `t_fuse_check.m`, `t_geometry.m`, `t_geometry_hazards.m`, `t_geometry_primitive_id.m`, `t_gl_imports.m`, `t_image_attachment_store.m`, `t_image_primitive_id.m`, `t_image_usage.m`, `t_logic.m`, `t_perf_order.m`, `t_primitive_restart.m`, `t_pso_depth_stencil.m`, `t_pso_warm.m`, `t_pull.m`, `t_queue_origin.m`, `t_reorder_chain.m`, `t_rt_depth_ro.m`, `t_transform_feedback.m`, `t_unwritten_store.m`, `t_upgrade_alias.m`, `t_vbuf.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:5403` | `S` | `S`: the draw state the game's commands set (`:5387-5403`) | `bind_stages`, `cs_hoist_try`, `defer_fallback`, `defer_replay`, `dispatch` +17 | `at_bind`, `atest_key`, `atest_on`, `attr_read`, `bare_dims` +54 | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | copied per queue (`mtl_queue_activate`); `state_reset` (`:5665`) |
| `:3500` | `g_pso_dirty`, `g_dss_dirty` | pipeline / depth-stencil state changed during replay | `copy_t2t_draw`, `cs_hoist_try`, `defer_fallback`, `defer_replay`, `draw_` +10 | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | cleared when the pipeline is bound |
| `:5664` | `g_state_inited` | state was reset once | `state_reset` | `mtl_exec` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `state_reset` |
| `:5679` | `g_queue_states`, `g_active_queue` | per-queue copies of `S` and `R`, and the active one | `mtl_queue_activate`, `mtl_queue_forget` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `mtl_queue_forget` (`:5693`) |
| `:5081` | `g_queue_origin_ll` | SET_WINDOW_ORIGIN's raster flip, queue state | `mtl_set_queue_origin_lower_left` | `cap_head`, `draw_`, `first_draw_covers` | `g_sub_mu` | set per submission by `mtl_set_queue_origin_lower_left` (`hle_nvn.c:1285`) |
| `:7917` | `g_dispatch_dim` | workgroup counts of the current dispatch (driver segment c0) | `dispatch` | `encode_args_` | `g_sub_mu` | per dispatch |
| `:7918` | `g_draw_binst` | base instance of the current draw (c0 + 0x644) | `draw_`, `geo_capture_one`, `geo_gs_one`, `geo_prep` | `encode_args_` | `g_sub_mu` | per draw |
| `:7919` | `g_c0_dim_buf`, `g_c0_dim_off` | where `encode_args` put c0 for this dispatch | `dispatch`, `encode_args_` | — | `g_sub_mu` | per dispatch |
| `:7938` | `g_geo_bind` | geometry-stage bindings of the current draw | `geo_gs_one`, `geo_mesh_encode`, `geo_raster` | `encode_args_` | `g_sub_mu` | per draw |
| `:6924` | `g_pso_pull` | the pipeline `pso_get_` returned pulls its vertex streams | `pso_get_` | `draw_` | `g_sub_mu` | per draw |

### T13 Argument encoding

Argument tables (`:100-103`), argument-buffer arenas (`:5352`), pool snapshots (`:7628-7629`), dirty flags and the generation values last seen (`:7759-7770`), and the pool GPU-address table (`:7793`). `g_arenas` changes outside `g_mu` (`arena_begin` `:5367-5373`, `arena_commit` `:5374`); `arena_alloc` takes `g_mu` only around `arena_new` (`:5380`), which reads `g_done` (`:5356`). Moves with it: the `bind_vbufs` cache (`:5503`), `at_bind` (`:6177`), `lo_bind` (`:6254`).

Tests naming these globals (15): `nvn_replay.m`, `t_capture_live.m`, `t_copy_alias.m`, `t_cpu_tex.m`, `t_geometry.m`, `t_geometry_hazards.m`, `t_linear_readback.m`, `t_link_ticks.m`, `t_mip_extent.m`, `t_present_crop.m`, `t_present_snap.m`, `t_queue_origin.m`, `t_readback.m`, `t_sparse_tex.m`, `t_vbuf.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:100` | `g_vt`, `g_ft`, `g_ct`, `g_up_ct` | argument tables: vertex, fragment, compute, upload compute | `mtl_init` | `clr_tri`, `dispatch_enc`, `enc_c_args`, `enc_c_begin`, `enc_r_args` +8 | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | made once in `mtl_init` |
| `:102` | `g_vt_addr`, `g_vt_valid` | vertex-buffer addresses bound in the vertex table and their valid bits | `enc_r_vbuf`, `mtl_init` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `mtl_init`; per bind |
| `:103` | `g_ft_addr`, `g_ct_addr`, `g_ft_valid`, `g_ct_valid` | fragment / compute table addresses and valid bits | `enc_c_args`, `enc_r_args`, `mtl_init` | — | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `mtl_init`; per bind |
| `:5352` | `g_arenas`, `g_cur_arena`, `g_sub_arenas` | argument-buffer arenas: all, current, this submission's | `arena_alloc`, `arena_begin`, `arena_commit` | `arena_new`, `draw_`, `encode_args_` | `g_sub_mu` | returned by fence (`arena_begin`, `arena_commit`) |
| `:7628` | `g_psnap`, `g_psnap_next` | pool address snapshots for argument blocks | `pool_gpu` | — | `g_sub_mu`, `g_rmu` | rebuilt by `pool_gpu` |
| `:7629` | `g_psnap_gen` | generation bumped by each rebuild: an argument block holding a pool address is not reused past it | `pool_gpu` | `encode_args_` | `g_sub_mu`, `g_rmu` | bumped by `pool_gpu`; read in `encode_args_` |
| `:7759` | `g_args_dirty` | per-stage arguments need encoding again | `encode_args_`, `geo_mesh_encode`, `state_op`, `ubd_dirty` | `args_dirty_all` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `args_dirty_all` (`:7761`), `args_sync_dirty` (`:7764-7768`) |
| `:7760` | `g_args_reg_seen`, `g_args_dirty_seen`, `g_args_ser_seen` | the `g_reg_gen`, dirty clock and `g_ser_gen` values seen when arguments were last valid | `args_sync_dirty` | — | `g_sub_mu` | compared in `args_sync_dirty` (`:7765`) |
| `:7770` | `g_args_mesh` | vertex-table slot for geometry-stage arguments shared with the mesh stage | `geo_mesh_encode` | `bind_args` | `g_sub_mu` | per draw (`geo_mesh_encode`) |
| `:7793` | `g_gmem_buf`, `g_gmem_gen` | GPU table of pool GPU addresses and its generation | `gmem_map_gpu` | — | `g_sub_mu`, `g_rmu` | rebuilt when `g_pool_gen` moves (`gmem_map_gpu` `:7795-7802`) |

### T14 Encoders and command buffers

The command buffer and the open encoders: what the sink step replaces. `g_cb` is a `DmRecCB` when the encode thread records (`rec_commit`, `nvn_rec.h:330-335`). Moves with it: `draw_`'s last pipeline and depth-stencil state (`:10550`, `:10565`).

Tests naming these globals (10): `t_copy_alias.m`, `t_feedback.m`, `t_image_attachment_store.m`, `t_image_usage.m`, `t_pfv.m`, `t_rt_depth_ro.m`, `t_rt_range.m`, `t_upload_budget.m`, `t_vbuf.m`, `t_xv.m`.

| Line | Globals | Holds | Written by | Read by | Lock | Invalidated by |
|---|---|---|---|---|---|---|
| `:764` | `g_cb` | the main command buffer of the submission (`MTL4CommandBuffer` or the recorder's) | `mdi_wait`, `mtl_sub_begin`, `mtl_sub_commit`, `sub_cut` | `blit_open`, `dlss_eval`, `enc_c_begin`, `enc_r_begin`, `enc_r_begin_pass` +9 | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | made in `mtl_sub_begin` (`:822`), nil at commit (`:1644`) |
| `:765` | `g_blit` | the open copy / compute encoder | `blit_open`, `clear_tex`, `clear_tex_tri`, `copy_t2t`, `copy_t2t_draw` +18 | `blit_barrier`, `m4_end`, `mtl_sub_update` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `m4_end`, `sub_cut`, `mtl_sub_commit` |
| `:768` | `g_blit_alias` | buffer operations of the open copy encoder used aliased GPU addresses | `blit_buf`, `m4_end`, `vbuf_unaligned` | `blit_vis` | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `m4_end` (`:874`) |
| `:1039` | `g_blit_ct` | the open copy encoder has the compute argument table set | `blit_open`, `dispatch_enc` | — | `g_sub_mu` | per copy encoder |
| `:3479` | `g_enc` | the open render encoder | `defer_fallback`, `rp_begin_ex_`, `rp_end` | `blit_note`, `draw_`, `enc_open`, `fb_pass_sync`, `fb_prepare` +14 | `g_sub_mu`; also off the submit path, see [cross-thread](#cross-thread-touches-of-moving-state) | `rp_end` |
| `:3494` | `g_enc_pso`, `g_enc_dss` | pipeline and depth-stencil state already set on this encoder | `clr_tri`, `draw_`, `geo_draw_`, `rp_begin_ex_`, `tf_note` +1 | — | `g_sub_mu` | per encoder |
| `:3497` | `g_ed` | dynamic state already sent on the open render encoder | `clr_tri`, `draw_`, `geo_draw_`, `rp_begin_ex_`, `tf_note` +1 | — | `g_sub_mu` | cleared per encoder (`:3495-3496`) |
| `:3499` | `g_enc_vis`, `g_enc_has_vis` | visibility mode of this encoder; a visibility buffer is attached | `clr_tri`, `draw_`, `rp_begin_ex_` | `mtl_exec`, `rt_range_same` | `g_sub_mu` | per encoder |

## Groups that stay global

These stay global through S3b: other threads share them, they are made once, they are process configuration, or they are diagnostics. "Lock at every write" lists the locks held at all writes (— means no one lock covers every write); "Threads" is the call-graph reach (unverified).

### G1 Device and queues

Stays because made once by `mtl_init` (`:391`, guard `if (g_dev) return` `:392`) and read from every thread.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:84` | `g_dev` | the Metal device | `mtl_init` | `geo_mesh_pso` block `nvn_geometry.inc:423`, `pso4_init` block `:6582`, `pso_desc` block `:6273`, `arena_new` +112 | — | api, enc, gcd, link, mtlcb, present, sub |
| `:90` | `g_q` | the classic command queue (`q_cb`, `:796`) | `mtl_init` | `dummy_tex`, `q_cb` | — | api, gcd, link, present, sub |
| `:91` | `g_q4` | the Metal 4 queue that submissions, uploads and presents commit to | `mtl_init` | `ext_wait`, `fx_mode`, `gpu_capture_frame`, `grab_present` +10 | — | api, enc, gcd, link, present, sub |
| `:92` | `g_classic_ok`, `g_classic` | mtl_device_classic was asked / the device has no Metal 4 and only the classic part started (mtl_init) | `mtl_device_classic`, `mtl_init` | `present_enqueue` | — | api, gcd, sub |
| `:93` | `g_feedback_q` | dispatch queue made by `mtl_init` | `mtl_init` | — | — | api, gcd, sub |

### G2 Fences, completion, deferred release, post-ops

Stays because the feedback handlers and the game's waits on other threads read and write them.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:128` | `g_ev` | shared event the submissions signal; `mtl_wait_at` waits on it | `mtl_init` | `gp_periodic_finish`, `mtl_sub_commit`, `mtl_wait_at` | — | api, gcd, link, present, sub |
| `:129` | `g_fence` | Highest committed fence value (incremented exclusively by the submit thread) | `mtl_sub_commit` | `alias_take_over`, `arena_begin`, `defer_obj_release_ex`, `gml_take` +14 | `g_sub_mu`, atomic | api, gcd, link, present, sub |
| `:131` | `g_mu` | lock, see [locks.md](locks.md) | — | — | — | api, gcd, link, mtlcb, present, sub |
| `:132` | `g_cv` | lock, see [locks.md](locks.md) | — | — | `g_mu` | api, gcd, link, mtlcb, present, sub |
| `:133` | `g_done` | GPU complete and all CPU-visible effects through this fence published | `post_complete` | `arena_begin`, `arena_new`, `defer_drain`, `gw_commit` +8 | `g_mu`, atomic | api, gcd, link, mtlcb, present, sub |
| `:168` | `g_last_commit_error` | a commit reported an error (set by commit feedback blocks) | `mtl_sub_commit` block `:1627`, `sub_cut` block `:11553`, `mtl_sub_begin` | `mtl_last_commit_error` | atomic | mtlcb, sub |
| `:169` | `g_up_pending` | upload batches committed and not complete | `up_flush` block `:2170`, `mtl_finish_gpu_at`, `q_cb`, `up_flush` | `mtl_wait_state_dump` | atomic | api, gcd, link, mtlcb, present, sub |
| `:280` | `g_deferred` | objects waiting for a fence before release (`defer_obj_release_ex`, `defer_drain`) | `defer_obj_release_ex` | `cctx_snap`, `defer_drain`, `mtl_mem_stat`, `up_diag` | `g_deferred_mu` | api, gcd, link, mtlcb, present, sub |
| `:281` | `g_deferred_mu` | lock, see [locks.md](locks.md) | — | — | — | api, gcd, link, mtlcb, present, sub |
| `:783` | `g_sub_thread`, `g_sub_thread_set` | the submit thread (set by `mtl_sub_begin`), read by `on_sub_thread` | `mtl_sub_begin` | `mtl_wait_state_dump`, `on_sub_thread`, `tex_init_fill`, `tex_zero_fill` +1 | `g_sub_mu`, atomic | api, gcd, link, present, sub |
| `:1557` | `g_postr` | post-op records per fence, run at completion (`post_complete`) | `mtl_sub_commit`, `post_complete` | — | — | api, gcd, link, mtlcb, present, sub |
| `:1558` | `g_post_mu` | lock, see [locks.md](locks.md) | — | — | — | api, gcd, link, mtlcb, present, sub |
| `:2089` | `g_upload_gpu_ns` | GPU time of upload batches | `up_flush` block `:2170`, `mtl_upload_gpu_ns_take` | — | atomic | api, mtlcb |
| `:2092` | `g_up_alloc_busy` | upload slots in use | `up_flush` block `:2170`, `up_begin` | `mtl_wait_state_dump` | atomic | api, link, mtlcb, present, sub |
| `:2095` | `g_up_wmu`, `g_up_wcv` | lock, see [locks.md](locks.md) | — | — | — | api, gcd, link, mtlcb, present, sub |
| `:2138` | `g_up_lost`, `g_up_lost_lk`, `g_up_lost_n`, `g_up_lost_redo` | textures dropped from an upload batch before it ran (weak table), its lock and counters (`:2132-2138`) | `up_flush` block `:2170`, `up_lost_take` | `sp_reconcile`, `tex_mtl_` | `g_up_lost_lk`, atomic | api, link, mtlcb, present, sub |
| `:900` | `g_cur_frame` | the frame number (`mtl_set_frame`) | `mtl_set_frame` | `blit_note`, `cap_head`, `cctx_snap`, `clear_color_tri` +57 | atomic | api, link, present, sub |

### G3 Residency

Stays because one residency set for the process; `res_add` runs on guest threads too (`:217`).

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:126` | `g_res` | the residency set | `mtl_init` | `res_add_at`, `res_commit`, `res_remove` | — | api, gcd, link, mtlcb, present, sub |
| `:127` | `g_res_dirty` | the set has changes to commit | `res_add_at`, `res_commit`, `res_remove` | — | `g_res_mu` | api, gcd, link, mtlcb, present, sub |
| `:171` | `g_res_mu` | lock, see [locks.md](locks.md) | — | — | — | api, enc, gcd, link, mtlcb, present, sub |
| `:211` | `g_res_objects` | objects in the residency set | `res_add_at` | `defer_drain`, `mtl_mem_stat`, `res_check`, `res_remove` +1 | `g_res_mu` | api, gcd, link, mtlcb, present, sub |
| `:212` | `g_image_heap_n` | live image heaps (`resource_vis` and the pass barriers read it) | `- dealloc`, `image_texture` | `enc_r_begin_pass`, `enc_r_end_pass`, `resource_vis` | atomic | api, gcd, link, present, sub |
| `:215` | `g_rs_site`, `g_rs_rm`, `g_rs_commits`, `g_rs_commit_ns` | residency churn by call site, removals, commits, commit time (`mtl_res_stats`) | `mtl_res_stats`, `res_add_at`, `res_commit`, `res_remove` | — | `g_res_mu` | api, gcd, link, mtlcb, present, sub |
| `:246` | `g_image_heap_owner_key` | associated-object key of an image heap owner (`image_texture`) | `image_texture` | — | — | api, link, present, sub |
| `:248` | `g_res_check_on` | `DM_RES_CHECK`: check argument resources against the residency set (`res_check`) | `mtl_init` | `encode_args_`, `res_check` | — | api, gcd, sub |

### G4 Memory pools and GPU addresses

Stays because pools are created and finalized by API calls on any guest thread.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:347` | `g_pools`, `g_npool`, `g_cap` | pool table: entries, count, capacity | `mtl_pool_add`, `mtl_pool_del` | `cap_pools`, `gmem_map_gpu`, `gml_read`, `mtl_addr` +8 | `g_mu` | api, link, mtlcb, present, sub |
| `:348` | `g_pidx_ok`, `g_plast` | whether the address→pool index is valid, the last hit (pool_find) | `mtl_pool_add`, `mtl_pool_del`, `pidx_sort`, `pool_find` | — | `g_mu` | api, link, mtlcb, present, sub |
| `:349` | `g_keep` | Holds the buffer references (pool_ent has non-owning pointers) | `mtl_init` | `mtl_pool_add`, `mtl_pool_del` | — | api, gcd, sub |
| `:350` | `g_pool_adds` | pools added (counter) | `mtl_pool_add` | `mtl_res_snapshot` | `g_mu` | api |
| `:351` | `g_pool_res_n` | registered pools already in the residency set (for the memory readout; under g_mu) | `gmem_map_gpu`, `mtl_pool_del`, `pool_res` | `mtl_mem_stat` | `g_mu` | api, link, present, sub |
| `:496` | `g_dead_pools` | No-copy buffers of finalized pools (weak references, under g_mu): the memory report counts how many are still ... | `mtl_pool_del` | `mtl_mem_stat` | `g_mu` | api |
| `:502` | `g_pool_gen` | pool table generation | `mtl_pool_add`, `mtl_pool_del` | `bind_vbufs`, `gmem_map_gpu`, `pc_get`, `pc_put` +1 | `g_mu`, atomic | api, link, present, sub |
| `:504` | `t_pc` | per-thread cache of pool lookups, with the `g_pool_gen` it was filled under (thread-local) | `pc_get`, `pc_put` | — | thread-local | api, link, present, sub |
| `:576` | `g_pidx`, `g_pidx_cap` | pool indices sorted by start address (`pool_find`) | `pidx_sort` | `gmem_map_gpu`, `pool_find` | `g_mu` | api, link, mtlcb, present, sub |

### G5 Registries, serial table, aliases, CPU-written textures

Stays because API calls register textures and samplers on any guest thread; S4 redesigns the registry view (plan.md S4). `t_tex_sampled` (`:2670`) is thread-local and stays so: `tex_rid_` (`:5298-5299`) and `draw_tex` (`:11220`) set it around their own lookup, and `tex_cpu_content` (`:2679`) reads it on whichever thread resolves a texture.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:519` | `g_reg_gen` | registration generation: pools, textures, samplers | `mtl_pool_add`, `mtl_pool_del`, `mtl_reg_samp`, `mtl_reg_tex` | `args_sync_dirty`, `draw_`, `pool_gpu`, `rp_begin_ex_` +1 | atomic | api, sub |
| `:2670` | `t_tex_sampled` | the texture being resolved is sampled (thread-local; set around the lookup of `tex_rid_` and `draw_tex`) | `draw_tex`, `tex_rid_` | `tex_cpu_content` | thread-local | api, link, present, sub |
| `:1736` | `g_by_serial` | Serial → MTLTexture / NvPkg / NvProg | `alias_take_over`, `prog_serial_del`, `prog_serial_put`, `serial_del` +5 | `mtl_mem_stat`, `mtl_res_snapshot` | `g_smu` | api, link, present, sub |
| `:1737` | `g_smu` | lock, see [locks.md](locks.md) | — | — | — | api, link, mtlcb, present, sub |
| `:1739` | `g_ser_gen` | serial table generation: entries added or removed, or a packaged texture replaced (`:1738`) | `up_flush` block `:2170`, `alias_take_over`, `mtl_alias_drop_pool`, `mtl_tex_cpu_written` +7 | `args_sync_dirty`, `cctx_snap`, `draw_`, `pool_gpu` +6 | atomic | api, link, mtlcb, present, sub |
| `:1745` | `g_alias` | texture sharing table: textures over the same storage | `alias_take_over`, `cap_tex_read`, `mtl_alias_drop_pool`, `tex_mtl_` +1 | `image_texture`, `mtl_mem_stat`, `tex_upgrade` | `g_smu` | api, link, present, sub |
| `:1746` | `g_alias_seen` | key → g_fence + 1 at its last lookup or creation (alias_take_over spares entries looked up lately) | `alias_take_over`, `mtl_alias_drop_pool`, `tex_mtl_` | — | `g_smu` | api, link, present, sub |
| `:1749` | `g_image_desc` | serial → malloc'ed tex_t, under g_smu | `image_desc_drop_pool`, `mtl_tex_init`, `mtl_tex_release` | `image_texture` | `g_smu` | api, link, present, sub |
| `:1762` | `g_alias_set` | Textures in the sharing table (non-owning; used to ask "is this shared") | `tex_mtl_` | `alias_has`, `alias_take_over`, `mtl_alias_drop_pool`, `tex_upgrade` | `g_smu` | api, link, present, sub |
| `:1763` | `g_alias_evicted` | shared textures evicted on pool Finalize so far (for the memory report) | `mtl_alias_drop_pool` | `mtl_mem_stat` | `g_smu` | api |
| `:1803` | `g_alias_taken` | shared textures evicted when another texture took over their storage (for the memory report) | `alias_take_over` | `mtl_mem_stat` | `g_smu` | api, link, present, sub |
| `:1841` | `g_tex_live` | serial → (void *)1, under g_smu | `cap_tex_read`, `mtl_reg_tex`, `mtl_tex_cpu_written`, `mtl_tex_init` +3 | — | `g_smu` | api, link, present, sub |
| `:1842` | `g_ghost`, `g_ghost_ring`, `g_ghost_next`, `g_ghost_puts` | released textures kept for reuse, and their ring | `alias_take_over`, `tex_get`, `tex_put`, `tex_upgrade` | `mtl_mem_stat` | `g_smu` | api, link, present, sub |
| `:1916` | `g_abs_mu`, `g_abs`, `g_nabs` | render-pass results already absorbed into a texture's storage (16), with their lock | `pkg_absorb_note`, `pkg_absorb_take` | `abs_free`, `tex_mtl_` | `g_abs_mu`, atomic | api, gcd, link, mtlcb, present, sub |
| `:1917` | `g_absp`, `g_nabsp` | the counts are read without the lock first (tex_mtl_) | `pkg_absorb_pending` | `pkg_absorb_waits`, `tex_mtl_` | `g_abs_mu`, atomic | api, gcd, link, mtlcb, present, sub |
| `:2611` | `g_cpu_tex_mu` | lock, see [locks.md](locks.md) | — | — | — | api, link, present, sub |
| `:2612` | `g_cpu_tex`, `g_cpu_tex_retired` | serial → pool (or (void *)1 for a live test texture without a pool) | `cpu_tex_drop_pool`, `mtl_tex_cpu_written`, `mtl_tex_release`, `tex_cpu_written` | `mtl_cpu_tex_count` | `g_cpu_tex_mu` | api, link, present, sub |
| `:4301` | `g_rmu` | lock, see [locks.md](locks.md) | — | — | — | api, sub |
| `:4807` | `g_treg`, `g_ntreg` | texture registry: descriptor index to registered texture and its views | `mtl_reg_tex` | `cap_registries`, `csh_cs`, `csh_draw_reads`, `defer_handle_sub` +23 | `g_rmu` | api, sub |
| `:4808` | `g_treg_serial` | serial → first registered descriptor index + 1, under g_rmu | `mtl_reg_tex`, `treg_retire_serial`, `treg_unlink` | — | `g_rmu` | api |
| `:4809` | `g_treg_transient`, `g_ntreg_transient`, `g_treg_transient_cap` | transient registry entries | `tex_by_id`, `treg_finish_submission` | — | — | sub |
| `:4812` | `g_tser` | lock-free copy of texture ID to serial for the replay (`:4810-4811`) | `mtl_reg_tex` | `h_ser` | `g_rmu`, atomic | api, sub |
| `:4813` | `g_sreg`, `g_sreg_ok`, `g_sview`, `g_srid`, `g_nsreg` | sampler registry: parameters, valid bits, sampler states, resource IDs, count | `mtl_reg_samp` | `cap_registries`, `encode_args_`, `mtl_res_snapshot`, `pool_gpu` +2 | `g_rmu` | api, sub |
| `:4814` | `g_sview_w`, `g_srid_w`, `g_sbk` | a sampler's twin for a border colour Metal lacks (retained, NULL = none) and the shader's factors k (see ... | `mtl_reg_samp` | `encode_args_`, `samp_by_id` | `g_rmu` | api, sub |
| `:4863` | `g_vc` | texture serial → vc_set | `mtl_vc_drop`, `tbuf_as_2d`, `vc_drop_pool`, `vc_get` +1 | `mtl_vc_stats` | — | api, sub |
| `:5073` | `g_tpool_n`, `g_stat_tex_oob` | texture pool size; out-of-pool texture IDs read (`:5071-5072`) | `mtl_set_tex_pool_n`, `tex_by_id` | `cap_head` | — | api, sub |

### G5b Sparse textures

Stays because mapped by API calls (`nvn_sparse_watch`) and reconciled on the submit path under the recursive `g_sp_mu`.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:2720` | `g_sp_mu` | lock, see [locks.md](locks.md) | — | — | — | api, link, present, sub |
| `:2722` | `g_sp`, `g_sp_n`, `g_sp_cap`, `g_sp_ids` | sparse textures, their count and IDs | `sp_free`, `sp_new` | `mtl_sparse_drop_pool`, `sp_stat`, `sp_sub_begin` | `g_sp_mu` | api, link, present, sub |
| `:2723` | `g_sp_heaps` | sparse heaps | `sp_tile_alloc` | `sp_emit`, `sp_stat`, `sp_sub_begin`, `sp_tiles_drain` | — | api, link, present, sub |
| `:2724` | `g_sp_ch` | tile chunks (bitmaps) | `sp_tile_alloc` | `sp_tiles_drain` | — | api, link, present, sub |
| `:2725` | `g_sp_free`, `g_sp_nfree`, `g_sp_freecap` | freed tiles and their fence | `sp_tile_free`, `sp_tiles_drain` | `sp_sub_begin` | — | api, link, present, sub |
| `:2726` | `g_sp_npend`, `g_sp_pend_sub`, `g_sp_ntiles`, `g_sp_up_bytes`, `g_sp_maps`, `g_sp_unmaps`, `g_sp_rounds`, `g_sp_evv` | sparse pending counts and counters | `sp_emit`, `sp_free`, `sp_reconcile`, `sp_sub_begin` +4 | `sp_stat` | — | api, link, present, sub |
| `:2727` | `g_sp_ev` | sparse mapping event | `sp_emit` | — | — | api, link, present, sub |
| `:2790` | `g_sp_sh`, `g_sp_shcap`, `g_sp_nsh`, `g_sp_hb`, `g_sp_round` | shared tiles and their hash | `sp_reconcile`, `sp_sh_add`, `sp_sh_unlink`, `sp_unit_drop` | `mtl_sparse_drop_phys`, `sp_sh_find`, `sp_stat` | — | api, link, present, sub |
| `:2827` | `g_sp_ops`, `g_sp_nops`, `g_sp_opcap` | queued mapping operations | `sp_emit`, `sp_op_add` | — | — | api, link, present, sub |
| `:2929` | `g_sp_idx`, `g_sp_nidx`, `g_sp_idxcap` | sparse index scratch | `sp_mark`, `sp_reconcile` | — | — | api, link, present, sub |
| `:2930` | `g_sp_upl`, `g_sp_nupl`, `g_sp_uplcap` | sparse uploads | `sp_reconcile` | — | — | api, link, present, sub |
| `:2931` | `g_sp_a`, `g_sp_len`, `g_sp_key`, `g_sp_rng`, `g_sp_m`, `g_sp_ix`, `g_sp_phys`, `g_sp_w` | sparse batch scratch | `sp_reconcile` | — | — | api, link, present, sub |

### G6 Shaders, pipelines, archives, prebuild

Stays because built by GCD workers, the prebuild and the precompile threads, keyed by content.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:81` | `g_warm_started` | the prepare step started (`warm_start`) | `warm_start` | `mtl_prepare` | — | gcd, sub |
| `:342` | `g_bf_want`, `g_dual_want` | want lists read from `DM_NVN_BF_WANT` / `DM_NVN_DUAL_WANT`, each with its lock | `bf_want_note`, `pso_desc` | — | — | gcd, sub |
| `:355` | `g_c1_banks` | constant-bank blocks | `c1_store` | `mtl_res_snapshot` | `g_c1_lock` | gcd, sub |
| `:356` | `g_c1_bank_off`, `g_c1_alloc_bytes`, `g_c1_data_bytes` | constant-bank offset and byte counts | `c1_store` | `mtl_res_snapshot` | `g_c1_lock` | gcd, sub |
| `:357` | `g_c1_count`, `g_c1_exclusive` | constant-bank counters | `c1_store` | `mtl_res_snapshot` | `g_c1_lock` | gcd, sub |
| `:358` | `g_c1_full` | shaders whose constant bank is full (`c1_full.tsv`) | `shmap_read` | `c1_store` | — | api, gcd, sub |
| `:359` | `g_c1_full_valid` | that set was loaded | `shmap_read` | `c1_store` | — | api, gcd, sub |
| `:360` | `g_cb_ext` | cb_extent.tsv: shader key → "reg:bytes ..." (how far into each uniform slot the shader can read); nil when ... | `shmap_read` | `shader_load` | — | api, gcd, sub |
| `:361` | `g_c1_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:4303` | `g_shmap` | shader mapping table: control-section hash to Mac metallib (`:4302`) | `shmap_read` | `mtl_prog_prefetch`, `prog_get`, `shader_prefetch_rest`, `warm_stale` | — | api, gcd, sub |
| `:4304` | `g_shmap_path`, `g_msl_dir` | paths of the shader map and the MSL folder | `shmap_read` | `at_fn`, `bf_fn`, `geo_mesh_fn`, `lo_fn` +8 | — | api, gcd, sub |
| `:4397` | `g_shcache` | shader cache by key | `shader_get`, `shader_prefetch_rest`, `warm_claim` | `mtl_res_snapshot`, `shader_get_layer` | — | sub |
| `:4436` | `g_warm_items` | warm-up items | `warm_enqueue` | `warm_claim` | `g_warm_lock` | gcd, sub |
| `:4437` | `g_warm_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:4438` | `g_warm_ready` | warm-up ready | `warm_claim`, `warm_enqueue` | — | atomic | gcd, sub |
| `:4439` | `g_warm_t0` | warm-up start time | `warm_start` | `warm_finish` | — | gcd, sub |
| `:4440` | `g_warm_running` | background warm-up still running (`mtl_warm_wait`) | `warm_finish`, `warm_start` | `arch_flush`, `mtl_warm_wait`, `pso_build_ex` | atomic | gcd, sub |
| `:4441` | `g_warm_shaders`, `g_warm_rps`, `g_warm_cps`, `g_warm_skip_fz`, `g_warm_skip_stale` | the prewarm's workers count into them | `warm_stale`, `warm_task` | `warm_finish`, `warm_prepare` | atomic | gcd, sub |
| `:4442` | `g_warm_claim_shaders`, `g_warm_claim_rps`, `g_warm_claim_cps` | warm-up claim counters | `warm_claim` | `present_now` | `g_sub_mu` | link, present, sub |
| `:4445` | `g_pso_record`, `g_pso_record_checked` | pipeline record file | `pso_record_file` | — | — | sub |
| `:4465` | `g_pso_user`, `g_pso_user_checked` | user pipeline record file | `pso_user_file` | — | — | sub |
| `:4466` | `g_pso_user_seen` | pipelines already in it | `pso_user_record` | — | — | sub |
| `:4491` | `t_lib_layer` | Build the library from a .metallib file without permanently occupying a file descriptor: newLibraryWithURL ... | `lib_from_file` | `pre_desc`, `shader_load` | thread-local | gcd, sub |
| `:4513` | `g_fn4_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:4514` | `g_fn4` | id<MTLFunction> → MTL4FunctionDescriptor | `fn4_note` | `fn4_of` | `g_fn4_lock` | gcd, sub |
| `:4537` | `g_fn_dev_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:4540` | `g_fn_dev` | a function fn_spec left unspecialized → its stable specialization record (fn filled by fn_dev) | `fn_spec` | `fn_dev` | `g_fn_dev_lock` | gcd, sub |
| `:4699` | `g_progpf_lock`, `g_progpf_seen` | libraries loaded or being loaded by the prefetch, and its lock | `progpf_first` | — | `g_progpf_lock` | api, sub |
| `:4746` | `g_builtin_lib` | built-in shader library | `builtin_get` | — | — | sub |
| `:4747` | `g_builtin` | built-in shaders by name | `builtin_get` | — | — | sub |
| `:5822` | `g_vin_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:5823` | `g_vin_loaded`, `g_vin_failed`, `g_vin_psos` | shadow-input libraries loaded / not usable, pipelines built with them | `pso_desc`, `vin_fn` | `vc_stat` | — | gcd, sub |
| `:5843` | `g_pull_lock` | lock, see [locks.md](locks.md) | — | — | — | sub |
| `:6094` | `g_fz_fn_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:6095` | `g_bf_fn_cache` | functions by name (blend / feedback variants) | `bf_fn` | — | `g_fz_fn_lock` | gcd, sub |
| `:6096` | `g_bf_lib_cache` | libraries by name | `bf_fn` | — | `g_fz_fn_lock` | gcd, sub |
| `:6097` | `g_pso`, `g_dss` | pipeline cache keyed by `pso_key`; depth-stencil cache | `dss_get`, `geo_capture_pso`, `pso_get_`, `pso_pend_demand` +5 | `mtl_res_snapshot` | — | sub |
| `:6098` | `g_pso_fail` | pipelines that failed to build, never retried | `geo_capture_pso`, `pso_get_`, `tf_pso` | — | — | sub |
| `:6100` | `g_geo_mark` | address used as a marker key (`pso_desc`, `geo_capture_pso`) | `geo_capture_pso`, `pso_desc` | — | — | gcd, sub |
| `:6149` | `g_at_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:6219` | `g_lo_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:6402` | `g_comp4` | the Metal 4 compiler (`pso4_init`) | `pso4_init` block `:6582` | `arch_capture`, `hybrid_on`, `pso4_compiler`, `pso_build_ex` +2 | — | gcd, sub |
| `:6405` | `g_arch4`, `g_arch4p`, `g_arch_dir`, `g_arch_seq` | pipeline archives (with and without vertex layouts), folder, file sequence | `pso4_init` block `:6582`, `arch_write` | `arch_compact_marker`, `pre_pair`, `pso_build_ex`, `pso_prebuild` | — | gcd, sub |
| `:6411` | `g_compact_enabled` | immutable after pso4_init; unlike g_compact_files, never cleared by the archive queue | `pso4_init` block `:6582` | `arch_flush`, `pso_build_ex` | — | gcd, sub |
| `:6412` | `g_compact_files`, `g_compacted`, `g_compact_taken` | archive files to compact, compaction counters | `pso4_init` block `:6582`, `arch_compact_finish`, `arch_flush`, `pso_build_ex` | — | atomic | gcd, sub |
| `:6425` | `g_arch_q`, `g_arch_new`, `g_arch_new_vd`, `g_arch_sched` | bases captured and not written yet, those of them with a vertex layout | `arch_note_new` block `:6671`, `pso4_init` block `:6582`, `arch_capture`, `arch_note_new` +1 | `pso_prebuild` block `:7111`, `arch_flush` | atomic | gcd, sub |
| `:6439` | `g_ep`, `g_ep_lock` | the current period | `pso4_init` block `:6582`, `arch_flush` | `ep_enter` | — | gcd, sub |
| `:6440` | `g_arch_cap` | compiles are captured (an archive folder, a serializer): immutable after pso4_init | `pso4_init` block `:6582` | `arch_capture`, `arch_flush`, `pso_build_ex`, `pso_prebuild` | — | gcd, sub |
| `:6441` | `g_arch_pending` | periods handed over and not written yet | `pso4_init` block `:6582` | `arch_flush` block `:6665`, `arch_flush`, `arch_flush_wait` | — | gcd, sub |
| `:6446` | `g_pbase` | pipeline base cache (`pbase_key`) | `pso_build_ex` | — | `g_pbase_lock` | gcd, sub |
| `:6451` | `g_pbase_pending` | pipeline bases being built | `pso_build_ex` | — | `g_pbase_lock` | gcd, sub |
| `:6452` | `g_pbase_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:6460` | `g_arch_bundle`, `g_bundle_dir` | the bundled pipeline archive and its folder (`:6453-6459`) | `pso_bundle_open` | `pso4_init` block `:6582`, `pso_bundle_covers`, `pso_prebuild` | — | gcd, sub |
| `:6625` | `g_arch_flush_ok` | the last archive write succeeded (`:6624`) | `arch_write` | `arch_compact_finish` | — | gcd |
| `:6823` | `g_pp` | pending pipeline builds (`pso_pend_*`) | `pso_pend_start` block `:6862`, `pso_pend_slot`, `pso_pend_start`, `pso_pend_take` +1 | `pso_pend_find` | `g_pp_mu` | gcd, sub |
| `:6824` | `g_pp_mu`, `g_pp_cv` | lock, see [locks.md](locks.md) | — | — | — | gcd, sub |
| `:6825` | `g_pp_submit_mark`, `g_pp_kicked`, `g_pp_taken`, `g_pp_stolen` | pipeline prediction mark of this submission; kicked, taken, stolen counts | `pso_get_`, `pso_pend_slot`, `pso_pend_take` | `mtl_pso_line`, `pso_predict_rest_` | — | api, sub |
| `:6923` | `g_pso_hy` | pulling pipelines by the key they stand in for (submit thread) | `hybrid_get` | — | — | sub |
| `:6926` | `g_hy_kick_set`, `g_hy_lock` | hybrid pipelines kicked, and its lock | `hybrid_get` | — | `g_hy_lock` | sub |
| `:6973` | `g_pre_running`, `g_pre_next`, `g_pre_done`, `g_pre_built`, `g_pre_archived`, `g_pre_skipped`, `g_pre_failed` | prebuild progress counters (`pso_prebuild`) | `pso_prebuild` block `:7111`, `pso_prebuild` block `:7124`, `pre_pair`, `pso_prebuild` | `prepare_prebuild` | atomic | gcd, sub |
| `:6978` | `g_pre_known`, `g_pre_fails`, `g_pre_fail_lock` | pairs known to fail, failures of this run, and their lock | `pso_prebuild` | `pso_prebuild` block `:7124`, `pre_pair` | — | gcd, sub |
| `:6979` | `g_pre_known_n` | pairs left to the draws because they failed on an earlier start | `pre_pair`, `pso_prebuild` | `pso_prebuild` block `:7124` | atomic | gcd, sub |
| `:7176` | `g_sm_amp`, `g_sm_amp_n`, `g_sm_amp_lock` | slice-merge pipelines, count, lock | `sm_amp_get` block `:7184`, `sm_amp_get` | — | `g_sm_amp_lock` | gcd, sub |
| `:7280` | `g_warm_dict`, `g_warm_dict_lock` | warm dictionary and its lock | `warm_finish`, `warm_load_begin` | `warm_shader` | — | gcd, sub |
| `:7283` | `g_warm_loads` | warm loads by key | `warm_finish`, `warm_load_begin` | `warm_shader` | — | gcd, sub |
| `:7287` | `g_warm_done` | lines done (the prepare screen's count) | `warm_task` | `warm_prepare` | atomic | gcd, sub |
| `:8511` | `g_pf_lock` | lock, see [locks.md](locks.md) | — | — | — | gcd |
| `:10773` | `g_cps` | compute pipelines by program | `dispatch`, `warm_claim` | `mtl_res_snapshot` | — | sub |
| `:10774` | `g_cps_fail` | compute pipelines that failed | `dispatch` | — | — | sub |
| `:10804` | `g_progpf_loaded` | program libraries loaded in the background (`:10801-10803`) | `mtl_prog_prefetch` block `:10817` | — | atomic | gcd |
| `:11388` | `g_dlss` | upscalers | `dlss_scaler_for` | — | `g_sub_mu` | sub |
| `:11389` | `g_dlss_comp` | upscaler compiler | `dlss_scaler_for` | — | `g_sub_mu` | sub |
| `nvn_geometry.inc:404` | `g_pso_mesh`, `g_pso_mesh_lock` | mesh pipelines and their lock | `geo_mesh_pso` block `nvn_geometry.inc:423`, `geo_mesh_pso` | — | `g_pso_mesh_lock` | gcd, sub |
| `nvn_geometry.inc:405` | `g_pso_mesh_building` | mesh pipeline being built | `geo_mesh_pso` | — | `g_pso_mesh_lock` | sub |

### G7 Device objects made once

Stays because immutable after creation.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:5185` | `g_dummy_tex_rid` | resource IDs of dummy textures | `dummy_tex` | `encode_args_`, `pool_gpu`, `tex_fit` | `g_rmu` | sub |
| `:7538` | `g_dummy_img_rid`, `g_dummy_tbuf_rid` | resource IDs of all-zero dummy images and texture buffers (`:7536-7537`) | `dummy_img`, `dummy_tbuf` | `encode_args_`, `img_binding` | `g_rmu` | sub |
| `:8217` | `g_quad_ib`, `g_quad_gpu` | quad index buffer and its GPU address | `quad_ib_make` | `draw_`, `ixc_run` | — | sub |
| `:8218` | `g_fan_ib`, `g_fan_gpu` | non-indexed triangle fans: shared indices (0, i, i+1), base vertex = first | `fan_ib_make` | `draw_`, `ixc_run` | — | sub |
| `nvn_geometry.inc:9` | `g_geo_lean_k` | lean geometry kernels | `geo_lean_pick` | `geo_draw_`, `geo_gs_one` | — | sub |
| `nvn_feedback.inc:5` | `g_tf_prepare` | transform-feedback prepare kernel | `tf_prepare` | — | — | sub |

### G8 Present, display link, snapshots, streaming

Stays because the present thread and the display-link callback own them.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:94` | `g_present_qos` | present thread QoS | `present_main` | `mtl_present_qos` | atomic | api, present |
| `:98` | `g_present_alloc4` | present command allocators | `mtl_init` | `mtl_mem_stat`, `present_now` | — | api, gcd, link, present, sub |
| `:99` | `g_present_cb` | present command buffers | `mtl_init` | `present_now` | — | api, gcd, link, present, sub |
| `:105` | `g_present_args` | present argument table | `mtl_init` | `present_encode_m4` | — | api, gcd, link, present, sub |
| `:106` | `g_present_uv` | present UV buffers | `mtl_init` | `present_now` | — | api, gcd, link, present, sub |
| `:107` | `g_present_alloc_fence` | fence of each present allocator | `present_now` | — | — | link, present |
| `:112` | `g_present_alloc_done` | Under g_pq_mu: per present allocator, the newest ticket its commit feedback reported done on the GPU. ... | `present_now` block `:12576` | `present_now` | `g_pq_mu` | link, mtlcb, present |
| `:113` | `g_pq_mu` | lock, see [locks.md](locks.md) | — | — | — | api, gcd, link, mtlcb, present, sub |
| `:114` | `g_pq_cv` | lock, see [locks.md](locks.md) | — | — | — | api, gcd, link, mtlcb, present, sub |
| `:115` | `g_link_cv` | lock, see [locks.md](locks.md) | — | — | `g_link_mu` | api, link |
| `:116` | `g_link_mu` | lock, see [locks.md](locks.md) | — | — | — | api, link |
| `:117` | `g_link_tick_ns`, `g_link_tick_n` | display-link tick time and count | `- metalDisplayLink:needsUpdate:`, `link_sync` | `mtl_link_wait_ticks`, `mtl_link_wait_vsync`, `mtl_present_wait`, `present_now` | atomic | api, gcd, link, present |
| `:118` | `g_link_dropped` | display-link ticks dropped | `- metalDisplayLink:needsUpdate:`, `mtl_present_wait`, `present_drop_for_suspend` | `present_now` | — | api, gcd, link, present |
| `:119` | `g_link_empty` | Under g_pq_mu: ticks that found no new frame queued (counted here, not as ticks minus presents: presents ... | `- metalDisplayLink:needsUpdate:` | `present_now` | `g_pq_mu` | link, present |
| `:120` | `g_link_hold_until`, `g_link_held` | Changed only on the display-link callback thread: the time the previous frame must stay on screen until by ... | `- metalDisplayLink:needsUpdate:` | `present_now` | — | link, present |
| `:121` | `g_pq_inflight` | Under g_pq_mu: number of presents committed to the GPU whose completion callback has not arrived yet | `present_now` block `:12576`, `present_now` | `fx_encode`, `mtl_present_wait`, `present_drop_for_suspend` | `g_pq_mu` | api, gcd, link, mtlcb, present, sub |
| `:122` | `g_dm_present_link` | Present pacing mode (runtime value of DM_PRESENT_LINK, modified directly during same-process alternating ... | `link_sync`, `mtl_init` | `- metalDisplayLink:needsUpdate:`, `link_on`, `mtl_present_wait` | — | api, gcd, link, sub |
| `:123` | `g_present_latency` | DM_PRESENT_LATENCY: the display link's frame latency in a window and in fullscreen alike (0 = not set: ... | `mtl_init` | `link_latency`, `link_latency_why` | — | api, gcd, link, sub |
| `:124` | `g_pq_done` | presents completed (ticket) | `present_now` block `:12576`, `- metalDisplayLink:needsUpdate:`, `mtl_present_wait`, `present_drop_for_suspend` +1 | `mtl_snap_acquire_wait`, `mtl_wait_state_dump`, `present_enqueue`, `snap_take` | — | api, gcd, link, mtlcb, present |
| `:125` | `g_pq_read` | present queue read position | `- metalDisplayLink:needsUpdate:`, `mtl_present_wait`, `present_drop_for_suspend`, `present_main` | — | — | api, gcd, link, present |
| `:11877` | `g_blit_pso`, `g_blit_fmt` | present blit pipeline and its pixel format | `present_pipeline` | `present_encode`, `present_encode_m4` | — | api, link, present, sub |
| `:11878` | `g_blit_samp` | present blit sampler | `present_pipeline` | `present_encode`, `present_encode_m4` | — | api, link, present, sub |
| `:11879` | `g_present_n` | presents encoded | `present_now` | `dm_gfx_shot_at`, `fx_encode`, `mtl_present_count` | — | api, link, present, sub |
| `:11915` | `g_shotq`, `g_nshotq` | screenshot queue | `dm_gfx_shot_at`, `present_now` | — | `g_shotq_mu` | link, present |
| `:11916` | `g_shotq_mu` | lock, see [locks.md](locks.md) | — | — | — | link, present |
| `:11923` | `g_grab_cb` | Game picture needed by the whole-window screenshot (front end window_shot; no longer does drawViewHierarchy ... | `grab_present`, `mtl_grab_next_present` | `present_now` | `g_shotq_mu` | link, present |
| `:12190` | `g_pres` | present log ring | `present_now` block `:12605`, `- metalDisplayLink:needsUpdate:`, `mtl_present_wait`, `present_drop_for_suspend` | `mtl_presented_time` | — | api, gcd, link, mtlcb |
| `:12196` | `g_link_ring` | display-link log ring | `- metalDisplayLink:needsUpdate:` | `mtl_link_tick` | — | api, link |
| `:12201` | `g_drawable_ns` | Accumulated wall clock waiting for nextDrawable in present (timing instrumentation) | `mtl_drawable_ns_take`, `present_now` | — | atomic | api, link, present |
| `:12215` | `g_present_stall_ns` | For unit tests: an extra pause before each present on the present thread (simulating a drawable that stays ... | `mtl_present_test_stall` | `present_now` | atomic | link, present |
| `:12216` | `g_present_layer_resident` | the layer made resident | `present_now` | — | — | link, present |
| `:12303` | `g_fx_present` | only the present thread encodes or replaces the scaler | `present_encode_m4`, `present_now` | — | — | api, link, present, sub |
| `:12304` | `g_fx_comp` | MetalFX compiler | `fx_encode` | — | — | api, link, present, sub |
| `:12305` | `g_fx_mode` | 1 = metalfx, 0 = off | `fx_mode` | — | — | api, link, present, sub |
| `:12436` | `g_stream_pace` | streaming pace | `mtl_stream_pace` | `link_sync`, `present_now` | atomic | api, gcd, link, present |
| `:12441` | `g_stream` | streaming slots | `stream_setup`, `stream_target` | `stream_capture` | — | link, present |
| `:12442` | `g_stream_on` | streaming on (switch) | `stream_capture` | — | — | link, present |
| `:12493` | `g_link_it_tin` | Enqueue time of the frame the display-link callback is presenting (read and written only on the display-link ... | `- metalDisplayLink:needsUpdate:` | `present_now` | — | link, present |
| `:12625` | `g_ext_ev` | External producer (the Vulkan layer, dm/gfx/vk) renders on its own queue and signals this event when a ... | `mtl_present_ext` | `ext_wait` | — | link, present |
| `:12628` | `g_pq` | present queue | `present_enqueue` | `- metalDisplayLink:needsUpdate:`, `present_main` | `g_pq_mu` | api, link, present |
| `:12629` | `g_pq_in` | present queue write position | `present_enqueue` | `- metalDisplayLink:needsUpdate:`, `mtl_present_flush`, `mtl_wait_state_dump`, `present_drop_for_suspend` +1 | `g_pq_mu` | api, gcd, link, present |
| `:12631` | `g_link_vperiod`, `g_link_vhalf` | virtual ticks (link_range): seconds per counted tick (0 = every callback is a tick) and half a refresh of the ... | `link_range` | `- metalDisplayLink:needsUpdate:` | — | api, link |
| `:12641` | `g_stall_t0`, `g_stall_drop`, `g_stall_n`, `g_stall_red`, `g_stall_logged` | present stall state and counters | `- metalDisplayLink:needsUpdate:`, `link_sync`, `mtl_present_wait` | `mtl_link_stalled` | `g_pq_mu`, atomic | api, gcd, link |
| `:12647` | `g_rescue_mode` | Also read by link_on without g_pq_mu, to stop pacing on silent ticks immediately | `link_sync`, `mtl_present_wait` | `- metalDisplayLink:needsUpdate:`, `link_on` | `g_pq_mu`, atomic | api, gcd, link |
| `:12648` | `g_rescue_back_at`, `g_rescue_back_ns`, `g_rescue_n` | present rescue state and counters | `mtl_present_wait` | `link_sync` | `g_pq_mu` | api, gcd |
| `:12707` | `g_link`, `g_link_rl`, `g_link_started` | the display link, its run loop, started flag | `link_main`, `link_sync` | `link_on`, `mtl_link_pause` | — | api, link |
| `:12708` | `g_link_owns_layer`, `g_classic_busy` | Under g_pq_mu: nextDrawable throws while the layer has the display link object attached, so the present ... | `link_sync` block `:12791`, `link_main`, `present_main` | `mtl_present_wait`, `present_drop_for_suspend` | `g_pq_mu` | api, gcd, link, present |
| `:12738` | `g_link_mode` | Current mode of the display link object: 1 / 2 same as g_dm_present_link, 3 = power-saving mode 30 Hz | `link_sync` | `link_main`, `mtl_link_rate`, `mtl_link_wait_tick`, `mtl_link_wait_vsync` | — | api, link |
| `:12838` | `g_present_discard` | presents discarded (suspend) | `mtl_present_discard` | `mtl_present_wait`, `mtl_snap_acquire_wait`, `present_enqueue` | atomic | api, gcd |
| `:12875` | `g_snap` | snapshot slots (`snap_take`) | `present_enqueue`, `snap_take` | `mtl_snap_acquire_wait` | atomic | api |
| `:12876` | `g_snap_alloc`, `g_snap_cb` | snapshot allocators and command buffers | `snap_take` | — | — | api |
| `:12877` | `g_snap_res`, `g_snap_ev`, `g_snap_v` | snapshot residency set, event and value | `snap_take` | `mtl_snap_acquire_wait`, `snap_drain` | — | api, gcd |
| `:12878` | `g_snap_next`, `g_snap_cmt` | g_snap_cmt: the last copy the encode thread has committed (its g_snap_v) | `present_enqueue`, `snap_commit_wait`, `snap_take` | `mtl_snap_acquire_wait` | atomic | api, gcd, link, present |
| `:12879` | `g_snap_n`, `g_snap_wtex` | snapshot slot count; window textures | `mtl_snap_on`, `mtl_snap_window_textures` | `mtl_snap_acquire_wait`, `present_enqueue`, `snap_take` | — | api |
| `:13094` | `g_prefetched_drawable` | Used for compositing straight onto the drawable | — | `mtl_present_take_prefetched` | — | — |

### G9 Configuration switches

Stays because environment values read once; they change no translation state.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:89` | `g_nvn_deswz_gpu` | GPU deswizzle switch | `mtl_init` | `pkg_upload_`, `sp_upload` | — | api, gcd, link, present, sub |
| `:101` | `g_vbuf_cache` | DM_NVN_VBUF_CACHE=0 restores the uncached path for A/B measurements | `mtl_init` | `bind_vbufs`, `enc_c_args`, `enc_r_args`, `enc_r_vbuf` | — | api, gcd, sub |
| `:2318` | `g_direct_upload_on`, `g_direct_uploads`, `g_direct_dispatches` | direct upload switch and counters | `direct_upload_on`, `pkg_upload_` | — | — | api, link, present, sub |
| `:3464` | `g_zskip_env` | Cache of DM_NVN_ZSKIP (−1 = not read). This function is called on every draw, and getenv once took about 8% ... | `zskip_on` | — | — | sub |
| `:3505` | `g_kd_force` | the draw DM_NVN_KEYDUMP matched: force the per-binding records on (see kd_draw) | `draw_` | `encode_args_`, `passdump` | — | api, link, present, sub |
| `:4503` | `g_depth_zero`, `g_vs_loaded` | NVN depth mode (nvnDeviceSetDepthMode): every vertex library has two entry points (dmsh_build.py vs_depth): ... | `mtl_pso_prebuild_tool`, `mtl_set_depth_zero`, `shader_load` | `cap_head`, `pso_prebuild` | atomic | api, gcd, sub |
| `:5079` | `g_origin_ll` | NVN window origin. In lower-left mode (GL convention, NVN's default) NDC y = -1 lands on a render target's ... | `mtl_set_origin_lower_left` | `cap_head`, `draw_`, `first_draw_covers`, `present_encode` +2 | atomic | api, link, present, sub |
| `:9114` | `g_defer_env_ab`, `g_defer_env_off` | Environment switches: read once at the start of each submit (defer_reset); the hot path does not call getenv | `defer_env` | `defer_on` | `g_sub_mu` | sub |
| `:9814` | `g_fb_mode` | 0 none, 1 writers with reuse until a barrier, 2 every sampling draw, fresh | `fb_mode` | `fb_prepare` | — | sub |
| `nvn_geometry.inc:212` | `g_geo_split_compute`, `g_geo_full_colors`, `g_geo_pack_legacy` | geometry switches (`DM_NVN_GEOMETRY_COMPUTE`, `_COLOR`, `_PACK`) | `geo_color_omit`, `geo_draw_`, `geo_pack_legacy` | — | — | sub |
| `nvn_geometry.inc:231` | `g_geo_ix_on` | geometry index cache switch | `geo_ix_on` | — | — | sub |
| `nvn_geometry.inc:527` | `g_geo_query_run` | geometry query-run switch | `geo_query_run` | — | — | sub |
| `nvn_geometry.inc:528` | `g_geo_cut_on` | geometry cut switch (`DM_NVN_GEOMETRY_CUT`) | `geo_cut_on` | — | — | sub |

### G10 GPU-written memory learning

Stays because shared with the feedback handlers (`gml_read`) under `g_gsr_mu` / `g_gml_mu`.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:775` | `g_gsr`, `g_gsr_n`, `g_gml_on` | GPU-written ranges per fence, count, learning on | `gml_take`, `ubp_get` | `gml_read` | — | mtlcb, sub |
| `:776` | `g_gsr_mu` | lock, see [locks.md](locks.md) | — | — | — | mtlcb, sub |
| `:7830` | `g_gml_mu` | lock, see [locks.md](locks.md) | — | — | — | mtlcb, sub |
| `:7831` | `g_gml_lo`, `g_gml_hi`, `g_gml_n`, `g_gml_stable`, `g_gml_over` | the learned pools' ranges; over: the set filled: a write anywhere from then on | `gml_read` | `gml_take` | `g_gml_mu` | mtlcb, sub |
| `:7832` | `g_gml_logs`, `g_gml_miss`, `g_gml_full` | write-log counters | `gml_read` | `gml_take` | `g_gml_mu` | mtlcb, sub |
| `:7833` | `g_gml_free` | free write-log buffers | `gml_take` | `gml_read` | `g_gml_mu`, `g_rmu` | mtlcb, sub |

### G11 Mirror readback ledger

Stays because written at completion under `g_mrb_mu`.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:11022` | `g_mrb_mu`, `g_mrb`, `g_mrb_n`, `g_mrb_untracked` | Readbacks queued and not landed, by texture (mirror_readback / mirror_rb_land). Until one lands the texture's ... | `mrb_note` | `mrb_pending` | `g_mrb_mu` | api, gcd, link, mtlcb, present, sub |

### G12 Diagnostics and statistics

Stays because counters, dumps and probes; the plan puts them behind one hook layer in S6.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `:88` | `g_l3_gpu_leaks` | diagnostic state | `dm_mtl_l3_tick` | — | — | — |
| `:104` | `g_vbuf_resolve`, `g_vbuf_reuse`, `g_vbuf_set`, `g_vbuf_skip`, `g_vbuf_copies`, `g_vbuf_copy_bytes` | vertex-buffer binding counters | `bind_vbufs`, `enc_r_vbuf`, `vbuf_unaligned` | `mtl_vbuf_stats` | — | api, sub |
| `:134` | `g_arena_made` | diagnostic state | `arena_new` | `mtl_mem_stat` | `g_mu` | api, sub |
| `:135` | `g_allocprof`, `g_ap_bytes`, `g_ap_fn` | diagnostic state | `encode_args`, `mtl_exec`, `pso_get`, `rp_begin_ex` +2 | `mtl_mem_stat`, `pkg_upload_`, `sp_tile_alloc`, `tex_mtl_` | — | api, link, present, sub |
| `:139` | `g_cp_wall`, `g_cp_cpu`, `g_cp_calls`, `g_cp_last` | diagnostic state | `cp_end`, `cp_report` | — | thread-local | api, link, present, sub |
| `:140` | `g_cp_geo_waited`, `g_cp_geo_safe` | diagnostic state | `cp_report`, `geo_prep` | — | thread-local | api, sub |
| `:177` | `g_ws_n`, `g_ws_blk`, `g_ws_ns` | diagnostic state | `ws_put`, `ws_report` | — | atomic | api, enc, gcd, link, present, sub |
| `:185` | `g_fend` | For the game's waits: when each fence's command buffer ended on the GPU and when its feedback handler ran ... | `ws_fb`, `ws_wake`, `ws_wake_pair` | — | atomic | api, gcd, link, mtlcb, present, sub |
| `:186` | `g_ws_wake_n`, `g_ws_wake_ns`, `g_ws_fb_ns` | diagnostic state | `ws_report`, `ws_wake_pair` | — | atomic | api, gcd, link, mtlcb, present, sub |
| `:199` | `g_ws_post` | diagnostic state | `mtl_sub_commit`, `ws_report` | — | atomic | api, sub |
| `:671` | `g_cnt_report`, `g_cnt_reset` | Report / reset counts per counter type (diagnostics) | `mtl_exec` | `mtl_counter_stats` | `g_sub_mu` | sub |
| `:870` | `g_bar_skip`, `g_bar_full` | draw passes begun without / with the consumer barrier (DM_NVN_BARRIER=game) | `enc_r_begin_pass` | `mtl_barrier_stats` | — | api, sub |
| `:896` | `g_gp_heap`, `g_gp_lab`, `g_gp_n`, `g_gp_state`, `g_gp_cur`, `g_gp_f0`, `g_gp_f1`, `g_gp_every`, `g_gp_frame` | diagnostic state | `gp_active`, `gp_begin`, `gp_end`, `gp_periodic_finish` +1 | `gp_report` | — | api, gcd, link, mtlcb, present, sub |
| `:897` | `g_gp_e` | the encoder g_gp_cur belongs to: m4_end also ends the upload / diagnostics / present encoders, which may end ... | `gp_begin`, `gp_end` | — | — | api, gcd, link, present, sub |
| `:898` | `g_gp_busy` | a periodic profile's report has not been printed yet: the heap is still being read | `gp_periodic_finish`, `gp_report`, `mtl_sub_commit` | `gp_begin` | atomic | mtlcb, sub |
| `:899` | `g_bw_load`, `g_bw_store`, `g_gp_bw_l0`, `g_gp_bw_s0` | the bandwidth ledger (defined with the pass statistics below) and its values at the last render pass end | `rp_begin_ex_`, `rp_end`, `sd_finish` | `ab_frame`, `gp_end`, `mtl_bw` | — | api, gcd, link, present, sub |
| `:900` | `g_stat_pass`, `g_stat_draw`, `g_gp_copies`, `g_gp_disp`, `g_gp_ubd` | pass and draw counts; copies, dispatches and inline updates encoded (encoder labels) | `blit_buf`, `dispatch_enc`, `draw_`, `mdx_next` +2 | `ab_frame`, `bcrt_attach`, `blit_note`, `cctx_snap` +41 | — | api, gcd, link, present, sub |
| `:1036` | `g_blit_splits` | copies / buffer updates / fills that ended an open draw pass (the residency set line; a pass ended this way ... | `blit_raw` | `mtl_blit_splits` | — | api, sub |
| `:1129` | `g_ubd_deferred`, `g_ubd_conflicts` | updates deferred, passes ended before a draw that needed more (the residency set line) | `dispatch`, `draw_`, `mtl_sub_update` | `mtl_ubd_stats` | — | api, sub |
| `:1201` | `g_ubp_made`, `g_ubp_reused`, `g_ubp_refused` | partial shadows made / taken from the cache / refused (the pass ended), for the residency set line | `ubd_conflict_sh`, `ubp_get` | `mtl_ubp_stats` | — | api, sub |
| `:1202` | `g_ubp_why` | why ubp_get refused: 0 too large or off, 1 other GPU writes in this submission (sbw), 2 GPU writes of an ... | `ubp_get` | `mtl_ubp_why` | — | api, sub |
| `:1408` | `g_bp_t0` | Time of process start (when this module is loaded) | `bp_t0` | `present_now` | — | link, present |
| `:1411` | `g_bp_lib_n`, `g_bp_lib_ns`, `g_bp_pso_n`, `g_bp_pso_ns`, `g_bp_up_bytes`, `g_bp_first_present` | diagnostic state | `dispatch`, `pkg_upload_`, `present_now`, `pso_get_` +2 | `mtl_create_ns`, `mtl_create_stats`, `mtl_pso_line`, `mtl_upload_bytes` | — | api, link, present, sub |
| `:1412` | `g_up_total_ns` | Cumulative upload time (same source as the per-frame @upload_ms) | `pkg_upload` | `present_now` | — | api, link, present, sub |
| `:1415` | `g_gpu` | t0 / t1: the frame's earliest GPUStart / latest GPUEnd (mach absolute time, ns) | `gpu_tag_begin`, `gpu_tag_done` | `mtl_gpu_ms`, `mtl_gpu_span` | atomic | api, mtlcb, sub |
| `:1423` | `g_ub_n`, `g_ub_N`, `g_ub_cur`, `g_ub_name`, `g_ub_keys`, `g_ub_nk` | same-process alternating measurement (`DM_NVN_UB`) | `ub_frame` | `draw_`, `mtl_set_frame`, `ub_skip` | atomic | api, sub |
| `:1424` | `g_ubp_on`, `g_ubp_c`, `g_ubp_sum_us` | diagnostic state | `mtl_ub_present`, `ub_frame` | — | atomic | api |
| `:1475` | `g_cap_f0`, `g_cap_n`, `g_cap_on` | DM_GPU_CAPTURE=<frame>[:<frames>] (diagnostic): a Metal GPU trace of those frames (default 1) for Xcode's ... | `gpu_capture_frame` | — | — | api |
| `:1707` | `g_red_once` | diagnostic state | `atest_key`, `attach`, `bcrt_attach`, `clear_tex` +51 | — | — | api, gcd, link, mtlcb, present, sub |
| `:1877` | `g_pkg_uploads`, `g_pkg_reuploads`, `g_pkg_miss`, `g_pkg_edge_skips` | diagnostic state | `pkg_edges_clean`, `tex_mtl_` | `mtl_mem_stat`, `mtl_pkg_edge_skips`, `mtl_pkg_miss`, `mtl_pkg_stats` +1 | — | api, link, present, sub |
| `:1878` | `g_pfv_upgrades` | diagnostic state | `sp_upgrade`, `tex_upgrade` | — | — | sub |
| `:2088` | `g_upload_ns` | Cumulative time of deswizzle + upload encoding on the submit thread (timing instrumentation) | `mtl_upload_ns_take`, `pkg_upload` | — | atomic | api, link, present, sub |
| `:2225` | `g_up_blocks_new`, `g_up_swaps`, `g_up_swap_bytes`, `g_up_old` | g_up_old: old blocks switched out (weak references); the diagnostic line counts how many are still alive | `up_alloc` | `up_diag` | — | api, gcd, link, present, sub |
| `:2341` | `g_zb_ser`, `g_zb`, `g_zb_tot`, `g_zb_n` | diagnostic state | `pkg_upload_`, `zb_report` | — | — | api, link, present, sub |
| `:2510` | `g_tex_zeroed` | diagnostic state | `tex_zero_fill` | — | — | api, link, present, sub |
| `:3196` | `g_texinfo_ser`, `g_texinfo_n` | diagnostic state | `tex_mtl_` | `td_dump` | — | api, link, present, sub |
| `:3491` | `g_sm_npass`, `g_sm_ncont`, `g_sm_nwait` | slice-merged passes, layer switches taken into them, draws that left one because their pipeline was not built ... | `draw_`, `mtl_exec`, `rp_begin_ex_`, `sm_plan` | `mtl_sm_stats` | — | api, sub |
| `:3501` | `g_stat_args_enc`, `g_stat_args_reuse` | Argument buffer: new-encode / reuse counts | `encode_args_` | `mtl_args_stats` | — | api, sub |
| `:3502` | `g_pass_full_rw`, `g_udc_saved_bytes` | Bandwidth ledger: attachment load / store bytes, number of full load-store passes | `rp_begin_ex_`, `sd_finish` | `mtl_bw`, `mtl_udc_saved_bytes` | — | api, sub |
| `:3506` | `g_pd_a0`, `g_pd_a1` | the frames dumped (inclusive); -2 = DM_NVN_PASSDUMP not read yet, -3 = DM_NVN_PASSDUMP=every:<n> | `dm_gfx_passdump_next`, `passdump` | — | atomic | api, link, present, sub |
| `:3507` | `g_pd_every` | diagnostic state | `passdump` | — | — | api, link, present, sub |
| `:3560` | `g_pg`, `g_pg_f` | diagnostic state | `pg_on` | `pg_commit` block `:3632`, `pg_commit` | — | mtlcb, sub |
| `:3561` | `g_pg_buf`, `g_pg_b`, `g_pg_used` | diagnostic state | `pg_new`, `pg_on`, `pg_sub_begin` | `pg_commit`, `pg_compute` | — | sub |
| `:3562` | `g_pg_pass`, `g_pg_np`, `g_pg_cap`, `g_pg_open` | diagnostic state | `pg_end_render`, `pg_new`, `pg_sub_begin` | `pg_commit` | — | sub |
| `:3563` | `g_pg_frame`, `g_pg_idx` | diagnostic state | `pg_new` | — | — | sub |
| `:3564` | `g_pg_mu` | lock, see [locks.md](locks.md) | — | — | — | mtlcb |
| `:3567` | `g_pg_st`, `g_pg_rep_frame` | diagnostic state | `pg_commit` block `:3632` | — | `g_pg_mu` | mtlcb |
| `:3676` | `g_udc_ab`, `g_udc_ab_on` | diagnostic state | `shot`, `udc_on` | — | — | api, link, present, sub |
| `:3696` | `g_ab_phase`, `g_ab_len` | in-process A/B phase and its length (`DM_AB`) | `ab_frame`, `ab_len` | `mtl_ab_gpu`, `sw_on` | atomic | api, sub |
| `:3698` | `g_sw_name`, `g_sw_mode`, `g_sw_n` | diagnostic state | `sw_mode` | `ab_report` | — | api, sub |
| `:3718` | `g_ab_gpu`, `g_ab_fr`, `g_ab_nf`, `g_ab_ph`, `g_ab_bw0`, `g_ab_pass0`, `g_ab_f0` | diagnostic state | `mtl_ab_gpu` | `ab_report` | — | api |
| `:3719` | `g_ab_bw1`, `g_ab_pass1`, `g_ab_f1` | the counters at the switch to the current phase (taken in ab_frame), copied to *0 when the previous phase is ... | `ab_frame` | `ab_report`, `mtl_ab_gpu` | — | api |
| `:3753` | `g_sd_dead_bytes`, `g_sd_n_dead`, `g_sd_n_all` | diagnostic state | `sd_finish` | — | — | sub |
| `:3829` | `g_lp` | DM_NVN_LOADPROBE=1 / 2 / 3 (two constant sentinel values / NaN - under float formats normal shader output ... | `lp_finish`, `rp_begin_ex_` | `rp_end` | — | sub |
| `:3847` | `g_rt_merge_n` | Cumulative continuation count | `mtl_exec` | — | `g_sub_mu` | sub |
| `:4738` | `g_gs_miss_draws` | A draw whose geometry stage has no function (a slice writer that does not fit the vertex shader, ... | `draw_gs_check` | — | — | sub |
| `:4864` | `g_vc_hit`, `g_vc_new` | diagnostic state | `vc_get`, `vc_put` | `mtl_vc_stats` | — | api, sub |
| `:4911` | `g_tb2_binds`, `g_tb2_made`, `g_tb2_fail`, `g_tb2_copy`, `g_tb2_copy_bytes` | A texture buffer bound to a slot whose 1D integer fetches the translator made 2D reads of rows of ... | `tbuf_as_2d`, `tbuf_rows_copy` | `mtl_tb2_stats` | `g_rmu` | api, sub |
| `:5236` | `g_tex_mis_n`, `g_tex_mis_shown` | A texture type mismatch no view bridges, reported once per shader and texture slot with what is bound: one ... | `tex_mis_note` | `mtl_tex_mis_count` | `g_rmu` | api, sub |
| `:6442` | `g_pb_built`, `g_pb_archived`, `g_pb_reused`, `g_pb_spec`, `g_pb_legacy`, `g_pb_base_ns` | diagnostic state | `pso_build_ex` | `mtl_pso_line`, `warm_finish`, `warm_prepare` | atomic | api, gcd, sub |
| `:6444` | `g_pt_hit_n`, `g_pt_hit_ns`, `g_pt_miss_n`, `g_pt_miss_ns`, `g_pt_spec_ns`, `g_pt_comp_ns`, `g_pt_pred_n`, `g_pt_pred_ns`, `g_pp_done_n` | pipeline timing counters: hits, misses, specializations, compiles, predictions | `pso_pend_start` block `:6862`, `pso_build_ex`, `pso_predict_rest` | `mtl_pso_line`, `pso_get_` | atomic | api, gcd, sub |
| `:6841` | `g_pw_n`, `g_pw_ns` | Draws that waited for their pipeline on the submit thread, by why no stand-in served them: 0 hybrid pipelines ... | `pso_get_` | `mtl_pso_line` | — | api, sub |
| `:6925` | `g_hy_draws`, `g_hy_made`, `g_hy_none`, `g_hy_kicked`, `g_hy_ns` | draws with a pulling pipeline, pulling pipelines made, misses with no pulling base ready, pulling bases built ... | `draw_`, `hybrid_get`, `pso_get_` | `mtl_hybrid_stats`, `mtl_pso_line` | atomic | api, sub |
| `:7630` | `g_stat_pool_builds`, `g_stat_pool_ms` | diagnostic state | `pool_gpu` | — | `g_rmu` | sub |
| `:8243` | `g_stat_ds_omit` | Number of passes that attach less depth-stencil because the lookahead proved it unused (including ... | `draw_` | `mtl_ds_omit` | — | api, sub |
| `:8244` | `g_stat_s_only`, `g_stat_d_only` | Of those, the number of passes that attach only stencil / only depth | `draw_` | — | — | sub |
| `:8304` | `g_defer_ab`, `g_defer_ab_on` | diagnostic state | `defer_on`, `shot` | — | — | api, link, present, sub |
| `:8512` | `g_pf_n`, `g_pf_ns` | diagnostic state | `shader_prefetch_rest` | — | — | sub |
| `:9674` | `g_ms_key`, `g_ms_every`, `g_ms_plen`, `g_ms_init` | Diagnostic DM_NVN_MAGSCAN=<fragment key>:<scan every N frames, default 30>:<frames per phase, default 600>: ... | `ms_on` | `ms_draw`, `ms_fs_override`, `ms_note`, `ms_phase_now` +1 | — | sub |
| `:9697` | `g_ms_ppass`, `g_ms_pframe`, `g_ms_drawn`, `g_ms_dropped` | diagnostic state | `ms_draw` | `ms_after`, `ms_poll` | — | sub |
| `:9723` | `g_ms_s`, `g_ms_cur` | which buffer this scan frame writes (-1 = not scanning this frame) | `ms_after`, `ms_note`, `ms_poll` | — | — | sub |
| `:9724` | `g_ms_curf`, `g_ms_first` | diagnostic state | `ms_note` | `ms_after` | — | sub |
| `:9725` | `g_ms_att`, `g_ms_lv`, `g_ms_sl`, `g_ms_aser`, `g_ms_na`, `g_ms_apass` | diagnostic state | `ms_after`, `ms_note` | — | — | sub |
| `:9726` | `g_ms_seq`, `g_ms_sc`, `g_ms_hitf`, `g_ms_maxblk`, `g_ms_pscan`, `g_ms_f0`, `g_ms_f1`, `g_ms_pmag` | the phase being tallied (frame / frames per phase) and its totals | `ms_poll` | — | — | sub |
| `:10051` | `g_ubpk_same`, `g_ubpk_diff` | diagnostic state | `ubp_check` | — | — | sub |
| `:10221` | `g_lc_taken`, `g_lc_landed` | clears a later pass took as its load action / clear-only passes still opened for them (the residency set line) | `lc_land`, `lc_take` | `mtl_lc_stats` | — | api, sub |
| `:11539` | `g_cut_draw0`, `g_cut_sub`, `g_cuts`, `g_copy_cuts` | diagnostic state | `sub_cut` | `mtl_copy_cut_count`, `mtl_cut_count` | — | api, sub |
| `:11671` | `g_clr_tri` | clears drawn as a triangle: colour, depth / stencil | `clear_color_tri`, `clear_ds_tri` | — | `g_sub_mu` | sub |
| `:12011` | `g_td_frame`, `g_td_path`, `g_td_list`, `g_td_done` | `DM_NVN_TEXDUMP` frame, path, list, done | `dm_gfx_texdump_next`, `td_dump`, `td_note` | `td_note_layer`, `ts_after`, `ts_note` | — | sub |
| `:12014` | `g_td_layers`, `g_td_lcount`, `g_td_lframe` | DM_NVN_TEXDUMP=layers=<n>:path: the first frame with at least n draws into single layers of small (at most ... | `td_layer_count`, `td_note` | `td_note_layer` | — | sub |
| `:12018` | `g_td_w`, `g_td_h` | DM_NVN_TEXDUMP=size=WxH:path instead picks the frame by content: the first frame that opens a render pass ... | `td_note` | — | — | sub |
| `:12159` | `g_ts_idx`, `g_ts_n`, `g_ts_on`, `g_ts_first`, `g_ts_curf` | DM_NVN_TEXSNAP=in-frame index,... (together with the frame number and path of DM_NVN_TEXDUMP): as soon as ... | `ts_after`, `ts_note` | — | — | sub |
| `:12160` | `g_ts_att`, `g_ts_ser`, `g_ts_lv`, `g_ts_na` | diagnostic state | `ts_note` | `ts_after` | — | sub |
| `nvn_geometry.inc:7` | `g_geo_hoisted`, `g_geo_hoist_runs` | diagnostic state | `geo_draw_` | `mtl_geohoist_stats` | — | api, sub |
| `nvn_geometry.inc:214` | `g_geo_pack_small`, `g_geo_pack_large` | diagnostic state | `geo_draw_` | — | — | sub |
| `nvn_geometry.inc:215` | `g_geo_color_omits` | diagnostic state | `geo_raster` | — | — | sub |
| `nvn_geometry.inc:451` | `g_geo_mesh_n`, `g_geo_mesh_wait` | mesh draws; draws the compute path drew while their mesh pipeline was built | `geo_mesh_draw` | `mtl_geomesh_stats` | — | api, sub |
| `nvn_geometry.inc:526` | `g_geo_dependency_splits` | diagnostic state | `geo_run_walk` | `mtl_geohoist_stats` | — | api, sub |

The groups below are outside `nvn_mtl.m`. `hle_nvn.c` is the API side: the game's calls record into command memory and register objects, and none of its globals is translation state. `nvn_rec.h` is the encode-thread sink, `nvn_dirty.c` the page tracker, `nvn_capture.inc` diagnostics.

### A1 Entry slots and API bookkeeping

Stays because the NVN thunks index these tables (`hle_nvn.c:46`: the layout must not change).

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:46` | `nvn_slot` | The thunk accesses it by i*16; the layout must not change | `nvn_init_slots`, `nvn_nops_register` | `dump_frame`, `nvn_unimpl_c` | atomic | api |
| `hle_nvn.c:53` | `nvn_big_real` | the real implementation of functions that run on the big host stack (nvn_entry.S nvn_big_entry) | `nvn_nops_register` | — | — | — |
| `hle_nvn.c:54` | `nvn_real` | DM_NVN_PROF: the real implementation called by the timing wrapper | `nvn_nops_register` | `h_nvnQueuePresentTexture` | — | api |
| `hle_nvn.c:55` | `nvn_prof_ticks` | DM_NVN_PROF: cumulative time of each function (cntvct counts) | `h_nvnQueuePresentTexture` | — | atomic | api |
| `hle_nvn.c:56` | `g_unimpl_seen` | unimplemented entry points already logged (one byte per entry) | `nvn_unimpl_c` | — | — | — |
| `hle_nvn.c:79` | `g_log` | NVN call log switch | `nvn_init_slots` | `h_nvnBufferInitialize`, `h_nvnDeviceGetInteger`, `h_nvnDeviceInitialize`, `h_nvnMemoryPoolInitialize` +5 | — | api |
| `hle_nvn.c:84` | `g_nsem` | Number of semantic implementations (filled by nvn_init_slots) | `nvn_init_slots` | `nvn_nops_register` | — | api |
| `hle_nvn.c:346` | `g_layout_logged` | layouts logged (bits) | `log_layout` | — | — | api |

### A2 Submit lock and object serials

Stays because `g_sub_mu` serializes submissions; serials name objects for every thread.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:80` | `g_sub_mu` | lock, see [locks.md](locks.md) | — | — | — | api, sub |
| `hle_nvn.c:81` | `g_serial` | object serial counter | `nvn_new_serial`, `nvn_serial_floor` | — | atomic | api, sub |

### A3 Descriptor pools

Stays because registered by API calls: the only writer is `dpool_add` (`hle_nvn.c:280-289`), through its pointer parameters, under `g_dpool_mu`; the readers (`dpool_base` `hle_nvn.c:290`, from the bind and register calls and the replay) take no lock.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:277` | `g_tpb`, `g_spb` | descriptor pool bases (texture, sampler) | `h_nvnSamplerPoolInitialize`, `h_nvnTexturePoolInitialize` | `h_nvnCommandBufferSetSamplerPool`, `h_nvnCommandBufferSetTexturePool`, `h_nvnSamplerPoolRegisterSampler`, `h_nvnSamplerPoolRegisterSamplerBuilder` +3 | — | api, sub |
| `hle_nvn.c:278` | `g_ntpb`, `g_nspb`, `g_tnext`, `g_snext` | their counts and cursors | `h_nvnSamplerPoolInitialize`, `h_nvnTexturePoolInitialize` | `h_nvnCommandBufferSetSamplerPool`, `h_nvnCommandBufferSetTexturePool`, `h_nvnSamplerPoolRegisterSampler`, `h_nvnSamplerPoolRegisterSamplerBuilder` +3 | — | api, sub |
| `hle_nvn.c:279` | `g_dpool_mu` | lock, see [locks.md](locks.md) | — | — | — | api |

### A4 CPU-written texture and span tracking

Stays because API calls and the submit path, under `g_ft_mu` / `g_fl_mu`.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:377` | `g_ft`, `g_nft`, `g_cft`, `g_ft_mu` | textures the CPU wrote, to flush (`ft_add`, `ft_flush`), and the lock | `ft_add`, `ft_del`, `ft_flush`, `nvn_ft_poll` +1 | `nvn_ft_tracked` | `g_ft_mu` | api, link, present, sub |
| `hle_nvn.c:453` | `g_fl`, `g_nfl`, `g_cfl`, `g_fl_mu` | CPU-written spans, and the lock | `fl_add`, `fl_drop` | `fl_find`, `nvn_flushed` | `g_fl_mu` | api, link, present, sub |

### A5 Program keys

Stays because under `g_pk_mu`.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:637` | `g_pk_mu`, `g_pk` | program key table (`pk_get`) and its lock | `pk_get` | `pk_drop` | `g_pk_mu` | api, sub |

### A6 Sync timing

Stays because atomic counter.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:736` | `g_sync_ns` | time in sync waits | `h_nvnQueuePresentTexture`, `h_nvnSyncWait` | — | atomic | api |

### A7 Command memory segments

Stays because API calls, under `g_cs_mu` / `g_hostseg_mu`.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:812` | `g_cs` | Diagnostic DM_NVN_CMDSTAT=1: every 300 frames log one line of command recording usage -- how many bytes / ... | `cmd_alloc_keep`, `cmd_new_segment`, `cs_dump`, `cs_on` +2 | — | — | api |
| `hle_nvn.c:813` | `g_cs_mu` | lock, see [locks.md](locks.md) | — | — | — | api |
| `hle_nvn.c:856` | `g_hostseg`, `g_nhostseg`, `g_caphostseg`, `g_hostseg_bytes` | host-owned command memory segments | `hostseg_take` | `hostseg_release` | `g_hostseg_mu` | api |
| `hle_nvn.c:857` | `g_hostseg_mu` | lock, see [locks.md](locks.md) | — | — | — | api |

### A8 Submit timing

Stays because atomic counters read by the frame summary.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:1236` | `g_sub_wall_ns`, `g_sub_cpu_ns`, `g_sub_instr` | Wall clock / this thread's CPU time / this thread's retired instruction count for submit (excluding present) ... | `h_nvnQueuePresentTexture`, `h_nvnQueueSubmitCommands` | — | atomic | api, sub |
| `hle_nvn.c:1237` | `g_cum_sub_instr`, `g_cum_sub_cpu_ns` | Cumulative versions of the above (the "translation" summary row every 300 frames takes the difference; on a ... | `h_nvnQueueSubmitCommands` | `dm_nvn_sub_cpu_ns`, `tsummary` | atomic | api, sub |
| `hle_nvn.c:1248` | `g_cum_sub_cyc`, `g_cum_sub_sys_ns`, `g_cum_sub_wall_ns` | cumulative submit cycles, system and wall time | `h_nvnQueueSubmitCommands` | `tsummary` | atomic | api, sub |
| `hle_nvn.c:1250` | `g_nvn_ns` | Host time spent in submit / present this frame (replay encoding + present), used by the timing instrumentation | `h_nvnQueuePresentTexture`, `h_nvnQueueSubmitCommands` | — | atomic | api, sub |

### A9 Suspend gate

Stays because `gfx_enter` / `gfx_leave` (`hle_nvn.c:1258`) around submits and presents.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:1254` | `g_susp_mu` | lock, see [locks.md](locks.md) | — | — | — | api, gcd, sub |
| `hle_nvn.c:1255` | `g_susp_cv` | lock, see [locks.md](locks.md) | — | — | `g_susp_mu` | api, gcd, sub |
| `hle_nvn.c:1256` | `g_susp`, `g_inflight_api` | suspended; API calls inside the gate | `dm_gfx_suspend`, `gfx_enter`, `gfx_leave` | — | `g_susp_mu` | api, gcd, sub |
| `hle_nvn.c:1257` | `dm_host_work` | see dm.h (defined here: the graphics unit tests compile this file but not hle_thread.c) | `gfx_enter`, `gfx_leave`, `h_nvnQueueSubmitCommands` | — | atomic, thread-local | api, sub |

### A10 Frame timing, pacing and frame step

Stays because the present / acquire path on the game thread and the present thread.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:1385` | `g_rt_comp_ms` | Currently declared real-time computation amount (ms; 0 = not declared) | `set_time_constraint_comp` | `rt_comp_tick`, `set_time_constraint`, `tsummary` | — | api |
| `hle_nvn.c:1386` | `g_rt_period_ms` | real-time period declared (ms) | `set_time_constraint_comp` | `tsummary` | — | api |
| `hle_nvn.c:1399` | `g_frame` | frame counter | `dump_frame` | `dm_nvn_frame_count`, `fstep_tick`, `h_nvnQueuePresentTexture`, `h_nvnWindowAcquireTexture` | — | api |
| `hle_nvn.c:1400` | `g_acq_wait_ns`, `g_pq_wait_ns` | Accumulated display-link wait / wait for the present queue to return inside acquire, recorded per frame at ... | `h_nvnQueuePresentTexture`, `h_nvnWindowAcquireTexture` | — | — | api |
| `hle_nvn.c:1401` | `g_fs_start`, `g_fs_wait` | frame step (fstep_tick): when the first acquire after a present returned (the frame's start, 0 = none yet), ... | `fstep_tick`, `h_nvnWindowAcquireTexture` | — | — | api |
| `hle_nvn.c:1441` | `g_prev` | per-function call counts of the last frame (`dump_frame`) | `dump_frame` | — | — | api |
| `hle_nvn.c:1442` | `g_tsv` | timing TSV file | `dump_frame` | `frame_rec`, `h_nvnQueuePresentTexture`, `trow` | — | api |
| `hle_nvn.c:1477` | `g_tw`, `g_tn` | timing windows | `tpush` | `tsummary` | — | api |
| `hle_nvn.c:1478` | `g_pres_iv`, `g_presn` | Present interval (ms; -1 = dropped by the system, 0 = no reading) | `h_nvnQueuePresentTexture`, `tsummary` | — | — | api |
| `hle_nvn.c:1479` | `g_pres_exp`, `g_pres_exp_last` | how long that frame should have stayed on screen (ms, pres_expect_ms); the last one for slow_emit | `h_nvnQueuePresentTexture` | `slow_emit`, `tsummary` | — | api |
| `hle_nvn.c:1482` | `g_hold_ring` | The hold (60 Hz vsyncs) each present was given, by present number. On-screen intervals are read 8 presents ... | `h_nvnQueuePresentTexture` | `pres_expect_ms` | — | api |
| `hle_nvn.c:1496` | `g_lf` | late-frame records | `h_nvnQueuePresentTexture` | — | — | api |
| `hle_nvn.c:1503` | `g_hr`, `g_hn`, `g_hn_read` | GPU time history | `h_nvnQueuePresentTexture`, `nvn_gpu_recent` | — | — | api |
| `hle_nvn.c:1603` | `g_sr` | slow-frame state | `slow_emit`, `srow`, `trow` | — | — | api |
| `hle_nvn.c:1604` | `g_slow` | slow-frame switch | `slow_on` | — | — | api |
| `hle_nvn.c:1674` | `g_hz`, `g_display_mode` | Present is fixed at 60 Hz: the adaptive mechanism stepped down at frame 60 in 24/24 real-device logs and ... | `nvn_present_config`, `present_cfg` | `link_wait`, `nvn_game_fps`, `present_itv`, `present_period` +1 | — | api |
| `hle_nvn.c:1675` | `g_game_itv` | when pacing by the game's interval, the interval the game currently sets (in game mode 2 = 30 fps; ... | `present_period` | — | atomic | api |
| `hle_nvn.c:1677` | `g_itv2_since` | start of the game's current run of intervals >= 2 (now_ns; 0 = it is 1 now) | `present_period` | `nvn_game_fps` | atomic | api |
| `hle_nvn.c:1683` | `dm_fps_state` | frame-step state page (weak; `loader.c` defines it, the graphics tests have no loader) | — | `fps_present_cap`, `fps_step_cap`, `fstep_tick`, `h_nvnQueuePresentTexture` +1 | — | api |
| `hle_nvn.c:1685` | `g_engine_stub` | the weak dm_fps_lock_engine's answer, for graphics unit tests (t_nvn sets it) | — | `dm_fps_lock_engine` | — | api |
| `hle_nvn.c:1729` | `g_present_cap` | present cap requested by an engine-native frame limiter (`fps_present_cap`) | `fps_present_cap` | — | — | api |
| `hle_nvn.c:1742` | `g_fs` | frame-step state (present thread only) | `fstep_tick` | — | — | api |
| `hle_nvn.c:1743` | `g_fg` | the GPU time at kmin and at the current hold (nvn_fstep_gpu_slowed) | `fstep_tick` | — | — | api |
| `hle_nvn.c:1744` | `g_fs_k` | the hold presentation follows (0 = not decided yet) | `fstep_tick` | `nvn_game_fps`, `present_itv` | atomic | api |
| `hle_nvn.c:1801` | `g_fs_pshare` | the last window's share in percent (−1 = not measured yet) | `fstep_cpu_slowed` | `fstep_tick` | — | api |

### A11 Virtual memory pools

Stays because mapping requests from API calls under `g_vp_mu`.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `hle_nvn.c:2112` | `g_vp`, `g_nvp`, `g_cvp` | the pools with a range of their own, under g_vp_mu | `vpool_drop`, `vpool_reserve` | `nvn_host_readable`, `nvn_sparse_alias` | `g_vp_mu`, atomic | api, sub |
| `hle_nvn.c:2113` | `g_vp_mu` | lock, see [locks.md](locks.md) | — | — | — | api, link, present, sub |
| `hle_nvn.c:2114` | `g_vp_gen` | bumped per mapping request | `vpt_set` | `nvn_sparse_gen` | `g_vp_mu`, atomic | api, link, present, sub |

### R1 Recorder and encode thread (`nvn_rec.h`)

Stays because the encode-thread sink: its ring is shared by the submit thread and the encode thread.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `nvn_rec.h:19` | `g_ubc` | uniform-copy operations ring | `ubc_push`, `ubc_thread` | — | — | sub, ubc |
| `nvn_rec.h:20` | `g_ubc_head`, `g_ubc_done` | ops queued / made (monotonic) | `ubc_push`, `ubc_thread` | `ubc_head`, `ubc_wait` | atomic | enc, sub, ubc |
| `nvn_rec.h:21` | `g_ubc_sleeping` | the uniform-copy worker sleeps | `ubc_thread` | `ubc_push`, `ubc_wait` | `g_ubc_mu`, atomic | enc, sub, ubc |
| `nvn_rec.h:22` | `g_ubc_mu`, `g_ubc_cv` | lock, see [locks.md](locks.md) | — | — | — | enc, sub, ubc |
| `nvn_rec.h:79` | `g_rec` | the encode thread records (`rec_on`; on by default on iOS) | `rec_on` | — | — | api, gcd, link, present, sub |
| `nvn_rec.h:91` | `g_rb_mu` | lock, see [locks.md](locks.md) | — | — | — | api, enc, gcd, link, present, sub |
| `nvn_rec.h:92` | `g_rb_work`, `g_rb_idle` | lock, see [locks.md](locks.md) | — | — | `g_rb_mu` | api, enc, gcd, link, present, sub |
| `nvn_rec.h:93` | `g_rb_cur`, `g_rb_head`, `g_rb_tail`, `g_rb_free` | the submit thread's open block; blocks waiting for the encode thread; empty blocks | `rec_own_begin`, `rec_own_push`, `rec_publish`, `rec_put` +1 | `rec_drain` | — | api, enc, gcd, link, present, sub |
| `nvn_rec.h:94` | `g_rb_busy`, `g_rb_started`, `g_rb_sleeping` | the encode thread is working through a block; the thread exists; it waits for work | `rec_put`, `rec_thread` | `rec_commit_upload`, `rec_drain`, `rec_own_push`, `rec_publish` +3 | `g_rb_mu` | api, enc, gcd, link, present, sub |
| `nvn_rec.h:101` | `g_note_mu`, `g_note_cv` | lock, see [locks.md](locks.md) | — | — | — | enc, gcd, link, present |
| `nvn_rec.h:109` | `g_rx_cb`, `g_rx_enc` | the encode thread's real command buffer and open encoder | `rec_exec` | — | — | enc |

### D1 Dirty-page tracker (`nvn_dirty.c`)

Stays because read lock-free by the page-fault handler on any thread (`nvn_dirty.c:22-23`).

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `nvn_dirty.c:31` | `g_blk` | blocks of tracked ranges (never moved or freed, `nvn_dirty.c:23`) | `nvn_dirty_add_range` | `rg` | `g_slot_mu`, atomic | api, gcd, link, mtlcb, present, sub |
| `nvn_dirty.c:33` | `g_nr` | number of ranges | `nvn_dirty_add_range` | `find_span`, `nvn_dirty_remove_range`, `nvn_dirty_slot_stats`, `on_fault` +1 | `g_slot_mu`, atomic | api, gcd, link, mtlcb, present, sub |
| `nvn_dirty.c:34` | `g_pg`, `g_shift` | host page size and shift | `nvn_dirty_add_range` | `busy_wait`, `mp`, `nvn_dirty_protect`, `nvn_dirty_since_hint` +5 | — | api, gcd, link, mtlcb, present, sub |
| `nvn_dirty.c:35` | `g_now` | the dirty clock | `stamp_page` | `nvn_dirty_now` | atomic | api, gcd, link, mtlcb, present, sub |
| `nvn_dirty.c:36` | `g_faults`, `g_preps` | fault and pre-write counters | `on_fault`, `prep_write` | `nvn_dirty_stats` | atomic | api |
| `nvn_dirty.c:37` | `g_adds_total` | ranges added | `nvn_dirty_add_range` | `nvn_dirty_slot_stats` | atomic | api |
| `nvn_dirty.c:38` | `g_live`, `g_live_peak` | number of registered pools and peak (for the memory readout line) | `nvn_dirty_add_range`, `nvn_dirty_remove_range` | `nvn_dirty_stat` | `g_slot_mu`, atomic | api |
| `nvn_dirty.c:40` | `g_overflow_logged` | overflow logged | `nvn_dirty_add_range` | — | `g_slot_mu`, atomic | api |
| `nvn_dirty.c:41` | `g_slot_mu` | lock, see [locks.md](locks.md) | — | — | — | api, gcd, link, mtlcb, present, sub |
| `nvn_dirty.c:42` | `g_mp_calls`, `g_mp_pages`, `g_mp_ticks` | This module's mprotect: call count, pages covered, time spent (mach timebase, safe in the page-fault path too) | `mp` | `nvn_dirty_mp_stats` | atomic | api, gcd, link, mtlcb, present, sub |
| `nvn_dirty.c:48` | `g_tb` | obtained when the first pool is registered (the fault path only multiplies and divides) | `nvn_dirty_add_range` | `busy_wait` | — | api, gcd, link, mtlcb, present, sub |
| `nvn_dirty.c:49` | `g_busy_red` | busy wait reported | `busy_wait` | — | atomic | api, gcd, link, mtlcb, present, sub |

### C1 Capture (`nvn_capture.inc`)

Stays because diagnostic capture on the submit path; behind the S6 hook layer with the other diagnostics.

| Line | Globals | Holds | Written by | Read by | Lock at every write | Threads |
|---|---|---|---|---|---|---|
| `nvn_capture.inc:12` | `g_cap_frame` | -1: not parsed yet, 0: off | `nvn_cap_enabled` | `cap_head`, `cap_present_step`, `nvn_cap_present`, `nvn_cap_submit` | — | api, sub |
| `nvn_capture.inc:13` | `g_cap_path` | capture path | `cap_present_step`, `nvn_cap_enabled` | `cap_submit_step` | — | api, sub |
| `nvn_capture.inc:14` | `g_cap_active`, `g_cap_done`, `g_cap_failed` | capture state | `cap_fail`, `cap_present_step`, `cap_submit_step`, `nvn_cap_present` | `nvn_cap_enabled` | — | api, sub |
| `nvn_capture.inc:15` | `g_cap_submit` | submits captured in the frame so far | `cap_submit_step` | `cap_present_step` | `g_sub_mu` | api, sub |
| `nvn_capture.inc:16` | `g_cap_presents` | presents seen (the frame number DM_NVN_SHOT uses) | `nvn_cap_present` | `nvn_cap_submit` | — | api, sub |
| `nvn_capture.inc:17` | `g_cap_w` | capture writer | `cap_flush_objs`, `cap_head`, `cap_mem`, `cap_pools` +6 | — | — | api, sub |
| `nvn_capture.inc:18` | `g_cap_t0`, `g_cap_ns`, `g_cap_unmapped`, `g_cap_segs`, `g_cap_tex_bytes`, `g_cap_tex_n`, `g_cap_tex_skip` | capture counters | `cap_enc_addr`, `cap_present_step`, `cap_seg_write`, `cap_submit_step` +1 | — | — | api, sub |
| `nvn_capture.inc:20` | `g_cap_reg`, `g_cap_nreg` | captured memory regions | `cap_reg_add` | `cap_enc_addr`, `cap_mem`, `cap_pools`, `cap_present_step` +2 | — | api, sub |
| `nvn_capture.inc:21` | `g_cap_tex`, `g_cap_prog`, `g_cap_dpol`, `g_cap_sync`, `g_cap_pool` | objects interned in the capture | `cap_enc_obj`, `cap_pool_obj`, `cap_tex_obj` | — | — | api |
| `nvn_capture.inc:22` | `g_cap_seg`, `g_cap_read` | segments and reads interned | `cap_seg_get`, `cap_submit_step`, `cap_tex_read` | — | — | api, sub |
| `nvn_capture.inc:23` | `g_cap_no_read` | at the present: the frame is rendered, nothing may be read back as an input any more | `cap_present_step` | `cap_tex_read` | — | api, sub |
| `nvn_capture.inc:24` | `g_cap_ntex`, `g_cap_nprog`, `g_cap_ndpol`, `g_cap_nsync`, `g_cap_npool` | interned object counts | `cap_enc_obj`, `cap_pool_obj`, `cap_tex_obj` | `cap_present_step`, `cap_submit_step` | — | api, sub |
| `nvn_capture.inc:25` | `g_cap_tobj`, `g_cap_pobj`, `g_cap_progb`, `g_cap_dpolb`, `g_cap_kind` | objects interned since the last flush | `cap_enc_obj`, `cap_flush_objs`, `cap_pool_obj`, `cap_tex_obj` +1 | — | — | api, sub |
| `nvn_capture.inc:26` | `g_cap_treg0`, `g_cap_ntreg0`, `g_cap_sreg0`, `g_cap_sreg0_ok`, `g_cap_nsreg0` | the registries as last written | `cap_registries` | — | `g_rmu`, `g_sub_mu` | sub |
| `nvn_capture.inc:59` | `g_cap_rid`, `g_cap_nrid` | g_cap_rid[sorted position] = region number in the file | `cap_reg_add` | `cap_enc_addr`, `cap_mem`, `cap_present_step`, `cap_reg_write` | — | api, sub |
| `nvn_capture.inc:68` | `g_cap_cur_submit` | submit being captured | `cap_present_step`, `cap_submit_step` | `cap_seg_write`, `cap_tex_read` | — | api, sub |
| `nvn_capture.inc:69` | `g_cap_where`, `g_cap_where_base` | what is being encoded, for the red lines below (a record: its op, and the base its field offsets count from) | `cap_seg_write`, `cap_tex_enc`, `cap_where` | — | — | api, sub |
| `nvn_capture.inc:141` | `g_cap_orig` | the record's payload in the game's memory (the copy is walked) | `cap_seg_write` | `cap_enc_obj` | `g_sub_mu` | sub |
| `nvn_capture.inc:180` | `g_cap_segq`, `g_cap_nseg`, `g_cap_segq_cap` | segment queue: segments captured, count, capacity | `cap_seg_get`, `cap_submit_step` | `cap_seg_write` | — | sub |
| `nvn_capture.inc:250` | `g_cap_mtex` | MTLTextures already read (several serials can share one) | `cap_tex_read` | — | — | api, sub |

### Test-only: the range checker

`rt_range_check.inc` is included only when `NVN_RT_RANGE_TEST` is defined (`:13097-13099`), and nothing at BASE defines it: the macro appears only in `nvn_mtl.m`. Its globals (`rt_range_check.inc:3-9`, and `g_rr_checking` `:3474`) snapshot `S` and `R` (`rr_snapshot`, `rt_range_check.inc:2`). They were not in the parsed build, so its reads and writes of moving globals are not in the tables above: `rr_finish` writes `g_exec_next`, `g_exec_cur`, `g_vis_on`, `g_vis_counting`, `g_vis_cur`, `S` and `R` (`rt_range_check.inc:45`, `:51`). The other `NVN_RT_RANGE_TEST` blocks of `nvn_mtl.m` are at `:3473`, `:3510`, `:3889`, `:3897`, `:10519`, `:10695` and `:11765`. If it is built, its globals follow T11 and T12; until then constraint 8 applies.

## Function-local statics

One row per function. Kinds: switch (an environment or system value read once), log throttle (a count that limits a log line), diagnostics, object cache (Metal or Foundation objects made once and reused), translator state (state of the submit path carried from call to call), scratch (a buffer reused to avoid stack or heap use, holding nothing between calls), state copy (a saved `S`), once guard, timebase, lock. Group: the moving group the statics go with, or "stays".

### `dm/gfx/nvn/hle_nvn.c`

| Line | Function | Statics | Kind | Group |
|---|---|---|---|---|
| `:88` | `nvn_init_slots` | `done` | once guard | stays |
| `:220` | `h_nvnDeviceGetInteger` | `api` | switch | stays |
| `:424`, `:425` | `nvn_ft_poll` | `gen`, `cur`, `left`, `hit`, `chit` | poll cursor over the CPU-written texture list (`g_ft`), its generation and a scratch list | stays (A4) |
| `:500`, `:508`, `:510` | `h_nvnTextureInitialize` | `n`, `ti`, `tw`, `th`, `n` | switch (`DM_NVN_TEXINFO`) and its sizes; log throttle | stays |
| `:698`, `:699` | `h_nvnProgramSetShaders` | `dump`, `trace`, `trace_init` | switch | stays |
| `:729` | `h_nvnQueueWaitSync` | `once` | log throttle | stays |
| `:864` | `hostseg_take` | `total` | diagnostics counter | stays (A7) |
| `:894` | `h_nvnCommandBufferAddCommandMemory` | `cblog`, `ng` | switch | stays |
| `:908`, `:912` | `cmd_alloc_keep` | `once`, `cblog`, `ncb` | log throttle, switch | stays |
| `:995` | `tex_snap` | `red` | log throttle | stays |
| `:1069` | `ssbo_slot_check` | `n` | log throttle | stays |
| `:1410`, `:1422` | `h_nvnWindowAcquireTexture` | `rt_period`, `pace`, `step`, `last` | pacing state and switches | stays (A10) |
| `:1444`, `:1470` | `dump_frame` | `inited`, `nframes`, `calls`, `cap` | diagnostics switch and its state | stays |
| `:1507` | `nvn_gpu_recent` | `v` | scratch for sorting | stays (A10) |
| `:1516`, `:1530`, `:1531`, `:1532`, `:1533`, `:1534`, `:1536`, `:1537`, `:1543`, `:1548` | `power_line` | `pt`, `pe`, `pcpu`, `pp`, `piw`, `ppw`, `pg`, `pf`, `pld`, `pst`, `pfu`, `pudc`, `tb`, `pbs`, `pbf`, `pcut`, `pccut`, `pbsp`, `pud`, `puc`, `ppm`, `ppr`, `ppf`, `plt`, `pll`, `pw5`, `psmp`, `psmc`, `psmw`, `pchm`, `pchd`, `pchs`, `pgh`, `pgr`, `pgs`, `pmn`, `pmw` | diagnostics: previous values for the periodic power line | stays (A10) |
| `:1576`, `:1581`, `:1584`, `:1588` | `tsummary` | `prev`, `pf`, `pi`, `pc`, `pd`, `pf`, `py`, `pk`, `pw`, `pyn`, `pyns` | diagnostics: previous values for the translation summary | stays (A10) |
| `:1618` | `slow_emit` | `judged`, `slow` | diagnostics counters | stays (A10) |
| `:1638` | `rt_on` | `v` | switch | stays |
| `:1641` | `set_time_constraint_comp` | `tb` | timebase | stays |
| `:1650` | `rt_comp_fixed_ms` | `v` | switch | stays |
| `:1656` | `rt_comp_tick` | `last`, `win`, `n` | pacing state: thread CPU time window | stays (A10) |
| `:1667` | `sleep_until_ns` | `tb` | timebase | stays |
| `:1697`, `:1698` | `thermal_capped` | `mu`, `on`, `capped`, `last`, `calm_since` | pacing state (thermal cap) and switch | stays (A10) |
| `:1765` | `link_wait` | `hz_was`, `rate_was`, `remainder` | pacing state: refresh rate and remainder last seen | stays (A10) |
| `:1803` | `fstep_cpu_slowed` | `levels`, `slowed`, `low_was`, `pc`, `pp` | pacing state (frame step) | stays (A10) |
| `:1819` | `fstep_hold` | `h` | switch | stays (A10) |
| `:1829`, `:1850`, `:1858` | `fstep_tick` | `prev`, `t0`, `v0`, `fixed_sum`, `held`, `nlog`, `slow_bits`, `slow_k`, `fixed_was`, `nfix` | pacing state (frame step) and diagnostics | stays (A10) |
| `:1891` | `present_crop` | `once` | log throttle | stays |
| `:1901`, `:1903`, `:1908`, `:1933`, `:1936`, `:1954`, `:1963`, `:1967`, `:1969`, `:1970`, `:1972`, `:1974`, `:1979`, `:1982`, `:1996`, `:1998`, `:2017` | `h_nvnQueuePresentTexture` | `was`, `prev_in`, `prev_out`, `prev_pass`, `prev_draw`, `lag_k`, `lag_n`, `lag_ms`, `lag_run`, `isub`, `tb`, `acc`, `pth`, `pcpu`, `pproc`, `pl`, `pst`, `pf`, `pudc`, `pae`, `par`, `puc`, `pus`, `pdo`, `pfa`, `pre_`, `pmc`, `pmp`, `pmn`, `plib`, `ppso`, `plns`, `ppns`, `pup`, `prup`, `pub`, `phy`, `on`, `ef`, `eg`, `prev_slot` | diagnostics: previous values for the per-frame `frames.tsv` rows; switches | stays (A10) |
| `:2036` | the `ONCE_LOG` macro, in 23 functions: `dlss_set_tex`, `h_nvnBufferInitialize`, `h_nvnCommandBufferBindTexturesDeferred`, `h_nvnCommandBufferMultiDrawArraysIndirectCount`, `h_nvnCommandBufferMultiDrawElementsIndirectCount`, `h_nvnCommandBufferSetComputeOverlapMode`, `h_nvnCommandBufferSetConservativeRasterEnable`, `h_nvnCommandBufferSetDepthRanges`, `h_nvnCommandBufferSetGeometryProcessingMode`, `h_nvnCommandBufferSetLineWidth`, `h_nvnCommandBufferSetPointSize`, `h_nvnCommandBufferSetRecordingMode`, `h_nvnCommandBufferSetRenderEnable`, `h_nvnCommandBufferSetRenderEnableConditional`, `h_nvnCommandBufferSetSampleMask`, `h_nvnCommandBufferSetScissors`, `h_nvnProgramSetSampleShading`, `h_nvnProgramSetShadersExt`, `h_nvnTextureBuilderSetSwizzle`, `h_nvnTextureViewSetSwizzle`, `h_nvnWindowBuilderSetNumActiveTextures`, `h_nvnWindowSetNumActiveTextures`, `write_texels` | `once_` | log throttle | stays |
| `:2197` | `vpool_map` | `n` | log throttle | stays |
| `:2560`, `:2561` | `push_const` | `once`, `k` | log throttle | stays |

### `dm/gfx/nvn/host_msl.m`

| Line | Function | Statics | Kind | Group |
|---|---|---|---|---|
| `:10` | `host_msl_lib` | `lk`, `libs`, `said` | object cache of libraries under a lock (`lk`); log throttle | stays (G6) |

### `dm/gfx/nvn/nvn_capture.inc`

| Line | Function | Statics | Kind | Group |
|---|---|---|---|---|
| `:72` | `cap_where` | `b` | scratch (capture) | stays (C1) |

### `dm/gfx/nvn/nvn_dirty.c`

| Line | Function | Statics | Kind | Group |
|---|---|---|---|---|
| `:127` | `nvn_dirty_add_range` | `inited` | once guard | stays (D1) |
| `:224` | `nvn_dirty_mp_stats` | `tb` | timebase | stays |

### `dm/gfx/nvn/nvn_geometry.inc`

| Line | Function | Statics | Kind | Group |
|---|---|---|---|---|
| `:8` | `geo_hoist_on` | `on` | switch | stays |
| `:85` | `geo_index_wait` | `always` | switch | stays |
| `:105` | `vertex_dump` | `key`, `path`, `configured`, `captured`, `limit`, `frame` | diagnostics (vertex dump switch and its state) | stays (G12) |
| `:176` | `geo_split` | `nsplit` | log throttle | stays |
| `:271` | `geo_color_omit` | `last`, `last_r` | translator state: last key and result | T10 |
| `:333`, `:347` | `geo_lean_pick` | `lean_on`, `failed` | switch, log throttle | stays |
| `:365` | `geo_mesh_on` | `on` | switch | stays |
| `:374` | `geo_mesh_prims` | `last`, `prims` | translator state: one-entry cache by mesh function | T10 |
| `:398` | `geo_mesh_fn` | `n` | log throttle | stays |
| `:741` | `geo_raster` | `once` | log throttle | stays |
| `:764` | `geo_run_walk` | `run` | scratch (128 KiB, off the stack) | T10 |
| `:802` | `geo_draw_` | `pack` | object cache: pack pipelines | stays (G7) |

### `dm/gfx/nvn/nvn_mtl.m`

| Line | Function | Statics | Kind | Group |
|---|---|---|---|---|
| `:141` | `cp_on` | `on` | switch | stays |
| `:157` | `cp_report` | `names` | diagnostics | stays (G12) |
| `:178` | `ws_on` | `v` | switch | stays |
| `:193` | `ws_wake` | `once` | log throttle | stays |
| `:250` | `res_check` | `nbad` | log throttle | stays |
| `:481` | `dm_mtl_l3_tick` | `leak` | log throttle | stays |
| `:855` | `ser_gate` | `on`, `ev`, `n` | switch (`DM_NVN_PASSGPU_SERIAL`) and its event | stays (G12) |
| `:884` | `barrier_game` | `v` | switch | stays |
| `:916` | `gp_periodic_finish` | `listener` | object cache | stays |
| `:1052` | `blit_barrier` | `off` | switch | stays |
| `:1111` | `mtl_sub_copy` | `once` | log throttle | stays |
| `:1130` | `ubd_on` | `v` | switch | stays |
| `:1138` | `ubd_lazy` | `v` | switch | stays |
| `:1195` | `ub_partial_on` | `v` | switch | stays |
| `:1240` | `um_on` | `v` | switch | stays |
| `:1367` | `mtl_sub_fill` | `pat`, `pat_v`, `pat_ok` | object cache: a pattern buffer and the value it holds | stays (G7) |
| `:1391` | `seg_ts` | `v` | switch | stays |
| `:1394` | `gpu_s_guest_ns` | `tb` | timebase | stays |
| `:1410` | `bootprof` | `v` | switch | stays |
| `:1453`, `:1457` | `ub_frame` | `sp`, `sv`, `ns`, `bad`, `ok` | diagnostics (`DM_NVN_UB`) | stays (G12) |
| `:1494`, `:1496` | `gpu_capture_frame` | `last`, `gpu_thr`, `after`, `over` | diagnostics (GPU capture) | stays (G12) |
| `:1631` | `mtl_sub_commit@block:1627` | `n`, `nv` | log throttle | stays |
| `:1653` | `fast_wake` | `v` | switch | stays |
| `:1880` | `dirtycheck` | `v` | switch | stays |
| `:2113` | `up_reuse` | `on` | switch | stays |
| `:2167` | `up_flush` | `lost_at`, `batch_n` | test switch (`DM_TEST_UP_LOST`) and batch count | stays |
| `:2230` | `up_diag` | `said_swaps`, `last_ns`, `lines`, `follow` | diagnostics | stays (G12) |
| `:2263` | `up_alloc` | `leak` | log throttle | stays |
| `:2340` | `zblock_on` | `v` | switch | stays |
| `:2346`, `:2352` | `zb_report` | `nl`, `nd`, `seen` | diagnostics (`DM_NVN_ZBLOCK`) | stays (G12) |
| `:2390` | `pkg_upload_` | `n` | log throttle | stays |
| `:2499` | `zero_buf` | `zb`, `zn` | object cache: a zero buffer that grows | stays (G7) |
| `:2512`, `:2542` | `tex_zero_fill` | `warned`, `big` | log throttle | stays |
| `:2575`, `:2580` | `tex_init_fill` | `flush_fill`, `n` | switch | stays |
| `:2640` | `mtl_tex_cpu_written` | `n` | log throttle | stays |
| `:2677`, `:2684` | `tex_cpu_content` | `on`, `n` | switch | stays |
| `:2703` | `sparse_view` | `nl` | log throttle | stays |
| `:2729` | `sp_on` | `on` | switch | stays |
| `:2761` | `sp_tile_alloc` | `once` | log throttle | stays |
| `:2858` | `sp_stage` | `b`, `used`, `seq` | sparse staging buffer, offset, sequence | stays (G5b) |
| `:2868` | `sp_raw` | `b`, `cap` | sparse scratch buffer | stays (G5b) |
| `:2907` | `sp_upload` | `once` | log throttle | stays |
| `:2926` | `sp_view` | `nl` | log throttle | stays |
| `:3090`, `:3098`, `:3107` | `sp_upgrade` | `once`, `once`, `once` | log throttle | stays |
| `:3162`, `:3183` | `sp_new` | `nl`, `nl` | log throttle | stays |
| `:3258`, `:3264`, `:3269`, `:3344`, `:3375` | `tex_mtl_` | `n`, `ti`, `tw`, `th`, `last`, `nl`, `n`, `once`, `n` | log throttles; `DM_NVN_TEXINFO` switch and its sizes | stays |
| `:3390` | `mtl_mem_stat` | `last_rss`, `last_gpu`, `last_frame`, `lines` | diagnostics: previous values for the memory line | stays (G12) |
| `:3644` | `pg_commit@block:3632` | `prev_end` | log throttle | stays |
| `:3689` | `tbdr_on` | `v` | switch | stays |
| `:3690` | `rt_range_on` | `v` | switch | stays |
| `:3814` | `xv_on` | `off` | switch | stays |
| `:3844` | `rpa_on` | `v` | switch | stays |
| `:3854` | `enc_label_on` | `v` | switch | stays |
| `:3887` | `rp_end` | `lf`, `base` | diagnostics: encoder label numbering | stays (G12) |
| `:3967` | `bcrt_attach` | `once` | log throttle | stays |
| `:4065`, `:4085`, `:4119` | `rp_begin_ex_` | `probe`, `once`, `once` | log throttle | stays |
| `:4293` | `clear_rect_zero` | `n` | log throttle | stays |
| `:4315` | `shmap_read_once` | `once` | once guard | stays |
| `:4318` | `shmap_load` | `warmed` | once guard | stays (G6) |
| `:4735` | `prog_fold_gs` | `once` | log throttle | stays |
| `:4740`, `:4742` | `draw_gs_check` | `m`, `n` | log throttle | stays |
| `:4766`, `:4783` | `prog_get` | `lp`, `lser`, `lgen`, `lpr`, `shd`, `shd_init` | translator state: one-entry cache checked against `g_ser_gen`; `shd` / `shd_init` switch | T12 |
| `:4939` | `tbuf_align` | `v` | switch | stays |
| `:5027`, `:5032` | `mtl_reg_tex` | `want`, `ti`, `tw`, `th`, `n` | switch, log throttle | stays |
| `:5102`, `:5154` | `tex_by_id` | `n`, `noted` | log throttle | stays |
| `:5203`, `:5209` | `tex_fit` | `noted`, `noted` | log throttle | stays |
| `:5292` | `img_fit` | `once` | log throttle | stays |
| `:5340` | `samp_by_id` | `nlog` | log throttle | stays |
| `:5490`, `:5495` | `vbuf_prepare` | `sub`, `gen`, `sparse`, `once` | translator state: submission, pool generation and sparse generation last seen; log throttle | T7 |
| `:5503`, `:5517` | `bind_vbufs` | `cache`, `zero`, `zero_gpu` | translator state: vertex-buffer cache checked against `g_pool_gen`; `zero` object cache | T13 |
| `:5587`, `:5591` | `order_draw` | `once`, `once` | log throttle | stays |
| `:5638`, `:5652` | `bind_stages` | `cp`, `ck`, `cs`, `next`, `once` | translator state: ring of combined programs `S.prog` points into; log throttle | T12 |
| `:5662` | `prog_resolve` | `n` | log throttle | stays |
| `:5821` | `vin_cpu` | `v` | switch | stays |
| `:5854` | `pull_load` | `n` | log throttle | stays |
| `:5923` | `vc_on` | `v` | switch | stays |
| `:5924` | `vc_check` | `v` | switch | stays |
| `:6001` | `vconv_bind` | `once` | log throttle | stays |
| `:6082` | `adv_blend` | `seen` | log throttle (bits seen) | stays |
| `:6167`, `:6168` | `at_fn` | `n`, `n` | log throttle | stays |
| `:6177` | `at_bind` | `gpu`, `pass`, `last` | translator state: GPU address, pass and slots last bound | T13 |
| `:6230`, `:6243` | `lo_fn` | `n`, `n` | log throttle | stays |
| `:6254` | `lo_bind` | `gpu`, `pass`, `last` | translator state: GPU address, pass and slots last bound | T13 |
| `:6272` | `pso_desc` | `keys`, `nk`, `hl`, `once` | switch (a key list read once), object cache (`hl`), once guard | stays (G6) |
| `:6384` | `pso4_on` | `v` | switch | stays |
| `:6545` | `ga_dir` | `dir`, `once` | object cache, once guard | stays |
| `:6581` | `pso4_init` | `once` | once guard | stays |
| `:6833` | `pp_bg_queue` | `q`, `n`, `rr`, `once` | object cache (queues), round-robin counter, once guard | stays (G6) |
| `:6919` | `hybrid_on` | `v` | switch | stays |
| `:6952`, `:6959` | `mtl_pso_line` | `p`, `pn`, `pns` | diagnostics: previous values for a periodic line | stays (G12) |
| `:7210`, `:7253`, `:7264` | `pso_get_` | `all`, `lg`, `predict` | switch, log throttle | stays |
| `:7426` | `prepare_on` | `v` | switch | stays |
| `:7540` | `dummy_tex` | `cache` | object cache | stays |
| `:7567` | `dummy_img` | `cache` | object cache | stays |
| `:7576` | `dummy_tbuf` | `cache` | object cache | stays |
| `:7618` | `dummy_samp` | `s` | object cache | stays |
| `:7621` | `dummy_samp_rid` | `rid` | object cache (resource ID of an object made once) | stays (G7) |
| `:7668`, `:7670` | `pool_gpu` | `tb`, `gone_logged` | timebase, log throttle | stays |
| `:7676` | `dummy_buf` | `b` | object cache | stays |
| `:7677` | `dummy_buf_gpu` | `gpu` | object cache (GPU address of an object made once) | stays (G7) |
| `:7737` | `dummy_img_atomic` | `cache` | object cache | stays |
| `:7779` | `support_buf` | `b` | object cache | stays |
| `:7785` | `support_gpu` | `gpu` | object cache (GPU address of an object made once) | stays (G7) |
| `:7816` | `gmem_map_gpu` | `said` | log throttle | stays |
| `:7838`, `:7869`, `:7871` | `gml_read` | `rlo`, `rhi`, `lines`, `lines` | diagnostics: last range logged; log throttles | stays (G10) |
| `:7882` | `gml_take` | `said` | log throttle | stays |
| `:7892` | `zero_bank` | `b` | object cache | stays |
| `:7893` | `zero_bank_gpu` | `gpu` | object cache (GPU address of an object made once) | stays (G7) |
| `:7927` | `c0_sample_rows` | `table`, `made` | object cache: a table made on first use | stays (G7) |
| `:7955`, `:7979`, `:8006`, `:8046`, `:8081`, `:8100` | `encode_args_` | `bl_pass`, `bl_all`, `cbd`, `cbk`, `cbd_init`, `nlog`, `nlog`, `nlog`, `nlog` | diagnostics (PASSDUMP); switch; log throttles | stays (G12) |
| `:8468` | `state_op` | `once` | log throttle | stays |
| `:8547` | `shader_prefetch_rest` | `logged` | log throttle | stays |
| `:8556`, `:8563`, `:8607` | `pso_predict_rest_` | `Ssave`, `qa`, `qb`, `logged` | state copy (`Ssave`); scratch queues `qa`, `qb`; log throttle | T12 |
| `:8611` | `fz_probe_cov2` | `Ssave` | state copy (`Ssave`) | T12 |
| `:8679` | `rtc_on` | `v` | switch | stays |
| `:8691` | `sm_on` | `m` | switch | stays |
| `:9049` | `fz_check_on` | `v` | switch | stays |
| `:9071` | `fz_check_run` | `Ssave` | state copy (`Ssave`) | T12 |
| `:9203`, `:9204` | `defer_replay` | `once`, `lm` | scratch `lm`; log throttle | T9 |
| `:9425`, `:9445` | `fuse_try` | `tex`, `img`, `t2`, `i2` | scratch copies of `S.tex` / `S.img` | T9 |
| `:9608` | `fz_p2_draw` | `lg` | log throttle | stays |
| `:9645` | `kd_draw` | `key`, `left`, `every`, `last` | diagnostics (`DM_NVN_KEYDUMP`) | stays (G12) |
| `:9682` | `ms_fs_override` | `fn`, `failed` | object cache, log throttle | stays |
| `:9772` | `ms_after` | `failed`, `ps`, `at`, `logged_att` | log throttle, object cache | stays |
| `:9876`, `:9880` | `fb_prepare` | `once`, `once` | log throttle | stays |
| `:9935`, `:9976`, `:9985` | `ixc_run` | `ps`, `at`, `failed`, `once`, `lg` | object cache, log throttle | stays |
| `:10010` | `wide_run` | `ps`, `at`, `failed` | object cache, log throttle | stays |
| `:10052` | `ubp_check_on` | `v` | switch | stays |
| `:10146`, `:10154` | `mdx_run` | `ps`, `at`, `failed`, `q` | object cache (`ps`, `at`); scratch queue `q` | T7 |
| `:10223` | `lc_on` | `v` | switch | stays |
| `:10306` | `cshoist_on` | `m` | switch | stays |
| `:10372`, `:10375`, `:10389`, `:10403` | `cs_hoist_try` | `rd`, `Ssave`, `wr`, `once` | state copy (`Ssave`); scratch ranges `rd`, `wr`; log throttle | T9; `Ssave` with T12 |
| `:10431`, `:10470`, `:10485`, `:10492`, `:10498`, `:10503`, `:10506`, `:10508`, `:10550`, `:10565`, `:10567`, `:10617`, `:10628`, `:10647`, `:10661`, `:10748` | `draw_` | `indlog`, `once`, `sk`, `nsk`, `small`, `once2`, `once`, `fz_fn`, `once3`, `cur_ps`, `cur_pr`, `cur_ps_pass`, `cur_pull`, `cur_ds`, `cur_ds_pass`, `dko`, `ndko`, `again`, `n`, `last_pass`, `all`, `hp`, `hn`, `once` | translator state: pipeline / depth-stencil state last set and their pass (`cur_*`); switches, log throttles, object cache `fz_fn` | T14 |
| `:10805` | `prefetch_on` | `v` | switch | stays |
| `:10831` | `dispatch_own` | `v` | switch | stays |
| `:10850` | `dispatch` | `once` | log throttle | stays |
| `:10914`, `:10928` | `rb_swap_gpu` | `ps`, `failed`, `once` | object cache, log throttle | stays |
| `:11044` | `mirror_note` | `n`, `nf` | diagnostics counters | stays (G12) |
| `:11078` | `mirror_rb_land` | `n` | log throttle | stays |
| `:11141`, `:11198` | `copy_t2t_draw` | `pso`, `vf`, `ff`, `fd`, `fds`, `samp`, `at`, `dss`, `dss_s`, `failed`, `once` | object cache (pipelines, functions, sampler, tables); log throttle | stays (G7) |
| `:11208`, `:11262` | `draw_tex` | `pso`, `vf`, `ff`, `at`, `failed`, `once` | object cache, log throttle | stays |
| `:11337`, `:11348`, `:11366` | `copy_t2t` | `plane`, `once`, `on`, `tw`, `th`, `tf`, `tb`, `tn`, `tfr`, `from` | object cache (`plane`, kept from copy to copy); log throttle; test switch and its state | stays (G7) |
| `:11416`, `:11424`, `:11447`, `:11455` | `dlss_eval` | `once`, `once`, `once`, `once` | log throttle | stays |
| `:11520` | `cctx_snap` | `b`, `p_pass`, `p_up`, `p_reup`, `p_ser` | diagnostics: capture context line and previous values | stays (G12) |
| `:11529` | `mtl_fps_target` | `env` | switch | stays |
| `:11538` | `cut_draws` | `v` | switch | stays |
| `:11556` | `sub_cut@block:11553` | `k` | log throttle | stays |
| `:11586` | `clr_lib` | `lib`, `failed` | object cache, log throttle | stays |
| `:11594`, `:11597`, `:11604` | `clr_pso` | `cache`, `ty`, `n` | object cache; log throttle | stays (G7) |
| `:11608` | `clr_dss` | `c` | object cache | stays |
| `:11624`, `:11627` | `clr_tri` | `vt`, `ft`, `n` | object cache, log throttle | stays |
| `:11721`, `:11731`, `:11806`, `:11824`, `:11866` | `mtl_exec` | `dump_all`, `last`, `prev`, `n`, `clog`, `once`, `once` | switches, diagnostics (`DM_NVN_ALLOCPROF` last values), log throttles | stays (G12) |
| `:11962`, `:12003`, `:12005` | `shot` | `out_w`, `out_h`, `shots`, `shots` | switch, log throttle | stays |
| `:12085`, `:12087`, `:12104`, `:12105` | `td_dump` | `ps`, `sp`, `src_msl`, `buf`, `env` | object cache, switch | stays |
| `:12240` | `present_raw_src` | `views`, `next`, `mu` | object cache of views, ring index, lock | stays (G8) |
| `:12271`, `:12280` | `present_encode` | `last_crop`, `last_vp` | log state: last crop and viewport | stays (G8) |
| `:12428` | `present_gpu_note` | `v`, `n` | diagnostics | stays (G8) |
| `:12515`, `:12536`, `:12585`, `:12586` | `present_now` | `rl`, `rr`, `rlf`, `rlmu`, `shots`, `nshot`, `shot_path`, `leads`, `e2e`, `lead_n` | diagnostics (screenshots, present latency), a lock (`rlmu`) | stays (G8) |
| `:12663`, `:12668`, `:12685` | `- metalDisplayLink:needsUpdate:` | `next`, `vp_was`, `cb_prev`, `gap_max`, `nticks`, `fifo` | switch, log throttle | stays |
| `:12717` | `link_range` | `on` | switch | stays |
| `:12757`, `:12767`, `:12777` | `link_sync` | `applied`, `paced_was`, `hz_was` | pacing state last applied | stays (G8) |
| `:12850` | `mtl_ext_tex` | `n` | log throttle | stays |
| `:12882` | `mtl_snap_on` | `v` | switch | stays |
| `:12943` | `snap_take` | `n` | log throttle | stays |
| `:12978`, `:12981`, `:12986` | `present_enqueue` | `once`, `t0`, `at`, `dur`, `st`, `f0` | test switch (`DM_TEST_LINK_STALL`) and its state; diagnostics | stays (G8) |
| `:13067` | `mtl_link_wait_ticks` | `started_tick` | pacing state | stays (G8) |

### `dm/gfx/nvn/nvn_rec.h`

| Line | Function | Statics | Kind | Group |
|---|---|---|---|---|
| `:23` | `ubc_on` | `v` | switch | stays |
| `:52` | `ubc_push` | `started` | once guard: the uniform-copy worker was started | stays (R1) |

## Constants

Constants hold no state and stay. `hle_nvn.c` has one `chk_*` constant per `NVN(...)` definition, the macro's type check (`hle_nvn.c:70`).

| File | Scope | Constants |
|---|---|---|
| `dm/gfx/nvn/hle_nvn.c` | file | 411 |
| `dm/gfx/nvn/nvn_border.h` | file | 1 |
| `dm/gfx/nvn/nvn_builtin.h` | file | 1 |
| `dm/gfx/nvn/nvn_capture.inc` | file | 1 |
| `dm/gfx/nvn/nvn_cover.h` | function | 1 |
| `dm/gfx/nvn/nvn_feedback.inc` | function | 1 |
| `dm/gfx/nvn/nvn_geometry.h` | function | 1 |
| `dm/gfx/nvn/nvn_geometry.inc` | file | 1 |
| `dm/gfx/nvn/nvn_geometry.inc` | function | 1 |
| `dm/gfx/nvn/nvn_mtl.m` | file | 8 |
| `dm/gfx/nvn/nvn_mtl.m` | function | 12 |
| `dm/gfx/nvn/nvn_pso_skey.h` | function | 1 |
| `dm/gfx/nvn/nvn_tex.c` | function | 2 |

