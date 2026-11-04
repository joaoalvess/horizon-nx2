# Object lifetimes in the NVN layer

Commit: `b0d98ee7`. Every `file:line` below is at that commit.

This file covers how host objects behind NVN objects live and die: Metal objects, table entries, residency and fenced reuse. The flow of a frame is in [nvn-pipeline.md](nvn-pipeline.md). The globals named here are listed in [nvn-state.md](nvn-state.md), and their locks in [locks.md](locks.md). Threads are in [overview.md](overview.md) and [host-threads.md](host-threads.md).

The fences: `g_fence` (`nvn_mtl.m:129`) is the fence of the last submission handed out. `mtl_sub_commit` advances it (`:1610`) before that submission's buffer is ended and committed (`:1639-1642`), so a `g_fence` read on another thread may name a commit still in progress. `g_done` (`:133`) is the last fence completed with its CPU writes published. "After fence F" means once `g_done >= F`.

## 1. ARC conventions in `nvn_mtl.m`

| Rule | Where |
|---|---|
| `#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to = function)` covers every function of the file, and of `nvn_rec.h`, which is included inside it (`:210`), so a callee does not retain its parameters. Per the comment, the caller or a table holds them, and deferred release guarantees their lifetime. `apply_to = function` does not reach Objective-C methods (unverified) | `nvn_mtl.m:72-73`, popped at `:13110` |
| Lookups return `__unsafe_unretained`: `hm_get_id` (`:1733`), `serial_get` (`:1830`), `tex_get` (`:1852`), `prog_get` (`:4764`, submit thread only), `pso_get` (`:7172`). Clang ignores the qualifier on a return type: `prog_get` retains its result and returns it autoreleased (checked in the -O2 host, refactor item C6), so an unretained local of its result still costs a retain / release pair. A result stays valid while its table holds the object. A replaced or deleted object goes through deferred release (section 3), so it outlives the submission that looked it up. That holds for lookups on the submit thread. The present-side lookups (`present_now` `:12506`, `snap_take` `:12919`; section 7, step 2) run outside a submission, and the deferred-release fence counts submissions, not the present command buffer committed later on `g_q4`, so the guarantee is not shown there (unverified) | as listed |
| Non-owning struct members: `pool_ent.buf` (`:346`; `g_keep` `:349` holds the reference), `pc_ent.buf` in the per-thread cache `t_pc` (`:503-504`), `up_blit.src` / `dst` (`:2116-2122`; `g_up_texs` and the batch's staging hold them), `g_sp_relaxed` (`:869`) | as listed |
| C hash tables hold objects as Core Foundation retains: `hm_put_id` uses `CFBridgingRetain`, and replace / delete use `CFRelease` (`hm_put_id` / `hm_del_id` `:1734-1735`; comment `:1731`). Registry views (`treg_t.view`, `alt`, `im`, `:4803-4806`), view cache entries (`vc_set.view`, `:4861-4862`) and sampler states (`g_sview`, `:4813`) are retained the same way | as listed |
| `arena_alloc` takes a `__strong id<MTLBuffer> *`, so the out-parameter does not autorelease. See `docs/reference/frame-rate.md`, "Arena buffer ownership on allocation" | `:5375-5377` |
| `arena_new` takes a strong reference before it removes the arena from `g_arenas` | `:5354-5356` |

## 2. Autorelease pools

Guest threads have no run loop and never drain their implicit pool, so every path that can autorelease on them has its own pool.

| Pool | Where | Why |
|---|---|---|
| One per submission, `g_sub_pool` | pushed at `mtl_sub_begin` `:821`, popped at the end of `mtl_sub_commit` `:1646`; comment `:799-801` | Command buffers, encoders and descriptors made during the replay |
| `res_add_at`, `res_remove` | `:219`, `:232`; comment `:217-218` | Weak hash table lookups autorelease the object on guest threads |
| `defer_drain` | `:300`; comment `:297-299` | Runs before the submission's pool is pushed. See `docs/reference/memory.md`, "Deferred-release drain without an autorelease pool" |
| `mtl_pool_del` | `:565`; comment `:561-564` | Runs on the guest thread that finalizes the pool. See `docs/reference/nvn-objects.md`, "Finalized pool buffers kept by a guest thread's autorelease pool" |
| `post_run` | `:1569` | A game wait may run the completion on its own thread. See `docs/reference/memory.md`, "Completion readbacks survive a guest waiter's pool" |
| Upload batch completion, `up_diag` | `:2179`, `:2226` | Staging removal; weak table enumeration |
| Present | `present_main` `:12825`, display link callback `:12696` | One per present |
| Encode thread | `rec_thread` `nvn_rec.h:187` | One per block of records |
| Program prefetch | `mtl_prog_prefetch` `:10817` | Background library loads |

`docs/reference/memory.md`, "GPU readback without an autorelease pool", covers the readback paths.

## 3. Deferred release

| Piece | Where |
|---|---|
| `NvDeferredRelease {object, fence, keep_resident}` | `nvn_mtl.m:278-279` |
| Queue `g_deferred`, lock `g_deferred_mu` | `:280-281` |
| `defer_obj_release_ex(obj, keep)`: queues `obj` with `fence = g_fence + 1`, the next submission to commit | `:287-294` |
| `defer_obj_release`: the object is retired. When drained, it leaves the residency set and the reference is dropped | `:295` |
| `defer_obj_unref`: only this reference is unwanted (the object may still be in use). When drained, only the reference is dropped | `:296` |
| Why the two exist | comment `:282-286` |
| `defer_drain`: takes the entries with `fence <= g_done`. A released (not unref'd) `MTLResource` is removed from the residency set if `g_res_objects` holds it. Then `d->object = nil` | `:300-319` |

Drain points:
- `mtl_sub_begin` (`:814`), on the submit thread;
- every submission's completion handler (`:1633`), on the feedback queue.

These are the only two. `post_early` (`:1656-1658`), which runs `post_complete` on a waiting game thread, publishes `g_done` but does not drain.

Main callers (`nvn_mtl.m` calls the two functions about 50 times):

| Caller | Object | Kind |
|---|---|---|
| `mtl_pool_del` `:567` | The pool's no-copy buffer | release |
| `serial_put` / `serial_del` `:1831-1832`, `obj_drop` `:1851` | The serial's previous object | unref if shared (`alias_has`), else release |
| `prog_serial_del` `:1834` | An `NvProg` | release |
| `mtl_alias_drop_pool` `:1787` | Shared textures on a finalized pool | release |
| `alias_take_over` `:1826` | A shared texture whose storage was taken over | unref if `g_ghost` still holds it, else release |
| `treg_drop_views` / `treg_drop_im` / `treg_gone` `:4817-4822`, `:4988-4991` | Registry views (each also CF-released) | unref |
| `vc_set_free` `:4866-4870` | View cache views | unref; rows views (`vc_rows_drop` `:4865`) are released |
| `NvPkg` storage replacement: `sp_upgrade` `:3117-3118`, a re-upload in `tex_mtl_` `:3307` | The old texture and its view; a spare of another shape | release and unref; release |
| `mtl_sub_update` `:1341` | A full uniform update block | release |
| `up_alloc` `:2254`, `up_param_alloc` `:2285` | A slot staging block too small for the batch; a full parameter block | release |
| `mtl_sub_begin` `:836`, `rp_begin_ex_` `:4227` | A visibility overflow buffer | release |
| `tbuf` rows view of a finalized texture `:4980` | A view for the last reads | release |

## 4. Residency

| Piece | Where |
|---|---|
| `g_res`: one residency set, created in `mtl_init` with `initialCapacity` 4096 and added to both queues | `nvn_mtl.m:126`; `:411-412`, `:434-435` |
| `g_res_objects`: a weak `NSHashTable` mirror of the members | `:211` |
| `g_res_dirty`, lock `g_res_mu` (separate from `g_mu`, because `res_add` runs under `g_mu` from `arena_new`; `pool_res` also runs `res_add` and `res_commit` with `g_mu` held, comment `:523`) | `:127`, `:171`; `pool_res` `:524-527` |
| `res_add_at` (macro `res_add`): a resource placed in a heap adds its heap instead; an object already present is skipped; sets dirty | `:219-231` |
| `res_remove`: skips heap members; removes and sets dirty | `:232-242` |
| `res_commit`: commits only when dirty, under `g_res_mu` | `:261-265` |
| Queue commits under `g_res_mu`: the encode thread's `RO_COMMIT` / `RO_COMMIT_REAL` (which also carries the snapshot copy) and the snapshot copy with the encode thread off | `nvn_rec.h:119-121`, `nvn_mtl.m:12964` |
| Queue changes not under `g_res_mu`: `rec_commit` / `rec_commit_upload` with the encode thread off, `present_offscreen_m4`, `stream_capture` and `present_now` commits, and `addResidencySet` for the layer's set and `g_snap_res` | `nvn_rec.h:334`, `:340`; `nvn_mtl.m:12415`, `:12490`, `:12583`; `:12551`, `:12928` |

Commit points (`res_commit();`, 14 call sites, all in `nvn_mtl.m`):

| Site | Where |
|---|---|
| The first address of a pool | `pool_res` `:526` |
| Each submission | `mtl_sub_commit` `:1636` |
| Each upload batch, and its completion after the staging is removed | `up_flush` `:2189`; completion handler `:2183` |
| The raw global memory pool table, rebuilt | `gmem_map_gpu` `:7813` |
| A new raw global memory store log | `gml_take` `:7886` |
| The commit before an indirect count is read | `mdi_wait` `:10101` |
| Each segment | `sub_cut` `:11558` |
| The present scaler's textures | `fx_encode` `:12350` |
| The offscreen present's target and buffer | `present_offscreen_m4` `:12403` |
| Stream targets | `stream_setup` `:12454`, `stream_target` `:12465` |
| The present | `present_now` `:12512` |
| The snapshot copy | `snap_take` `:12923` |

See `docs/reference/rendering.md`, "The residency set committed before a present", and "A present snapshot's copy needs the same residency commit".

Leaving the set:
- deferred release (`defer_drain` `:314`);
- upload staging, when the batch completes (`:2180`);
- large idle arenas (`arena_begin` `:5372`);
- `NvPkg` dealloc removes `tex` and `spare` (`:1875`);
- `NvImageHeap` dealloc removes its heap (`:244`). A heap's owner object is attached to each texture placed in it as an associated object (`:3234`, `:3240`), so the heap leaves the set after its last texture;
- the present scaler's textures when the scaler is remade (`fx_encode` `:12331`);
- the offscreen present's resources, on failure (`:12407`) and in its completion (`:12411`) (`present_offscreen_m4`);
- a stream target's previous texture (`stream_target` `:12464`).

On-demand pool residency:
- `mtl_pool_add` (`:528-556`) does not add the pool's buffer to the set.
- `pool_res` (`:524-527`) adds and commits it the first time `mtl_addr` / `mtl_gpu_addr` hand out its address (comment `:520-523`).

Other residency sets:

| Set | Where | Lifetime |
|---|---|---|
| `g_snap_res`, the present snapshot ring | created and added to `g_q4` in `snap_take` (`:12927-12928`) | A replaced slot texture stays in `old` and in the set until the slot's next use (`:12918`, `:12938-12942`). See `docs/reference/frame-rate.md`, "A replaced snapshot ring texture stays resident until the slot's next use" |
| The layer's own set | added to `g_q4` once per layer in `present_now` (`:12551`) | The layer's lifetime |

Residency diagnostics: `res_check` (`DM_RES_CHECK=1`, `:249`) and `mtl_res_stats` (`:267`).

## 5. Arenas

| Piece | Where |
|---|---|
| `NvArena {buf, gpu, fence, used, len}`; `g_arenas` (free and in-flight), `g_cur_arena`, `g_sub_arenas` (this submission's) | `nvn_mtl.m:5350-5352` |
| `arena_alloc(n, &buf)`: 256-aligned. When the current arena is full, a new one comes from `arena_new` under `g_mu` and is added to `g_sub_arenas` | `:5377-5385` |
| `arena_new(min)`: the smallest arena in `g_arenas` with `fence && fence <= g_done` that fits; else a new shared buffer of max(min, 4 MB), added to the residency set | `:5353-5361` |
| `arena_commit(fence)`, from `mtl_sub_commit` `:1635`: stamps this submission's arenas with its fence and moves them to `g_arenas` | `:5374` |
| `arena_begin()`, from `mtl_sub_begin` `:847`: arenas above `ARENA_KEEP` (32 MB) unused for `ARENA_IDLE` (600) submissions leave the residency set and the list | `:5366-5373` |
| Locking: `g_mu` covers only `arena_new`. `arena_begin` (`:5370-5372`) and `arena_commit` (`:5374`) change `g_arenas` without it; both are called only from the submit thread's `mtl_sub_begin` / `mtl_sub_commit` | as listed |
| A shader's cached argument block (`NvShader.ab_buf`, strong) is reused only inside the render pass that encoded it, because its arena may already be reclaimed (comment) | `:4379` |

## 6. Fenced rings and allocators

| Resource | Reused when | Where |
|---|---|---|
| Main command allocators `g_alloc4[ALLOC_MAX]` (32; 3 made at init) | `g_alloc_fence[i] <= g_done`. Segments of one submission share its allocator (`:11563`), and so does the command buffer `mdi_wait` begins after its commit (`:10110`) | init `:437-443`; pick `:825-833`; stamp `:1643` |
| Upload allocators `g_up_alloc4[3]` | The batch's completion clears `g_up_alloc_busy[slot]` | `up_begin` `:2202-2221`; completion `:2185` |
| Present allocators `g_present_alloc4[3]` | `g_present_alloc_done[i]` reached the allocator's last ticket. See `docs/reference/frame-rate.md`, "A present command allocator is reused only after its own present completes" | `present_now` `:12564`, completion `:12576` |
| Snapshot slots `g_snap[SNAP_MAX]` with `g_snap_alloc` / `g_snap_cb` | The slot's present is processed and `g_snap_ev` reached the slot's copy | `snap_take` `:12911-12917`; `mtl_snap_acquire_wait` `:12896` |
| Visibility buffers `g_vis_ring[VIS_RING]` (`VIS_RING = ALLOC_MAX`) | Slot fence `<= g_done`. An overflow buffer is released by fence | `:665-666`; pick `:839-845`; stamp `:1612`; overflow `:836`, `:4227` |
| Occlusion slot lists | `g_vs` holds a retain on each buffer (`:10639`), `vis_snapshot` adds one per report (`:673-677`), `post_run` releases them (`:1575`), `vis_clear` releases `g_vs` (`:672`) | as listed |
| Uniform update block `g_ubs_buf` (1 MB or larger) | Never reused: a full block is released by fence and a new one made | `:1118`; `mtl_sub_update` `:1340-1345` |
| Upload staging per slot `g_up_slot_blk[3]`, `g_up_slot_over[3]` | Kept for the slot (strong). Other blocks of a batch go to `g_up_keep` and are removed from residency and dropped by the batch's completion | `:2111`; `up_alloc` `:2239-2281`; `up_flush` `:2160-2161`, `:2179-2183` |
| Post records `g_postr[POST_RING]` (128) | Claimed (written) before reuse; otherwise the host aborts | `:1556-1557`; `:1624` |

## 7. Serials and the texture tables

Serials: `nvn_new_serial` (`hle_nvn.c:82`, counter `g_serial` `:81`). New serials come from:
- `nvnTextureInitialize` (`:506`);
- `nvnProgramSetShaders` (`:696`);
- `nvnQueueInitialize` (`:780-781`);
- the replay, for the combined per-stage programs of `bind_stages` (`nvn_mtl.m:5631`; new serial at `:5651`). These are the only users of `prog_serial_put` / `prog_serial_del` (`:5651`, `:5647`), and neither bumps `g_ser_gen` (`:1833-1834`).

Ranges:
- serials from 2^62 are external textures (`tex_put` `nvn_mtl.m:1855`);
- snapshot slots take `(1 << 61) + n` (`:12943`);
- the replayer raises the counter to `1 << 61` (`nvn_serial_floor` `hle_nvn.c:83`, `dm/gfx/tests/nvn_replay.m:224`).

| Table | Maps | Lock | Written by | Defined |
|---|---|---|---|---|
| `g_by_serial` | serial → `MTLTexture`, `NvPkg` or `NvProg` (CF-retained) | `g_smu` (`:1737`) | `serial_put` / `serial_del` (`:1831-1832`), `tex_put` (`:1855-1867`), `prog_serial_put` / `prog_serial_del` (`:1833-1834`), `tex_upgrade` (values rewritten in place, `:2063-2067`) | `nvn_mtl.m:1736` |
| `g_tex_live` | serial → 1 while its texture object is live | `g_smu` | `mtl_tex_init` (`:1843-1850`); removed by `mtl_tex_release` (`:3433`) | `:1841` |
| `g_ghost` | dead serial → object, a ring of `NGHOST` (512) | `g_smu` | `tex_put` on a serial not in `g_tex_live`; the oldest entry is dropped (`obj_drop`); `tex_upgrade` (values rewritten in place, `:2063-2067`) | `:1840-1842` |
| `g_alias` | (pool, offset, description) → shared texture (CF-retained) | `g_smu` | `tex_mtl_` (`:3381`); `tex_upgrade` (values rewritten in place, `:2068-2071`); evicted by `mtl_alias_drop_pool` (`:1770-1794`) and `alias_take_over` (`:1806-1829`, spares entries seen in the last `ALIAS_IDLE` 16 submissions) | `:1745` |
| `g_alias_seen` | key → `g_fence + 1` at its last lookup | `g_smu` | `tex_mtl_` (`:3364`, `:3381`) | `:1746` |
| `g_alias_set` | set of shared textures (non-owning; `alias_has` `:1764`) | `g_smu` | `tex_mtl_` `:3381`, `mtl_alias_drop_pool` `:1786`, `alias_take_over` `:1825`, `tex_upgrade` (moved to the upgraded texture, `:2072`) | `:1762` |
| `g_image_desc` | serial → malloc'd `tex_t` of image-shaped textures | `g_smu` | `mtl_tex_init`, `mtl_tex_release`, `image_desc_drop_pool` (`:1754-1761`) | `:1749` |

`tex_upgrade` (`nvn_mtl.m:2033`) moves every name of an upgraded texture under `g_smu` (`:2061-2074`; comment `:2058-2060`). For a texture held by an `NvPkg`, it instead replaces the package's `tex` and bumps `g_ser_gen` outside `g_smu` (`:2054-2056`); the tables keep the `NvPkg`.

How a texture's Metal object comes and goes:
1. `nvnTextureInitialize` (`hle_nvn.c:496-523`):
   - a live object that is initialized again first goes through `mtl_tex_release` (`:500`);
   - a new serial and `mtl_tex_init` (`:506`);
   - packaged data is copied and marked CPU-written (`:515-517`);
   - `ft_add` (`:521`).
2. First resolution, `tex_mtl_` (`nvn_mtl.m:3250`), on whichever thread resolves the texture first: the submit thread in the replay, the present threads (`present_now` `:12506`; comment `:12508-12511`) or the presenting game thread (`snap_take` `:12919`). A texture whose content comes from its storage is uploaded in a batch only the submit thread may open, so `present_enqueue` resolves it before queueing when the presenting thread is the submit thread (`:12977`; comment `:12974-12976`):
   - a texture shared by storage is found in `g_alias` (`:3364-3365`);
   - otherwise a new texture is made and added to the residency set (`:3371-3377`), takes over overlapping entries (`alias_take_over` `:3380`), and enters `g_alias` (`:3381`);
   - either way it is stored by `tex_put` (`:3365`, `:3383`).

   Packaged textures are held by an `NvPkg` (`:1871-1876`).
3. Records keep `tex_t` snapshots (`tex_snap`, `hle_nvn.c:989-1005`), so a record replayed after Finalize resolves its serial through `g_ghost` (`tex_get` `nvn_mtl.m:1852-1854`). See `docs/reference/rendering.md`, "Texture objects copied into command records", and `docs/reference/nvn-objects.md`, "Dead texture serials kept in a ghost table".
4. `nvnTextureFinalize` (`hle_nvn.c:524`) calls `ft_del`, then `mtl_tex_release` (`nvn_mtl.m:3431-3442`):
   - the `g_tex_live` and `g_image_desc` entries go, and the CPU-written record is retired (`:3433-3438`);
   - `serial_del` (`:3439`);
   - `mtl_vc_drop` (`:3440`, `:4898`);
   - `treg_retire_serial` (`:3441`).

## 8. Descriptor registry and view cache

| Piece | Where | Lifetime |
|---|---|---|
| `treg_t`: a copy of the `tex_t` at registration, plus cached views `view`, `alt`, `im` (CF-retained) and the flags `retired`, `gone`, `transient_sub` | `nvn_mtl.m:4803-4806`; `g_treg` `:4807`; lock `g_rmu` `:4301` | Registering what an ID already holds changes nothing (`mtl_reg_tex` `:5003-5040`) |
| `treg_retire_serial`, from `mtl_tex_release` | `:4832-4844` | Marks the serial's descriptors `retired` and drops their views |
| Transient views of retired entries | queued in `g_treg_transient` (`:5166-5172`) | Dropped by `treg_finish_submission` (`:4845-4854`, from `mtl_sub_commit` `:1609`) |
| `treg_drop_pool_views`, from `mtl_alias_drop_pool` | `:4992-4997` | `vc_drop_pool`, then `treg_gone` (`:4988-4991`) for every ID on the pool |
| View cache `g_vc` (serial → `vc_set`, `VC_WAYS` 4, `VC_MAX` 16384) | `:4859-4863` | Entries go at `mtl_vc_drop` (texture finalize), at pool finalize, and past `VC_MAX` textures |
| Sampler states `g_sview` | `:4813` | Retained per sampler ID (`mtl_reg_samp` `:5048`) |

See `docs/reference/nvn-objects.md`, "Finalized textures kept by registered descriptor views".

## 9. Finalize, object by object

| NVN call | What happens, in order |
|---|---|
| `nvnMemoryPoolFinalize` `hle_nvn.c:254-259` | The pool is dead to the replay first, then torn down (comment `:255`). (1) `mtl_alias_drop_pool(p)` (`nvn_mtl.m:1770-1794`): under `g_smu` it drops image descriptions, evicts the pool's shared textures (deferred release) and bumps `g_ser_gen`; outside `g_smu` it calls `cpu_tex_drop_pool` and `treg_drop_pool_views` (`g_rmu` is taken before `g_smu`, `:1793`). (2) `magic = 0`. (3) `mtl_sparse_drop_pool`; what it frees (unverified). (4) A virtual pool: `vpool_release`; what it frees (unverified). (5) A pool with its own storage: `nvn_dirty_remove_range`, `mtl_sparse_drop_phys`, `mtl_pool_del`, `fl_drop` |
| `mtl_pool_del` `nvn_mtl.m:558-572` | `g_reg_gen++`; under `g_mu`: `[g_keep removeObject:]`, `defer_obj_release(buf)`, added to the weak `g_dead_pools` (`:496`), swap-remove from `g_pools`, `g_pool_gen++`. See `docs/reference/nvn-objects.md`, "Finalized pools kept alive by residency and the sharing table" |
| `nvnTextureFinalize` `hle_nvn.c:524` | `ft_del`, `mtl_tex_release` (section 7), `magic = 0` |
| `nvnProgramSetShaders` `hle_nvn.c:693-720` | `mtl_prog_release` of the old serial, a new serial (`:696`), stage keys computed while the control section is valid (`pk_get` `:701`), `mtl_prog_prefetch` (`:717`) |
| `nvnProgramFinalize` `hle_nvn.c:634` | `mtl_prog_release` (`nvn_mtl.m:4799`: `serial_del`), `magic = 0`, `pk_drop` (`hle_nvn.c:646-651`: frees the keys in `g_pk` under `g_pk_mu`) |
| `nvnQueueFinalize` `hle_nvn.c:784-786` | Under `g_sub_mu`: `mtl_queue_forget(serial)` (`nvn_mtl.m:5693-5700`) frees the queue's saved state (resets `S` and `R` if it was active), `magic = 0` |
| `nvnSyncFinalize` `:723`, `nvnBufferFinalize` `:2061`, `nvnCommandBufferFinalize` `:806` | Clear the magic only |
| `nvnTexturePoolFinalize` `:299` | Nothing |

## 10. Command memory and records

- Records live in the game's command memory, which the host never frees. Record contents are copies:
  - texture snapshots (`tex_snap`);
  - uniform data (`OP_UPDATE_UB`, `hle_nvn.c:963-968`);
  - state bytes (`bind_state` `:1037`).
- Program stage keys are computed at `SetShaders`, because NVN guarantees the control section only during that call (comment `hle_nvn.c:697-698`).
- Host-lent segments are `malloc`'d (`hostseg_take` `:863-882`). They are marked free when the game hands out memory overlapping the recording's guest range (`hostseg_release` `:883-887`). Grants from an empty pool outside a recording have no range and are never reclaimed (comment above `HOSTSEG_SZ`, `:850`). See `docs/reference/nvn-objects.md`, "Host-lent command memory segments".

## 11. Encode-thread retains (`nvn_rec.h`)

| Piece | Where |
|---|---|
| `rec_obj`: `CFBridgingRetain` for each object argument, stored in the first `nobj` slots of `rec_t` | `nvn_rec.h:96`, `:74` |
| `rec_exec` releases those slots after it makes the call | `:177` |
| Argument tables: each stand-in is made once and kept for good, so the real table is passed without a retain | comment `:244`; `setArgumentTable` `:264` |
| Render pass descriptors are copied into the record, since the replay may change its own | `DmRecCB` `:322` |
| The encode thread's real command buffer and encoder `g_rx_cb`, `g_rx_enc` (strong statics). `g_rx_cb` is cleared after `RO_COMMIT` | `:109`, `:122` |
| Blocks go back to `g_rb_free` after they run and are never freed | `:189` |
| The submit thread waits for the encode thread (`rec_drain`) at the end of each submission (`nvn_mtl.m:1642`), so the stand-ins' objects never outlive the submission's pool on the submit side | `nvn_rec.h:218-227` |

## 12. Generation counters

| Counter | Bumped by | Read by |
|---|---|---|
| `g_ser_gen` (`nvn_mtl.m:1739`, comment `:1738`) | `serial_put` / `serial_del` (`:1831-1832`), `tex_put` (`:1865`), alias evictions in `mtl_alias_drop_pool` (`:1789`) and `alias_take_over` (`:1828`), `tex_upgrade` (`:2055` for an `NvPkg`, `:2073` otherwise), a lost upload batch in `up_flush`'s completion (`:2174`), `mtl_tex_cpu_written` (`:2639`), `sp_view` (`:2927`), `sp_upgrade` (`:3119`), a packaged re-upload in `tex_mtl_` (`:3310`). Not `prog_serial_put` / `prog_serial_del` (`:1833-1834`) | `prog_get`'s cache (`:4767`); the texture-ID view caches (`tex_by_id` `:5089`, `:5138`; `tex_fast` `:5178`; `tex_rid_` `:5297`); `pool_gpu` (`:7642`); `args_sync_dirty` (`:7764-7769`); the pass-continuation checks (`rp_begin_ex_` `:4047`, `rt_range_same` `:8769`, `:8775`, `draw_` `:10622`); the `cctx_snap` statistics (`:11524-11525`); the render-target range oracle (`rt_range_check.inc:25-48`) |
| `g_reg_gen` (`:519`) | `mtl_pool_add` (`:529`), `mtl_pool_del` (`:559`), `mtl_reg_tex` (`:5011`, `:5013`), `mtl_reg_samp` (`:5057`) | `rp_begin_ex_` (`:4047`), `pool_gpu` (`:7642`), `args_sync_dirty` (`:7765`), the pass-continuation checks (`rt_range_same` `:8769`, `:8775`, `draw_` `:10622`), the render-target range oracle (`rt_range_check.inc:25-48`) |
| `g_pool_gen` (`:502`) | `mtl_pool_add` (`:551`) and `mtl_pool_del` (`:569`), both under `g_mu` | the per-thread pool cache `t_pc` (`pc_get` `:507`, `pc_put` `:514`), `vbuf_prepare` (`:5491`), `bind_vbufs` (`:5504`), `gmem_map_gpu` (`:7795`, `:7802`) |
| `g_psnap_gen` (`:7629`) | each pool snapshot rebuild in `pool_gpu` (`:7667`) | `encode_args_`: the reuse check (`:7946`) and the stamp of a new block (`:8213`; `NvShader.ab_pgen`, `:4379`) |
| `nvn_dirty_now()` (`nvn_dirty.c:200`, counter `g_now` `:35`) | `stamp_page` (`nvn_dirty.c:70-75`, twice per page) when a protected page is released: a guest write fault (`on_fault` `:91`, through `release_page` `:83` and `unprotect_page` `:76`) or a host write about to land (`prep_write` `:115`, through `release_pages` `:101`) | `args_sync_dirty` (`nvn_mtl.m:7765`), the texture-ID view caches (`:5089`, `:5178`, `:5297`), the pass-continuation checks (`:4048`, `:8769`, `:8775`, `:10622`), content stamps of CPU-written data (`:1904`, `:1932`, `:2394`, `:2953`, `:3073`, `:3289`, `:5944`, `:5955`), `ft_add` (`hle_nvn.c:384`) and `nvn_ft_poll` (`:426`) |

The per-thread pool cache `t_pc` (`nvn_mtl.m:504`, comment `:497-500`) holds unretained buffers of resident pools. It is valid only while `g_pool_gen` is unchanged; a removed pool's buffer is released no earlier than after the next fence.
