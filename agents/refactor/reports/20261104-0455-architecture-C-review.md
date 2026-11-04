# Architecture review C: `nvn-state.md`, `locks.md`

Role: reviewer, Architecture mode. BASE `b0d98ee7`. I read the code only in `/Volumes/Hangar/Games/overnight/base-src-b0d98ee7`. Its `nvn_mtl.m`, `hle_nvn.c`, `nvn_rec.h`, `nvn_geometry.inc`, `nvn_feedback.inc`, `rt_range_check.inc` and `nvn_capture.inc` are byte-identical to `git show b0d98ee7:<path>`. A bare `:N` is in `dm/gfx/nvn/nvn_mtl.m`.

## Verdicts

- `agents/architecture/nvn-state.md`: **approve with nits**. 14 of the 15 statements hold, 1 is wrong (the writers and readers of `g_gw` / `g_gwx`). The order and constraints let T1-T4 each move in one commit with the command stream unchanged. Before the later steps, the constraints need three additions and one correction (N1-N4). The worst: constraint 4 and the T12 table move the thread-local `t_tex_sampled` into the shared context. That changes behaviour on non-submit threads, and the digest cannot see it.
- `agents/architecture/locks.md`: **approve with nits**. The double take of `g_rmu` is **real**, not just possible. It comes through `encode_args_` and through `draw_tex`, never through `fb_prepare` as the outer holder. The result is an abort, not a deadlock. Row `g_rmu` → "`g_rmu` itself" and the sentence after the nesting order should say this (L1-L3).

## nvn-state.md: statements checked

| # | Statement (section) | Result | Evidence |
|---|---|---|---|
| 1 | T1: `g_exec_next` is written by `defer_replay`, `fz_check_run` and `mtl_exec` | holds | `:9200`, `:9208` (`defer_replay`); `:9072`, `:9077` (`fz_check_run`); `:11832-11833` (`mtl_exec`). `rr_finish` writes it too (`rt_range_check.inc:51`; the text gives `:37`, which is the save). That file builds only with `NVN_RT_RANGE_TEST`, which nothing in the tree defines (N5) |
| 2 | T1: `g_exec_cur` is written only by `mtl_exec` | holds | `:11725`, `:11736`, `:11832-11833`; plus test-only `rt_range_check.inc:51` |
| 3 | T1: `g_ret` / `g_ret_n` are written only by `mtl_exec`; readers are `cs_hoist_try`, `defer_cont`, `geo_draw_`, `geo_run_walk`, `ixc_run` +3 | holds | the only writes are `:11745-11746`. Readers: `:10374`, `:9224`, `nvn_geometry.inc:762`, `:816`, `:9944`; the +3 are `pass_ds_need` `:8809-8815`, `wide_run` `:10019` and `mdx_run` `:10160` |
| 4 | T1: `g_rest` / `g_nrest` are written only by `mtl_exec_rest`, set per submission | holds | `:8242`. The submit sets them per handle (`hle_nvn.c:1290`) and clears them after the loop (`hle_nvn.c:1291`). Readers: `fz_next` `:8258`, `pass_ds_need` `:8816`, `defer_cont` `:9225`, `mtl_exec` `:11737` |
| 5 | T1: `g_exec_seq` is written by `mtl_sub_index_` and `sdx_seq` | holds | `:8912` (reset to 0), `:8935` (`++`). Readers: `sdx_decide` `:8938`, `defer_pre` `:9231`, `fz_prefilter` `:9351` |
| 6 | T1 / T2 "Tests naming these globals" (3 and 5) | holds | `rg` over the 144 files of `dm/gfx/tests`. T1: `t_perf_order.m`, `t_pso_depth_stencil.m`, `t_pso_pending.m`. T2: `nvn_replay.m`, `t_geometry.m`, `t_geometry_hazards.m`, `t_pso_pending.m`, `t_readback.m` |
| 7 | T2 and the counter table: `g_sub_serial` is incremented only by `mtl_sub_begin` | holds | the only write is `:813` |
| 8 | T2 and the cross-thread table: `g_alloc4` / `g_alloc_n` / `g_alloc_cur` are written by `mtl_init` and `mtl_sub_begin`; `mtl_init`'s guard takes no lock | holds | `mtl_init` `:437-445`; `mtl_sub_begin` `:828-831`; guard `if (g_dev) return` at `:392` |
| 9 | T2: `g_commit_blocks` is a new array per submission, copied and attached at commit, nil after; read by `draw_`, `fz_check_run`, `gml_take`, `ixc_run` | holds | `:834`, `:1617-1619`, `:1645`. The four add blocks at `:10436`, `:9085`, `:7889` and `:9989` |
| 10 | T2: `g_cut_copy` is written by `copy_b2t`, `mtl_sub_commit` and `sub_cut`; Read by "—" | holds, imprecise | the writes are `:11104`, `:1608` and `:11546`. `sub_cut` also reads it to decide the cut (`:11544-11545`). The Read by column leaves out functions that also write, so "—" reads as "unread" |
| 11 | T3: `g_rc_occ` is never cleared; `rc_occ_add` is the only writer | holds | `:638-642` write it; `rc_occ_has` `:635` reads it |
| 12 | T3: `g_vis_ring` is written by `mtl_sub_begin` and `mtl_sub_commit`; a slot is reused once its fence ≤ `g_done` | holds | `:840-845`, `:1612`. Note the initializers `g_vis_ring_i = -1` (`:666`) and `g_vis_cur = -1` (`:669`) (N2) |
| 13 | T4 and the counter table: `g_pend_gen` is bumped only in `pend_reset` (`:729`), called by `mtl_sub_begin` (`:837`); read by `gw_commit`, `pend_add`, `pend_last`, `pend_since`, `sbw_slot`, `ubp_get` | holds | `pend_reset` has one caller, `:837`. Reads: `:1257`, `:737`, `:748`, `:1274`, `:700`, `:1294`, `:1328`. Initializer `= 1` (`:684`) (N2) |
| 14 | Counter table: the bump sites of `g_wr_epoch` (7) and `g_mdx_epoch` (9) | holds | exactly these: `blit_buf` `:1085`; `dispatch` `:10845`; `copy_t2b` `:10936`; `tf_state_gpu` `nvn_feedback.inc:19`; `tf_note` `nvn_feedback.inc:56`; `geo_mesh_draw` `nvn_geometry.inc:469`; `geo_gs_one` `nvn_geometry.inc:721`. `g_mdx_epoch` also at `mtl_sub_copy` `:1107`, `mtl_sub_fill` `:1362` and `mtl_exec` `:11777` |
| 15 | T4: `g_gw` "Written by `gw_commit`, `gw_live`, `gw_put`", `g_gwx` "Written by `gw_commit`, `gw_put`, `ubp_get`, `um_put`", both "Read by —" | **wrong** | `gw_live` (`:1230`) and `ubp_get` (`:1299`) only read them, through `gw_live_in(const gw_ent *, ...)` (`:1224-1229`). The AST counted "array passed to a call" as a write. Writers: `gw_put_in` through `gw_put` (`:1222`), `gw_commit` (`:1254`, `:1256`) and `um_put` (`:1244`). Readers: `gw_live` (`g_gw`), `ubp_get` (`g_gwx`) |

Fix: row 15 (move `gw_live` and `ubp_get` to Read by). The method note (How the inventory was made, step 2) should say that passing an array to a `const` parameter is a read. Other rows built the same way may have the same error.

## nvn-state.md: does the order allow one commit per group with the stream unchanged?

For T1-T4, yes. The context has one global instance, so every reader on any thread reaches the same storage (constraint 4). The order then matters for review, not for semantics: nothing in T1-T4 needs a later group moved first. T1-T4 hold no thread-local and no `__unsafe_unretained` field. The functions in them are reached only from the submit path, except the rows the cross-thread table names (`mtl_init`; `sp_reconcile` / `sp_resolve` reading `g_sub_serial` under `g_sp_mu`), and those work unchanged with one instance. Their four non-zero initializers (N2) turn out harmless if dropped: each is reset by `mtl_sub_begin` (`:813`, `:837`, `:843`) before any read, or compared against a `g_sub_serial` that is ≥ 1 by then. Still, the constraints should require keeping them, because later groups have initializers that do matter.

The constraints are not enough for every later group:

- **N1 (wrong; T12, constraint 4, cross-thread row `t_tex_sampled`)**: `t_tex_sampled` is `static __thread int` (`:2670`). The writers, `tex_rid_` (`:5298-5299`) and `draw_tex` (`:11220`), set it around `tex_by_id` on the submit thread. The reader `tex_cpu_content` (`:2679`) runs on any thread that resolves a texture. In a shared context, a game thread resolving a texture inside the submit thread's window reads 1, and `tex_shared` takes the other branch. That changes which texture object it makes. `nvn_replay` is single-threaded, so the digest cannot catch this. The row "each thread reads its own" is true only while the variable stays thread-local. Fix: move `t_tex_sampled` to the groups that stay global, with `t_pc` (`:504`) and `t_lib_layer` (`:4491`), or keep it `_Thread_local` outside the context.
- **N2 (missing constraint)**: carry every non-zero initializer into the context instance's initializer. Moving globals with one: T3 `g_vis_ring_i = -1`, `g_vis_cur = -1`; T4 `g_pend_gen = 1`, `g_drain_sub = ~0ull`; T7 `g_vbuf_unaligned = {.klen = 24}` (`:5427`), `g_ir = {.klen = sizeof(ir_key)}` (`:5921`), `g_mdi_epoch = ~0ull` (`:10097`), `g_mdx_tag = 1`, `g_mdx_ep = ~0ull` (`:10134`); T9 `g_defer_cur = &g_defer_slots[0]` (`:8298`; becomes `&ctx.defer_slots[0]`); T10 `g_geo_ix = {.klen = ...}` (`nvn_geometry.inc:227`); T11 `g_fb_pass = UINT64_MAX` (`:9816`); T12 `g_pso_dirty = 1, g_dss_dirty = 1` (`:3500`); T13 `g_psnap_gen = 1` (`:7629`). An `nvn_hmap` with `klen` 0 breaks the map outright. Function-local statics that move carry theirs too.
- **N3 (missing constraint)**: keep each object pointer's ownership qualifier on its field: `__strong` in `vis_buf` (`:663`); `__unsafe_unretained` on `g_sp_relaxed` (`:869`), `g_fb_src` (`:7758`) and `g_c0_dim_buf` (`:7919`). A field that loses `__unsafe_unretained` becomes strong and extends lifetimes past the deferred-release scheme. Also keep arrays as arrays: `sizeof g_pend_hgen` (`:729`), `sizeof(*g_ret)` (`:9944` and the others) depend on it.
- **N4 (inconsistency)**: the Function-local statics table puts `cs_hoist_try`'s `Ssave` (`:10375`) in T9. T12's text says "the static `Ssave` copies (constraint 1)" move with `S`. Pick one. Constraint 1 also leaves out the `typeof(R) Rsave` stack copies in `fz_probe_cov2` (`:8611`), `fz_check_run` (`:9071`) and `cs_hoist_try` (`:10375`), and `rr_finish`'s copies (`rt_range_check.inc:37`, `:45`, `:51`).
- **N5 (unchecked code)**: `rt_range_check.inc` and the `NVN_RT_RANGE_TEST` blocks of `nvn_mtl.m` (`:3473`, `:3510`, `:3889`, `:3897`, `:10519`, `:10695`, `:11765`, `:13097`) name T1, T3, T11 and T12 globals (`g_exec_next`, `g_exec_cur`, `g_vis*`, `S`, `R`). No Makefile or source defines the macro, so no build compiles them, and a rename leaves them broken silently. Either move them in the same commits or note them as unbuilt.

## locks.md: the double take of `g_rmu`

**Real.** The full chain, outer holder `encode_args_`:

1. `mtl_exec` `:11832` → `draw` → `draw_`, for a draw of the later pass of a merged pass: `g_fz.active`, `g_fz.phase == 2`, `g_enc` open.
2. `fz_p2_draw` (`:10507`) proves it and, with `DM_NVN_FUSE_CHECK` set, calls `fz_snap_take` (`:9620` or `:9626`). So `g_nfzs ≥ 1` before argument encoding.
3. `encode_args` (`:10611` / `:10612`) → `encode_args_` takes `g_rmu` (`:7959`).
4. `tex_fast_rid` (`:7998`, `:8055`, `:8067`, `:8092`) → `tex_rid_` (`:5299`) → `tex_by_id` slow path (stale or missing view) → `tex_upgrade_pfv` (`:5137`). This needs the view to set a format that `tex_need_pfv` (`:1725`) says needs a format view, on a base texture made without `MTLTextureUsagePixelFormatView`.
5. `tex_upgrade` → `blit()` (`:2045`; base not buffer-backed). For a sparse packaged texture the route is `sp_upgrade` (`:2034`) → `blit()` (`:3116`).
6. `blit_raw` (`:1100`) → `rp_end` (`:1044`); `g_enc` is set, so it ends the pass → `fz_end` (`:3893`).
7. `fz_end`: `g_fz.active`, `phase == 2`, `fz_check_on()` and `!g_fz_checking` → `fz_check_run` (`:9102`).
8. `g_nfzs ≥ 1` → `args_dirty_all` and `draw` (`:9074-9075`) → `draw_` takes `g_rmu` a second time. The first site reached is `image_prepare` `:7709` if the program writes an image. Otherwise it is `fb_prepare` `:9854` if the fragment shader samples a texture (`g_fz.active` is 0 by now, so `fb_prepare` does not return early). Failing both, it is `encode_args_` `:7959`; the argument blocks are dirty, so it does not reuse them.

Outer holder `draw_tex`: an `OP_DRAW_TEX` replayed in the later pass after its first draw. `fuse_try` scans only up to the later pass's first draw (`:9373-9408`), so the merged pass is still open. `draw_tex` takes `g_rmu` (`:11219`) and calls `tex_by_id` (`:11220`) before its own `rp_end` (`:11225`). From there the chain is the same, from step 4.

Not an outer holder:
- `fb_prepare` (`:9854`, `:9859`): it returns at `:9842` while `g_fz.active`. With the flag clear, `fz_end` returns at once (`:9099`).
- `img_fit_upgrade`: `rp_begin_ex_` calls it with no pass open (`:4039-4044`).
- `image_prepare`: it ends the pass (`:7717`) before it takes `g_rmu` for the upgrade (`:7718`).

Effect: `g_rmu` is an `os_unfair_lock`. libplatform aborts when the thread that owns one locks it again ("BUG IN CLIENT OF LIBPLATFORM: Trying to recursively lock an os_unfair_lock"; `_os_unfair_lock_recursive_abort` in libplatform `src/os/lock.c`, https://opensource.apple.com/source/libplatform/libplatform-177.250.1/src/os/lock.c.auto.html). It is a crash of the submit thread, not a hang. That settles the "(unverified: Apple's contract)" at `locks.md:24`. Conditions: `DM_NVN_FUSE_CHECK` set, a merged pass, and the first resolution of such a view during it. It is rare, but nothing guards against it.

Fix in `locks.md`:
- **L1**: in the last `g_rmu` row of Nestings, mark it checked: real through `encode_args_` and `draw_tex`, not `fb_prepare`, `img_fit_upgrade` or `image_prepare`. Add the `sp_upgrade` `:3116` route. Name the inner site as the first `g_rmu` that the nested `draw_` reaches (`:7709`, `:9854` or `:7959`), not only `fb_prepare`.
- **L2**: the sentence after the nesting order (`locks.md:166`): the self-pair `g_rmu` → `g_rmu` exists under `DM_NVN_FUSE_CHECK`, so the graph has a cycle there. It is no longer "not ruled out".
- **L3**: `fz_p2_draw` calls `tex_fast_rid` → `tex_by_id` at `:9602` without `g_rmu`, although `tex_by_id` says "Caller holds g_rmu" (`:5085`). The `g_rmu` row's "Guards" should name it as an unlocked reader and writer of the registry view caches (`rp->view*`).

Outside the brief, open: step 4-6 without `DM_NVN_FUSE_CHECK` still ends the render pass inside `encode_args_`. `encode_args_` then binds into `en`, an encoder that `rp_end` has ended, and `draw_` draws on it. `img_fit` defers exactly this case for image slots (`:5281-5284`; the comment at `:7698-7700`), but `tex_by_id`'s format-view upgrade does not. I did not check whether any game reaches it.
