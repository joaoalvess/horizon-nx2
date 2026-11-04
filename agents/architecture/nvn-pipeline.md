# NVN pipeline: one frame

Commit: `b0d98ee7`. Every `file:line` below is at that commit.

This file follows one frame through the NVN layer. The game records commands into its own memory and submits handles. The host replays them into Metal 4 command buffers, commits them in segments, and presents. Related files:
- object lifetimes: [lifetimes.md](lifetimes.md);
- the globals: [nvn-state.md](nvn-state.md);
- the locks: [locks.md](locks.md);
- every host thread: [overview.md](overview.md) and [host-threads.md](host-threads.md).

## Files

| File | Role |
|---|---|
| `dm/gfx/nvn/hle_nvn.c` | NVN entry points. Objects live in place in the game's memory, and command buffer calls write records (header comment `hle_nvn.c:1-10`) |
| `dm/gfx/nvn/nvn_obj.h` | Object layouts and the record format, shared by both sides. Layouts: `queue_t` :19, `pool_t` :23, `tex_t` :41, `prog_t` :56, `sync_t` :58, `win_t` :65, `cmd_t` :69-82. Records: `op_hdr {op, size}` :101, op codes :102-110, payloads :112-195 |
| `dm/gfx/nvn/nvn_mtl.m` | The replay: records into Metal 4, submissions, residency, present. `mtl_exec` is at `nvn_mtl.m:11719` |
| `dm/gfx/nvn/nvn_rec.h` | The encode thread, included at `nvn_mtl.m:210` |
| `dm/gfx/nvn/nvn_capture.h`, `nvn_capture.c`, `nvn_capture.inc` | Frame capture (`DM_NVN_CAPTURE`). The `.inc` file is included at `nvn_mtl.m:13109` |
| `dm/gfx/tests/nvn_replay.m` | The replayer. It includes `nvn_mtl.m` and `hle_nvn.c` in one translation unit (`nvn_replay.m:13-17`) |

## Entry points

| What | Where |
|---|---|
| Slot table `nvn_slot[NVN_NFUNC]` | `hle_nvn.c:46` |
| `NVN()` macro: places each entry in section `__DATA,swnvn` | `hle_nvn.c:67-71` |
| `nvn_init_slots`, `nvn_lookup`; `nvnBootstrapLoader` returns `nvn_lookup(name)` | `hle_nvn.c:87`, `:103`, `:112-113` |
| `nvn_nops_register` (a constructor): installs empty implementations. Implemented functions outside `nvnCommandBuffer*` run through `nvn_big_entry` (big host stack); `DM_NVN_PROF` adds a timing wrapper | `hle_nvn.c:1321-1344` |

## 1. Recording (any game thread that owns the command buffer)

`cmd_t` (`nvn_obj.h:69-82`) holds the recording state:
- `cur` / `end`: the current segment;
- `begin`: the first record of the recording, which is its handle;
- `recording`: 0 idle, 2 begun with no record yet, 1 recording;
- `used`: what `GetCommandMemoryUsed` returns.

Steps:
1. `nvnCommandBufferAddCommandMemory` (`hle_nvn.c:888-897`).
   - A null pool, or a grant under 64 bytes, gets a host-lent segment.
   - Otherwise `hostseg_release` frees the host segments whose recording overlaps the range the game hands out (`:883-887`).
   - `cmd_new_segment` (`:829-835`) writes a 16-byte `OP_JUMP` at the old write position when the recording already has records.
   - `used` is reset.
2. `nvnCommandBufferBeginRecording` (`:925-929`) sets `recording = 2`. No BEGIN record is written.
3. Each command calls `rec()` (`:971-976`, through the `REC` / `RECN` macros at `:977-981`), which calls `cmd_alloc_keep` (`:903-920`):
   - the size is 8-aligned, and `OP_RESERVE` (16 bytes, `:801`) is kept free after the record;
   - out of room, it calls the game's memory callback, and after 2 tries (or with no callback) takes a host segment;
   - the first record sets `begin` and `recording = 1`.
4. `nvnCommandBufferEndRecording` (`:930-935`) writes `OP_END` and returns `begin` as the `NVNcommandHandle`.

Host segments: `hostseg_t` and `g_hostseg` (`:853-857`); sizes `HOSTSEG_SZ` 256 KB and `HOSTSEG_SMALL` 4 KB, cap `HOSTSEG_CAP` 1 GB (`:850-852`); `hostseg_size` (`:858`) and `hostseg_take` (`:863-882`). See `docs/reference/nvn-objects.md`, "Host-lent command memory segments".

What the recorders write:

| Command | Recorder | Record |
|---|---|---|
| Render targets | `nvnCommandBufferSetRenderTargets` `hle_nvn.c:1006` | `OP_SET_RT`, `p_set_rt` (`nvn_obj.h:112`). `tex_snap` (`hle_nvn.c:989-1005`) copies each texture object (0x80 bytes) after the record. An object that is invalid at record time keeps its pointer. See `docs/reference/rendering.md`, "Texture objects copied into command records" |
| State objects | `bind_state` `:1037`, callers `:1038-1043` | `OP_BIND_STATE`, with only the state's own bytes |
| Texture, sampler and image handles | `bind_handles` `:1078-1094` | `OP_BIND_TEX` / `OP_BIND_SAMP` / `OP_BIND_IMG`, `p_bind_handles` (`nvn_obj.h:148`); one combined bind is `OP_BIND_TEX1` |
| Uniform buffer | `nvnCommandBufferBindUniformBuffer` `:1059` | `OP_BIND_UBO_SMALL` |
| Uniform update | `nvnCommandBufferUpdateUniformBuffer` `:963-968` | `OP_UPDATE_UB`, with the data copied into the record |
| Draws | `rec_draw` / `rec_draw_idx` `:982-983`, callers `:1115-1121` | `OP_DRAW` / `OP_DRAW_IDX`, cut short unless the draw is indirect or a multi-draw |
| Dispatch | `nvnCommandBufferDispatchCompute` `:1123` | `OP_DISPATCH`, with the caller's return address (`p_dispatch.caller`) |
| Barrier, pools | `:1131`, `:1132` | `OP_BARRIER`, `OP_SET_TEX_POOL` / `OP_SET_SAMP_POOL` |
| Fence sync, event | `:947`, `:940` | `OP_FENCE_SYNC`, `OP_SIGNAL_EVENT` |
| Nested command buffers | `nvnCommandBufferCopyCommands` `:937` | One 16-byte `OP_CALL` per handle (`:938`). `nvnCommandBufferCallCommands` (`:2582`) calls `CopyCommands` |

## 2. Submit: `nvnQueueSubmitCommands` (`hle_nvn.c:1278-1302`)

This runs on the game thread that submits.
1. Takes `g_sub_mu` (`:1279`, defined at `:80`). The lock comes before the graphics gate (comment `:1276-1277`).
2. `mtl_prepare` (`:1280`, `nvn_mtl.m:809-811`), outside the gate: the first submission's prepare step (`shmap_load`).
3. `gfx_enter` (`:1281`, defined at `:1258`) waits while `dm_gfx_suspend` (`:1264-1272`) holds the gate.
4. `mtl_queue_activate(serial)` (`:1284`, `nvn_mtl.m:5680-5692`) saves the active queue's draw state `S` and render state `R`, then restores or creates this queue's. See `docs/reference/nvn-objects.md`, "Bindings belong to each queue".
5. `mtl_set_queue_origin_lower_left` (`:1285`).
6. `nvn_cap_submit(n, h)` (`:1286`): the capture hook (section 13).
7. `mtl_sub_begin` (`:1287`, section 3).
8. `nvn_ft_poll` (`:1288`, `hle_nvn.c:422`) checks textures registered for dirty upload, up to `FT_POLL_BYTES` per poll. It returns at once unless the profile sets `DM_GAME_TEX_DIRTY_UPLOAD`.
9. `mtl_sub_index(h, n)` (`:1289`, `nvn_mtl.m:8910-8911`) builds the store lookahead index for the submission when `tbdr_on()`, and clears it otherwise.
10. For each handle (`:1290`):
    - `mtl_exec_rest(h+i+1, n-i-1)` (`nvn_mtl.m:8242`) tells the lookahead which handles follow;
    - `mtl_exec(h[i])` replays it (section 4).

    Then `mtl_exec_rest(NULL, 0)` (`:1291`).
11. `mtl_sub_commit` (`:1292`, section 8).
12. Releases `g_sub_mu` (`:1293`), adds up the statistics, and calls `gfx_leave` (`:1300`).

Two queues on two threads serialize on `g_sub_mu`: `docs/reference/nvn-objects.md`, "Submissions from two queues on two threads".

## 3. `mtl_sub_begin` (`nvn_mtl.m:812-849`)

1. `g_sub_serial++` and `g_seg = 0` (`:813`).
2. `defer_drain()` (`:814`) releases what completed submissions no longer need ([lifetimes.md](lifetimes.md)). `defer_reset()` (`:815`, `:9174`) clears the deferred-draw (merged pass) state, not the release queue.
3. `mtl_prepare`, then `warm_claim` (`:816-817`, `:10775`).
4. Aborts with "submit re-entered" if `g_cb` is still set (`:818`).
5. Records the submit thread in `g_sub_thread` (`:819`) and pushes the submission's autorelease pool `g_sub_pool` (`:821`).
6. `g_cb = rec_cb_new()` (`:822`, `nvn_rec.h:327`): a real `MTL4CommandBuffer`, or a `DmRecCB` stand-in when the encode thread is on.
7. Picks an allocator (`:825-833`):
   - the first `g_alloc4[i]` whose `g_alloc_fence[i] <= g_done`;
   - else a new one, up to `ALLOC_MAX` (32);
   - else waits (`WS_ALLOC`) for the oldest.

   Then `reset` and `beginCommandBufferWithAllocator:`.
8. Creates `g_commit_blocks` (`:834`).
9. Visibility (`:836-845`): retires the last submission's overflow buffer, then picks a `g_vis_ring` slot whose fence has passed, waiting if none has.
10. `pg_sub_begin_ext(g_fence + 1)`, `arena_begin()` and `sp_sub_begin()` (`:846-848`).

## 4. The op loop: `mtl_exec` (`nvn_mtl.m:11719-11874`)

The loop reads `op_hdr` records in order until `OP_END` (`:11736`). Before the switch:
- `sdx_seq` (`:11727`) advances the lookahead index;
- `hoist_take` (`:11732`) skips ops already run ahead;
- `lc_land` (`:11734`) lands waiting clears before any op that cannot keep them.

| Ops | Handling | Line |
|---|---|---|
| `OP_END` | Returns; `g_exec_cur = NULL` | `:11736` |
| `OP_JUMP` | Continues at the target (segment link) | `:11743` |
| `OP_CALL` | Recurses into `mtl_exec`, pushing the return point on `g_ret` (`:8240`, depth 16) for the lookahead | `:11744` |
| `OP_SIGNAL_EVENT` | `mtl_sub_event` (`:1377`) queues post op kind 1 | `:11747` |
| `OP_REPORT_COUNTER` | Samples passed: post op kind 3 with `vis_snapshot()` (`:673`). Other counters: `mtl_sub_counter` (`:1378`) | `:11749` |
| `OP_RENDER_COND` | Sets `g_rc_skip` | `:11755` |
| `OP_FENCE_SYNC` | `s->fence = g_fence + 1; s->fenced = 1`: the fence this submission commits with. See `docs/reference/nvn-objects.md`, "Fence syncs recorded in command buffers" | `:11761` |
| `OP_RESET_COUNTER` | Samples passed: `vis_clear`; ends a pass begun without a visibility buffer | `:11763` |
| `OP_CLEAR_BUF`, `OP_COPY_B2B`, `OP_UPDATE_UB` | `mtl_sub_fill` (`:1360`), `mtl_sub_copy` (`:1106`), `mtl_sub_update` (`:1333-1358`) | `:11773-11776` |
| `OP_SET_RT` | Continues the pass when the targets match (several tests). Otherwise lazy clears (`lc_push`) or `rp_flush`, then `sub_cut()` and `R.rt = *r` | `:11780-11794` |
| `OP_CLEAR_COLOR`, `OP_CLEAR_DS` | A load action in `R`, or a triangle (`clear_color_tri` / `clear_ds_tri`); a clear inside a pass ends it | `:11796`, `:11813` |
| `OP_DRAW`, `OP_DRAW_IDX` | `draw` (`:10421`, wraps `draw_`) unless `g_rc_skip`; `g_exec_next` is set for the lookahead | `:11832-11833` |
| Binds and fixed state | `state_op` (`:8432-8547`) writes `S` / `R` and dirty flags | `:11835-11854`, `:11869` |
| Copies, clears, DLSS | `copy_b2t` (`:11085`, sets `g_cut_copy` at `:11104`), `copy_t2b` (`:10934`), `copy_t2t` (`:11268`), `draw_tex`, `clear_tex`, `dlss_eval` | `:11855-11860` |
| `OP_DISPATCH` | `dispatch` (`:10843`), unless already hoisted (`csh_take`) | `:11861` |
| `OP_BARRIER` | Ends the pass after shader writes, otherwise notes the order bits; sets `g_game_barrier` | `:11863` |

## 5. Passes and encoders

| Encoder | Opened by | Closed by | Notes |
|---|---|---|---|
| Render pass, `g_enc` (`:3479`) | `rp_begin_ex_` (`:4039-4254`): ends `g_blit` first (`:4049`, and again after `bcrt_attach` at `:4248`), so the two are never open together; `MTL4RenderPassDescriptor` from `R`, load actions from the pending clears (`:4058`, `:4101`, `:4107`), visibility buffer (`:4228`); `g_enc = enc_r_begin_pass(pd); args_dirty_all(); g_stat_pass++` (`:4250-4252`) | `rp_end` (`:3886-3901`): `sd_finish`, `enc_r_end_pass`, `g_enc = nil`, then `ubd_flush`, `bcrt_flush`, `rt_mirror_flush` | `rp_flush` (`:4266-4271`) opens a clear-only pass for pending clears, then ends it |
| Copy encoder, `g_blit` (`:765`) | `blit_open` (`:1040`); `blit_raw` (`:1043-1048`) ends the render pass first and lands deferred uniform updates | `enc_b_end` followed by `g_blit = nil`, at 24 sites: `rp_begin_ex_` (`:4049`, `:4248`), `sub_cut` (`:11547`), `mtl_sub_commit` (`:1606`), `mdi_wait` (`:10100`), `ubd_land_compute` (`:1050`), `rt_mirror_flush` (`:3884`), `ms_after` (`:9793`), `ixc_run` (`:9954`), `wide_run` (`:10029`), `mdx_run` (`:10175`), `dispatch` (`:10873`, `:10889`), `copy_t2t_draw` (`:11173`), `draw_tex` (`:11225`), `copy_t2t` (`:11301`, `:11373`), `dlss_eval` (`:11419`, `:11433`), `clear_tex` (`:11503`), `clear_tex_tri` (`:11655`), `td_dump` (`:12083`), and in `nvn_geometry.inc` `vertex_dump` (`:137`) and `geo_draw_` (`:807`) | A compute encoder, since Metal 4 copies are compute work. `blit_buf` / `blit_barrier` (`:1051`, `:1084-1098`) add barriers by guest range. See `docs/reference/rendering.md`, "Metal 4 does not order operations inside one encoder" |
| Dispatch | `dispatch_enc` (`:10835-10842`) shares `g_blit` and sets `g_ct`; `DM_NVN_DISPATCH_OWN=1` gives each dispatch its own encoder (`dispatch_own` `:10829`) | as the copy encoder | See `docs/reference/rendering.md`, "Compute dispatches share the copy encoder" |

Barriers:
- `m4_end` (`:872-877`) ends an encoder with a barrier from all stages to all queue stages.
- `enc_r_begin_pass` (`:960-966`) skips the full consumer barrier only when all of these hold (`:962`): the last encoder was a relaxed draw pass, the game issued no barrier since, `DM_NVN_BARRIER=game` (`barrier_game` `:884`), no image heap exists (`g_image_heap_n`), and no sparse mapping was made (`g_sp_mapped`).
- `enc_r_end_pass` (`:967-971`) uses the relaxed end barrier only in that mode and without image heaps (`:968`).

Each render pass binds the argument tables `g_vt` (vertex) and `g_ft` (fragment) (`:965`).

## 6. One draw: `draw_` (`nvn_mtl.m:10422-10786`)

1. A geometry-shader program goes to `geo_draw` and returns (`:10448-10449`).
2. `image_prepare` (`:10459`).
   - A deferred uniform update that conflicts with the draw ends the pass and lands (`:10467`).
   - Lazy clears are taken (`lc_take`, `:10472`).
   - Index, multi-draw and wide-index conversions run on the GPU first (`ixc_run`, `mdx_run`, `wide_run`, `:10473-10478`).
3. Pass split checks (`:10500`, `:10510`), `fb_prepare` (`:10512`), `vbuf_prepare` (`:10535`).
4. `en = rp_begin_ex(mode)` (`:10536`, `:4037`) opens the pass if none is open.
5. Pipeline state: `pso_get`, cached by program and pass serial (`:10553-10557`); depth-stencil: `dss_get` (`:10571-10572`).
6. Vertex input: `pull_bind` for a pulling pipeline, else `bind_vbufs` and `vconv_bind` (`:10605-10608`).
7. Arguments: `encode_args(en, vs, 0, 1)` and, unless rasterizer discard, `encode_args(en, fs, 1, 0)` (`:10611-10612`, section 7).
8. If binding the arguments ended the pass (`g_enc != en`), the draw is encoded again once (`:10616-10620`).
9. Occlusion counting takes a visibility slot for the pass (`:10632-10641`).
10. `g_stat_draw++` (`:10644`), then the `enc_r_draw*` call.

## 7. Argument encoding: `encode_args_` (`nvn_mtl.m:7941-8216`)

1. `args_sync_dirty` (`:7764-7769`, called at `:7945`) marks every stage dirty when `g_reg_gen`, `nvn_dirty_now()` or `g_ser_gen` changed.
2. Reuse (`:7946-7948`): `bind_args` (`:7771-7775`) binds the shader's cached block by its GPU address (`ab_gpu`; `ab_buf` only marks it as encoded since refactor item C1; `NvShader` `:4379`), and `g_stat_args_reuse++` counts it, when all of these hold (`:7946`):
   - `!passdump()`, and the stage is not compute (`nvn_stage != 5`: compute blocks are never reused);
   - the stage is clean and `sh->ab_pass == g_pass.serial`;
   - a shader that reads the driver bank has the same `ab_binst` (`g_draw_binst`);
   - a shader that reads pool addresses has the same `ab_pgen` (`g_psnap_gen`).
3. Otherwise:
   - takes `g_rmu` (`:7959`);
   - walks the reflection bindings (uniform buffers, samplers, textures, images, texture buffers, dynamic texture arrays). Push constants, the driver banks `DRV0` / `DRV2` and border factors are written into arena memory inside `g_rmu` (`arena_alloc` at `:8142`, `:8151`, `:8202`), so `arena_new`'s `g_mu` nests inside `g_rmu`;
   - releases `g_rmu` (`:8209`).
4. `arena_alloc(arg_len)` (`:8210`) takes the block. `bind_args` (`:8212`) binds it, through `enc_r_args` (`:994-1000`) or `enc_c_args` (`:1011`). With the encode thread on, these write the table as a record (`rec_table_op`).
5. Caches the block in `sh->ab_*` (`:8213`) and counts `g_stat_args_enc++` (`:8214`).

Compute dispatches call `encode_args(ce, cs, 5, 0)` (`:10894`) after `enc_c_pso` (`:10891`). Compute pipelines are cached in `g_cps` (`:10854-10862`); built-in kernels take their own path (`:10864-10877`).

## 8. Segments and the commit

`sub_cut` (`nvn_mtl.m:11540-11569`) runs from `OP_SET_RT` (`:11794`). It commits the command buffer so far as a segment when all of these hold:
- there is a `g_cb` and no open render pass;
- `cut_draws()` (`DM_NVN_CUT`, default 64, `:11538`) draws have passed since the last cut, or a buffer → texture copy set `g_cut_copy`;
- no hoist, deferred, fused or merged pass is active.

Steps:
1. Ends `g_blit` and calls `up_flush` (`:11547-11548`).
2. `g_seg++` (`:11550`). A feedback handler records the segment's GPU times and errors (`:11553-11557`).
3. `res_commit`, `endCommandBuffer`, `rec_commit` (`:11558-11560`). With the encode thread on, `rec_publish` hands the segment over now (`:11561`).
4. `g_cb = rec_cb_new()`, begun on the same allocator (`:11562-11563`).

See `docs/reference/frame-rate.md`, "Submissions handed to the GPU in segments", and `docs/reference/rendering.md`, "A segment committed after a buffer → texture copy".

`mdi_wait` (`nvn_mtl.m:10098-10112`) is the third place that commits `g_cb` inside a submission. It is called by `mdi_live` (`:10117`) before an indirect-count multi-draw reads a GPU-written count, and by the diagnostic `ubp_check` (`DM_NVN_UBP_CHECK`, `:10056`):
1. `rp_end`, `ubd_land`, ends `g_blit` (`:10099-10100`).
2. `up_flush`, `res_commit`, `endCommandBuffer`, `rec_commit(g_cb, nil)`, with no feedback handler (`:10101-10103`).
3. `rec_signal(g_mdi_ev, ++g_mdi_v)` and `rec_drain` (`:10105`), then waits on the CPU up to 10 s for that value (`:10106`).
4. `g_cb = rec_cb_new()`, begun on `g_alloc4[g_alloc_cur]` (`:10109-10110`). `g_seg` is not advanced.

`mtl_sub_commit` (`nvn_mtl.m:1602-1648`):
1. Closes the submission's work: `lc_land`, `defer_fallback`, `rp_flush`, `ubd_land`, ends `g_blit`, `up_flush`, `g_cut_copy = 0` (`:1603-1608`).
2. `treg_finish_submission` (`:1609`, `:4845-4854`) drops transient descriptor views behind this fence.
3. `fence = ++g_fence` (`:1610`); `gw_commit`; the visibility ring slot takes the fence (`:1612`).
4. Copies the post ops (`g_post`, `post_op` `:616`) into `g_postr[fence % POST_RING]` (`:1614-1626`, `POST_RING` 128 `:1556`).
5. Adds feedback handlers:
   - the commit blocks (`:1619`);
   - `gpu_tag_done`, the error log, `post_complete(fence)` and `defer_drain()` (`:1627-1634`).
6. `arena_commit(fence)` and `res_commit()` (`:1635-1636`).
7. `endCommandBuffer`, `rec_commit(g_cb, o)`, `rec_signal(g_ev, fence)`, `rec_drain()` (`:1639-1642`).
8. `g_alloc_fence[g_alloc_cur] = fence`, `g_cb = nil`, then pops `g_sub_pool` (`:1643-1646`).

## 9. Completion and waits

| Piece | Where | What it does |
|---|---|---|
| `g_fence` / `g_done` | `nvn_mtl.m:129`, `:133` | `g_fence`: the fence of the last submission handed out. `mtl_sub_commit` advances it (`:1610`) before the buffer is ended and committed (`:1639-1640`; with the encode thread on, the commit happens on `dm-encode` by the time `rec_drain` `:1642` returns), so another thread can read a `g_fence` whose commit is still in progress. `g_done`: the completed fence, with its CPU writes published |
| `post_complete` | `:1588-1601` | For each fence from `g_done+1` to `fence`: `post_claim` (`:1561`), which keeps `g_post_mu` locked until `post_run` (`:1566-1587`) returns. Then `g_done = fence` under `g_mu` and a broadcast on `g_cv` |
| `post_run` | `:1566-1587` | Kind 1 event write, kind 3 samples-passed sum, kind 4 mirror readback, else a counter report |
| `mtl_wait_at` | `:1659-1686` | A game wait at `WS_SYNC`, `WS_SYNC_NEWEST` or `WS_ACQ` (not `WS_SYNC_POLL`), with `DM_NVN_FAST_WAKE` on (`fast_wake` `:1653`), `g_ev` set and `fence <= g_fence` (`:1662`), waits on `g_ev`. On the signal it runs `post_early` (`:1656`), which runs `post_complete` on the waiting game thread (`:1664`). If `g_done` still trails, the wait takes off the time spent (`:1669-1673`) and waits on `g_cv` with the rest of its budget (`:1675-1682`). Every other wait waits on `g_cv` until `g_done >= fence` |
| `nvnSyncWait` | `hle_nvn.c:737-745` | `mtl_wait`, or `mtl_wait_acq` for `fenced == 2` (`nvn_mtl.m:1687-1688`) |
| `nvnQueueFenceSync` | `hle_nvn.c:726` | `fenced = 1, fence = mtl_last_fence()` (the last committed fence) |
| `nvnQueueWaitSync` | `hle_nvn.c:729` | Does not wait |
| `nvnQueueFinish` → `mtl_finish` | `hle_nvn.c:791`, `nvn_mtl.m:1690-1700` | Waits for `g_fence`. On the submit thread it also publishes encode records, then waits for pending upload batches. See `docs/reference/nvn-objects.md`, "`nvnQueueFinish` waits for the GPU, not the display" |
| Events | `hle_nvn.c:747-755` | `ev_signal` is a CPU write |

## 10. Present

Acquire, `nvnWindowAcquireTexture` (`hle_nvn.c:1404-1435`):
1. Takes the next index, `o->next++ % ntex` (`:1406`).
2. Paces to `avail[idx]`, or follows the display link (`:1414-1418`).
3. `mtl_snap_acquire_wait` (`:1426`, `nvn_mtl.m:12896`) waits for a free snapshot ring slot.
4. `mtl_present_wait(o->ticket[idx])` (`:1430`, `nvn_mtl.m:13004-13035`) waits until this image's previous present is processed.
5. The sync gets `fenced = 2, fence = mtl_last_fence()` (`:1431`).

`nvnQueuePresentTexture` (`hle_nvn.c:1896-2040`) does not take `g_sub_mu`:
1. `dm_fps_lock_tick` (`:1898`), `fstep_tick` (`:1902`), `present_cfg` (`:1904`), the test lag (`:1919-1920`).
2. `gfx_enter` (`:1922`).
3. `present_crop` and `nvn_cap_present` (`:1925-1926`).
4. `o->ticket[idx] = mtl_present(t, period, crop)` (`:1927`). `mtl_present` (`nvn_mtl.m:12845`) calls `present_enqueue`.
5. `gfx_leave` (`:1929`).
6. Statistics, then `dump_frame` (`:2007`; it advances `g_frame`, `:1443-1474`) and `mtl_set_frame(g_frame)` (`:2009`).
7. `o->avail[idx] = slot + period` (`:2016`).

`present_enqueue` (`nvn_mtl.m:12970-13001`):
1. Returns ticket 0 under `g_classic` or while presents are discarded (`:12972`).
2. On the submit thread, a texture whose content comes from storage is resolved and its upload batch committed: `tex_mtl`, `up_flush` (`:12977`).
3. Starts the present thread once (`:12978`) and calls `link_sync` (`:12979`, `:12756`).
4. With snapshots on, `snap_take` (`:12990`, `:12911-12969`) copies the texture into a host ring slot, and the queued item names the slot's serial.
5. Enqueues into `g_pq[PQ]` (`PQ` 8, `:12622`) under `g_pq_mu`, waiting only when the queue is full (`:12992-12993`).
6. Returns the ticket, or 0 for a snapshot (`:13000`).

`present_now` (`nvn_mtl.m:12494-12614`) runs on `nvn-present` (`present_main` `:12812-12835`), or on `nvn-present-link` in the display link callback, with the link's drawable (`:12696`):
1. `res_commit()` (`:12512`). See `docs/reference/rendering.md`, "The residency set committed before a present".
2. Adds the layer's residency set to `g_q4` once per layer (`:12551`).
3. Takes the supplied drawable or `nextDrawable` (`:12558`).
4. Takes a present allocator from `g_present_alloc4[3]` after its last present completed (`:12564`). See `docs/reference/frame-rate.md`, "A present command allocator is reused only after its own present completes".
5. `waitForDrawable`, then `present_encode_m4` (`:12568-12571`).
6. A feedback handler advances `g_pq_done` and `g_present_alloc_done` (`:12576`).
7. `commit` on `g_q4` (`:12583`), then `signalDrawable` (`:12599`).
8. `present` or `presentAfterMinimumDuration` (`:12611`).

Snapshots: comment `nvn_mtl.m:12857-12872`; `g_snap[SNAP_MAX]` (4, `:12873-12875`); `mtl_snap_on` (`:12881`). With the encode thread on, the copy is a block of its own queue (`rec_own_push`, `:12956-12962`). Otherwise it is committed on `g_q4` under `g_res_mu` (`:12964`). See `docs/reference/frame-rate.md`, "Present snapshots: the game's swapchain texture free at once", and `docs/reference/rendering.md`, "A present snapshot's copy needs the same residency commit".

## 11. The encode thread (`dm/gfx/nvn/nvn_rec.h`)

On by default on iOS. On the Mac it follows `DM_NVN_ENC_THREAD`, or the profile's `enc_thread` (`rec_on` `nvn_rec.h:80-90`).

| Piece | Where | Role |
|---|---|---|
| Stand-ins | `DmRecTable` `:245-253`, `DmRecEnc` `:255-316`, `DmRecCB` `:317-325` | Turn each Metal call into a fixed-size `rec_t {op, nobj, a[15]}` (`:74`) and retain object arguments with `rec_obj` (`:96`). A selector with no stand-in aborts (`rec_missing` `:242`) |
| Op codes | `RO_*` `:62-73` | Command buffer, commit, signal, encoders, barriers, render / compute / table calls, `RO_NOTE`, `RO_SPARSE_MAP` |
| Blocks | `REC_BLK` 256, `rec_blk` `:75-76`; `g_rb_*` `:91-94` | The submit thread fills `g_rb_cur` (`rec_put` `:204-216`). The first `rec_put` starts the thread, with a 1 MB stack |
| Hand-off | `rec_publish` `:197`, `rec_drain` `:218-227` | Publish queues the open block. Drain publishes, then waits until the thread is idle |
| Encode thread | `rec_thread` "dm-encode" `:179-194`; `rec_exec` `:110-178` | Makes the calls on the real objects. `RO_COMMIT` waits for the uniform shadows (`ubc_wait`) and commits under `g_res_mu` (`:116-123`). The objects are released after the call (`:177`) |
| Blocks from other threads | `rec_own_begin` / `rec_own_put` / `rec_own_push` `:230-241` | The snapshot copy: a whole block appended behind every published block |
| Entry points | `rec_cb_new` `:327`, `rec_table` `:328`, `rec_commit` `:330-335`, `rec_commit_upload` `:337`, `rec_signal` `:342`, `rec_sparse_map` `:343` | With the thread off, they call Metal directly; `rec_commit` and `rec_commit_upload` then commit on `g_q4` without `g_res_mu` (`:332-334`, `:339-340`) |
| Uniform copy queue | `ubc_*` `:17-60`; the first `ubc_push` (`:51-53`) starts the thread, whose body is `ubc_thread` "dm-ub-copy" (`:24-38`) | Fills large uniform shadows (`ubp_get`) off the submit thread |

`q_cb` (`nvn_mtl.m:797`) makes classic-queue (`g_q`) command buffers, for readbacks and diagnostics. On the submit thread it runs `up_flush`, `rec_drain` and `up_wait_zero` first. Not every buffer made outside the replay goes through it (the comment at `:792-795` says so, but the code differs):
- Metal 4 buffers are made directly: present `g_present_cb` (`:450`), upload batch `g_up_cb` (`:2214`), snapshot `g_snap_cb` (`:12930`), offscreen present (`present_offscreen_m4` `:12398`) and stream (`stream_setup` `:12449`);
- two classic buffers skip it: `udc_selftest` (`:373`, on a queue of its own, only with `DM_UDC_SELFTEST`) and `dummy_tex`'s zero clear on `g_q` (`:7555`).

## 12. Uploads

Texture uploads on the submit thread form a batch with its own command buffer:
- `up_begin` (`nvn_mtl.m:2202-2221`) waits for the slot's previous batch, then begins on `g_up_alloc4[slot]`;
- `up_alloc` (`:2239-2281`) gives out staging space;
- `up_flush` (`:2143-2200`) encodes the batch's copies, then commits it through `rec_commit_upload`.

The batch belongs to the submit thread (`up_owner_check` `:785-791`). Until the first `mtl_sub_begin`, `up_owner_check` lets every thread through (`!g_sub_thread_set`, `:786`). "The submit thread" is the last thread that called `mtl_sub_begin` (`:819`, never cleared), so with two submitting threads the batch's owner changes at each submission. `mtl_sub_commit` and `sub_cut` flush it before their own commit, so the uploads come first on the queue (comment `:2086-2087`).

## 13. Capture and replay

Capture (`DM_NVN_CAPTURE=<frame>:1:<path>`, parsed by `nvn_cap_enabled` `nvn_capture.inc:28`):
1. `nvn_cap_submit` (`nvn_capture.inc:422`) runs under `g_sub_mu`, before the replay, for each submit of the chosen frame. `cap_submit_step` (`:426-450`):
   - calls `mtl_finish`;
   - opens the file and writes the header (`cap_head`);
   - writes the pools, the registries, and the segments the handles reach (`cap_seg_get` `:181`, `cap_seg_write` `:187`, which follows `OP_CALL` / `OP_JUMP`);
   - flushes the objects, then copies the pool bytes last (`cap_mem` `:377`);
   - writes `CAP_SUBM`.
2. `nvn_cap_present` (`:471`) runs before the present is queued. `cap_present_step` (`:480-507`) takes the presented texture's digest (`cap_digest` `:452`, which waits with `mtl_finish` and reads back on the classic queue through `q_cb`), writes `CAP_PRES`, `CAP_LPIX` and `CAP_PHSH`, and closes the file.
3. A capture step drops the thread's time-constraint policy for its duration (`cap_policy_standard` `:410-418`).
4. A sparse virtual pool fails the capture (`cap_pool_obj` `:122`).

The format is described at `nvn_capture.h:1-7`, with the chunk tags at `:20-42`. Records are relocated by one field walk, `cap_rec_fields` (`nvn_capture.c:58`); `cap_layout` (`nvn_capture.c:35`) fingerprints the payload layouts.

Replay (`dm/gfx/tests/nvn_replay.m`, `main` `:187`):
1. `nvn_serial_floor(1 << 61)` (`:224`). See `docs/reference/nvn-objects.md`, "A replay's own objects take serials above a capture's".
2. Maps the regions (`map_region` `:126`) and registers the pools (`add_pools` `:137`).
3. For each submit, the same sequence as the submit entry, without `g_sub_mu`, the gate or queue activation: `mtl_sub_begin(); nvn_ft_poll(); mtl_sub_index(...)`, the exec loop, then `mtl_sub_commit()` (`:345-347`), then `mtl_finish` (`:349`).
4. Compares `cap_digest` of the presented texture (`:355`). The present path itself is not replayed.

## Threads in one frame

| Thread | Started by | Role |
|---|---|---|
| Game threads | the game | Record (`hle_nvn.c` command buffer calls), submit under `g_sub_mu`, acquire, present enqueue, finalize objects |
| `dm-encode` | first `rec_put`, `nvn_rec.h:204-216` | Makes the recorded Metal calls and commits (section 11) |
| `dm-ub-copy` | the first `ubc_push`, `nvn_rec.h:51-53`; body `ubc_thread` `:24-38` | Fills uniform shadows for `RO_COMMIT` |
| `nvn-present` | `present_start` `nvn_mtl.m:12837`, once from `present_enqueue` | `present_now` for each queued present when the display link does not own the layer (`:12819`) |
| `nvn-present-link` | `link_main` `nvn_mtl.m:12739-12755`, in display-link mode | Sets `g_link_owns_layer`, adds a `CAMetalDisplayLink` to its own run loop and runs it. The delegate (`NvMetalDisplayLinkDelegate` `:12653-12704`) takes queued presents with the link's drawable (`:12696`) |
| `dm.nvn.mtl4-feedback` (dispatch queue) | `mtl_init` `nvn_mtl.m:417` | Runs the Metal 4 commit feedback handlers: `post_complete`, `defer_drain`, segment times, upload batch retirement |
| Program prefetch queue | `pp_bg_queue()`, `mtl_prog_prefetch` `nvn_mtl.m:10806-10817` | Loads a new program's shader libraries in the background |
