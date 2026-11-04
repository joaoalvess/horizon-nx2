# Plan

## Goal

Two goals of equal weight (the user, 2026-11-04 13:30):

1. **A robust architecture and clean code that is easy to maintain.** Today the NVN → Metal layer is one translation unit, `dm/gfx/nvn/nvn_mtl.m`: 13,110 lines (1.26 MB, 1,082 lines over 200 characters), 943 functions (1,107 with the four files it includes), 1,064 file-scope names (about 400 declaration lines) that any function reads and writes, 14 global generation counters, `draw_` 351 lines, `encode_args_` 276, `rp_begin_ex_` 217, eleven functions of 100 lines or more. 75 of the tests `#include` the whole file. Understanding it took five subagents. The second file of the layer, `hle_nvn.c` (2,926 lines, 209 over 200 characters), is called up into by `nvn_mtl.m` through local prototypes. The target:
   - modules of a few hundred to about 1,000 lines, each with one concern, its own state and one small header, so a change touches one module;
   - dependencies that point one way, checked by a test;
   - a reader of one module needs its header and the headers it includes, not the whole layer. The top modules keep a wide fan-out (draw calls 20 modules, exec 21, geo 17, xfer and pass 15); their targets are set at the end of M;
   - no function over 100 lines, no line over 200 characters (stage CL);
   - a module guide in `docs/`, so the next reader needs no subagents.
2. **Lower CPU time per frame** on the fanless MacBook Air M4 (Pokopia, DK Bananza, Mario Kart World):
   - the submit thread runs at about half clock: submit CPU is 5.0-7.5 ms a frame in Pokopia's hot windows, against 1.85-2.0 ms nominal;
   - Pokopia's hot frames sit 2.0-2.6 ms above their GPU time;
   - DK's frame-rate controller counts translation time: 5-9 ms on the M4 Pro, 10-15 ms estimated on the hot Air.

   Measured background: `PERF_M4.md`, `/Volumes/Hangar/Games/Pokopia_v2.0.1a/0400A3A01EE4C000-work/host-opt/round2/cpu.md`.

The picture and the game-visible behaviour stay unchanged throughout.

## Method

- **Safety net first**: frame captures replayed by `nvn_replay`, and the command-stream digest (S3a), which proves a pure move changed nothing.
- **Upstream before the split** (D7): what upstream changed in `dm/gfx/nvn` comes in while it is still a cherry-pick, and the baselines are taken after it.
- **Structure first, performance on top of it**: the modules (M) and their interfaces (I) come before the command sink, the data model and asynchronous submission, so each later change lands in a small module with a clear owner.
- **One concern per commit.** A move is verbatim (code and its comments unchanged), made by a move tool from the module map's function list and checked mechanically (below); cleanup of what moved is stage CL. Behaviour changes carry their tests.
- **Measurement is reported, not a gate** (the user, 13:20): an item is dropped only when it cannot be made correct. A new call in a hot function (the call check below) is a defect of the move and is fixed before the next step; that is a fix, not a drop.
- **Fix forward in M** (`rules.md` amended when the user approves this plan). The moves depend on each other, so `rules.md`'s "a committed item that fails later leaves through `git revert`" does not apply to them: a fault found after a move is fixed by a new commit. Items outside M keep the revert rule.
- Every new component is written test-first; everything moved or rewritten keeps or gains characterization tests.
- Several subagents throughout: implementers, independent reviewers, searches (the user, 2026-11-04).

## Decisions (the user's)

| # | Decision | Recommendation | State |
|---|---|---|---|
| D1 | Diverge from upstream (`seedds/nxnative`) in `dm/gfx/nvn` | Diverge from S3 on; S0-S2b stay cherry-pick friendly (small, local diffs) | decided 2026-11-04: diverge from S3 on |
| D2 | Scope: `dm/gfx/nvn` + `nvn_rec.h` only, or the whole host | `dm/gfx/nvn` + `nvn_rec.h`, plus the host-thread track HT; services and SVCs only where a finding shows a cost | decided 2026-11-04: `dm/gfx/nvn` + `nvn_rec.h` + HT. `hle_nvn.c` is inside it (stage N) |
| D3 | Order: modules at the end (old S6) or first | Modules first, right after the digest; the context struct of old S3b is replaced by state owned per module | decided 2026-11-04 13:35: modules first |
| D4 | How the 75 white-box tests follow the split | During M, one transitional unity file (`dm/gfx/nvn/nvn_mtl_all.inc`, the modules in their original order) that the tests include instead of `nvn_mtl.m`; `nvn_replay`, `t_capture_live` and `t_rec_digest` move first, in M0, onto module objects built like the host. End state (stage T): a test includes only the module(s) whose statics it reaches and links the other modules' objects (option (d) of `reports/20261104-1352-split-mechanics.md` 2.3: statics stay static); tests whose oracle is the stream use S3a's recorder digest in T and the test sink from SK on (c); the `NVN_TESTABLE` linkage (b) only for a test that needs statics of more than three modules. The unity file is deleted at the end of T | decided 2026-11-04 15:05 (the user) |
| D5 | iOS Release builds `-Os` without LTO (`dm/ios/project.yml` sets neither key): after the split it inlines nothing across modules, and iOS runs the recorder for every game | `GCC_OPTIMIZATION_LEVEL = 2` and `LLVM_LTO = YES_THIN` in the Release configuration, the Mac's S1 choice (ThinLTO alone at `-Os` inlines only very small callees, because of the size threshold). Decided before M step 1; an unsigned Release link joins the checks either way | decided 2026-11-04 15:05: `-O2` + ThinLTO, before M step 1 |
| D6 | rewrite and geo call back into draw / dispatch, against the layer order | One whitelisted header, `mtl_replay.h`, through which rewrite (27) and geo (29) call `draw` / `dispatch` directly: direct calls, findable with `grep`, no init order. Its note and the check's whitelist entry state the re-entrancy contract: `rp_end` → `fz_end` → `fz_check_run` → `draw_` can run inside `encode_args_` with `g_rmu` held (night file, Open 05:00), and `draw_` must cope with a pass ended under it, as it does today (`nvn_mtl.m` 10613-10620). A function table would also work (one predictable indirect call per replayed draw; `draw` is a one-line wrapper of the 351-line `draw_`, so nothing is inlined either way), but hides the callee from a reader | decided 2026-11-04 15:05: `mtl_replay.h` |
| D7 | Upstream sync before the split, and how upstream reaches the fork after it | `git fetch upstream` at 14:40: 155 upstream commits are not on `main`, 56 of them in `dm/gfx/nvn`; `nvn_mtl.m` differs by 1,617 changed lines from the merge base (`6136418b`, 2026-11-03), and upstream wrote 104 commits on 2026-11-04 alone. They reach all three games: an upstream profile for Mario Kart World at 60 fps (`1d4b8e82`, `dm/games/0400C3F00006E000`; it registers only the base build v0, while the fork plays update v917504 / 1.8.0 on its provisional profile), its sparse tiles shared by physical memory (`1110473c`), DK's upscaler through MetalFX (`85468b6c`, 3.5-5 → about 1 ms a frame on an M1), DK's mesh draws in one dispatch (`84ec307f`), Pokopia's shader builds (`e70fd69d`), a finalization crash fix (`1440a736`). Recommendation: stage U now, before S3a's baselines; then `nvn_mtl.m` frozen on `main` during M; after M, an upstream hunk reaches its module through a script that maps the hunk's enclosing function to its module (from the map's function list), and syncs happen at stage boundaries only. That procedure goes into `docs/development.md`, and `CLAUDE.md`'s "Branches" paragraph links to it (`CLAUDE.md` is at 1,499 of its 1,500 words). For MKW, the user chooses: a profile derived from upstream's for 1.8.0 (as the NSP script derives one, without upstream's per-build fixes), or the base game v0 on upstream's profile; U then rewrites `CLAUDE.md`'s MKW sentence and `commands.md`'s `DM_GAMES_DIR` line | decided 2026-11-04 15:05: U now; MKW on a profile derived from upstream's for 1.8.0 |
| D8 | 168 single-caller callees cross a module boundary in the map (34 from `draw_` after the sink-copy merge, 29 from `mtl_exec`, 8 from `encode_args_`, 8 from `rp_begin_ex_`): across modules ThinLTO gives no single-caller bonus, so each can become a call | On the per-draw and per-binding paths: the callee becomes a `static inline` in its owner's header when small, or stays `static` beside its caller until I divides the straddling function; the call check below enforces it. Elsewhere: accept the call | decided 2026-11-04 15:05 (the user) |
| D9 | Cleanup rules (stage CL). `rules.md` forbids reformatting and removing comments, and the user's global rule forbids modifying pre-existing comments outside the diff | Per module, one commit each: (1) wrap lines over 200 characters; (2) rewrite comments that cite `nvn_mtl.m` line numbers (about 100) to name functions; (3) divide functions of 100 lines or more along their seams. No other wording change, no comment removed | decided 2026-11-04 15:05: all three |
| D10 | Boot schedule during M. `CLAUDE.md`: a change to the host is checked by booting each game it reaches | A module step (its cut commits plus its move commit) boots all three games once, at its end; each cut commit inside it gets the per-commit tier only (builds, digest, count, call and move checks, the module's tests; under Stages) | decided 2026-11-04 15:05 (the user) |
| D11 | When `refactor` merges into `main` | At the end of M0, M, I, N, SK, S4 and S5, each after the three boots and the corpus; HT items merge one by one | decided 2026-11-04 15:05 (the user) |

## Design principles

- **One module, one concern.** A module is one `.m` / `.c` file and one header in `dm/gfx/nvn`. It owns its state: no other module's `.m` names its globals; only its own header inlines read them, through hidden `extern`s. The dependency check enforces this after stage I.
- **Dependencies point one way.** The modules form layers (below); a module calls only modules under it. A cycle is cut by moving the function to the module that owns its data, or by a link-time `const` table defined by the upper module with static initializers (as the hook table is), or by a function pointer a queued object carries, set by its enqueuer (the post-op's `land`, the map's fence → tex cut), never by per-draw dynamic dispatch and never by a slot filled at init (it is NULL in a test that skips `mtl_init`, adds an init order, and hides who fills it). A check in `dm/tools/tests` keeps the direction; `hle_nvn.c` is a node in it, and a `.m` may not declare another file's function in a local prototype.
- **Locks belong to their module.** A module's lock is taken only by its own functions. No slot, hook or re-entry call is made while a lower module's lock is held (today `g_rmu`, owned by treg, is taken in args, `encode_args_` 7959, and in draw, `image_prepare` 7709, and held across the `DM_NVN_FUSE_CHECK` path). After M, the nesting analysis of `agents/architecture/locks.md` is run again.
- **Small public headers** (interface segregation): a header declares what other modules call, nothing more. At the end of stage T, `nvn_replay` includes headers only, and a test includes headers plus at most the module(s) whose statics it reaches (D4); none includes `nvn_mtl.m` or the unity file.
- **Rules of the split** (`reports/20261104-1352-split-mechanics.md`; verified by probes):
  - modules flat in `dm/gfx/nvn`, named `mtl_<concern>.m` / `.h` (the host and iOS builds pick them up with no edit; no `_mac` suffix);
  - a function with one caller stays `static` in its caller's module, except as D8 decides;
  - a hot helper shared across modules is a `static inline` in its owner's header (`always_inline` on per-draw and per-binding paths), reading the owner's state through hidden `extern`s; it returns plain `id`, never `__unsafe_unretained` (clang ignores the qualifier on a return type and warns; ARC removes the retain / release pair in the inlined caller); never an out-of-line accessor returning an ObjC object;
  - functions that use ObjC class literals, `@"…"`, `@selector`, `dispatch_once` or `used` statics stay in the module that calls them on hot paths (ThinLTO never imports them);
  - a function with any function-local `static` (a lazy `static … = -1` switch cache, a once-counter such as `static int k; if (k++ < 8)` at 11556) never becomes a header inline: each including file would get its own copy;
  - names that leave a module carry its prefix and hidden visibility, so `-Wl,-export_dynamic` does not export them; `@set:` switches stay reachable (`-Wl,-exported_symbol,'_g_*'` verified with `t_ub`);
  - an `@interface` goes into a guarded header (`#pragma once`), its `@implementation` into one `.m` (`nvn_rec.h`'s three `@implementation`s move into a `.m`); an `@autoreleasepool` moves with its function; `S`, `R` and `g_pass` get named typedefs; headers `hle_nvn.c` includes stay C (or `#ifdef __OBJC__`);
  - the hand-numbered `RED_ONCE` keys (1708) get a uniqueness check once they are spread over the modules.
- **Hot path: data-oriented.** Plain C structs in arrays. Facts computed once, when an object is created. No dynamic dispatch, and no ObjC message or ARC traffic per draw beyond the Metal calls themselves.
- **Dependency inversion through a command sink** (stage SK): the translator writes to a sink instead of to Metal directly. Three sinks: Metal; the encode-thread recorder (`nvn_rec.h`); a test recorder that names objects by creation order and digests the stream. The sink is chosen at build time or once per submission, never per call. S5's asynchronous boundary is this sink.
- **Liskov**: every sink keeps the Metal semantics the translator relies on: a distinct object per encoder (`g_enc != en`, `nvn_mtl.m` ~10616), call order, and the lifetime of the objects passed. The test sink is checked against the Metal sink on the corpus.
- **Diagnostics behind one hook layer** (capture, passdump, `DM_NVN_CPUPROF`, GPU profile): each hook site tests one hidden-extern flag before the call through the hook table, so the off path is a predictable branch, not an indirect call.
- **Open / closed**: per-game behaviour stays in the profiles (`game.tsv`, `patches.py`). The hot path extends through tables and `switch`, not callbacks.
- **Readable functions**: the functions that straddle concerns (`draw_`, `encode_args_`, `rp_begin_ex_`, `mtl_exec`) are divided along the module seams in I, each part in the module that owns its data; the other long ones in CL.

## Modules

From `reports/20261104-1415-module-map.md` (made from the AST at BASE and the source at HEAD; per module there: functions and ranges, globals, public functions, dependencies, tests), with the plan review's merge of sink and copy (`reports/20261104-1433-plan-review.md`, finding 11). `nvn_mtl.m` and the four files it includes (14,904 lines in the table, 1,107 functions) become 32 modules, `dm/gfx/nvn/mtl_<name>.m` / `.h`. The number is the extraction order: each module calls only modules with a smaller number (after the cuts below and the merge, 1,332 call edges and 1,235 data edges, all pointing down; the map's pipeline re-run with the merge gives no upward call or data edge as modeled, and 11 upward hook calls, which go through the hook table). The map was made at BASE `b0d98ee7`, and the line numbers in this plan are at `32913850`: both are before U. The pipeline is kept in `/Volumes/Hangar/Games/overnight/mm/`.

| # | Module | Lines | Concern |
|---|---|---|---|
| 1 | prof | 294 | diagnostic plumbing every module may call: CPU profile, wait and boot stats, A/B phases, GPU frame tags, `passdump`, the hook table |
| 2 | dev | 93 | Metal device and queues, residency, host libraries, hot switches |
| 3 | texfmt | 246 | stateless texture-format helpers |
| 4 | rec | 358 | the encode-thread recorder and the uniform-copy thread (`nvn_rec.h` becomes `mtl_rec.m` + `.h`) |
| 5 | fence | 257 | fences, completion, waits, deferred release, post-ops, queries and conditional rendering, the submission serial |
| 6 | parch | 340 | the Metal 4 compiler, binary archives, library files |
| 7 | mem | 165 | memory pools, guest-to-Metal addresses, per-submission arenas |
| 8 | serial | 83 | object-id maps and the serial table, aliases, ghosts |
| 9 | shader | 481 | the shader map, function loading and specialisation, programs, builtins |
| 10 | state | 276 | the draw state `S`, the pass state `R`, `g_pass` (named typedefs), save / restore, the replay cursor |
| 11 | hazard | 393 | write tracking (pending writes, epochs), uniform patch lookups, GPU-written memory |
| 12 | sink | 367 | the open command buffer and encoders, the `enc_*` wrappers, argument-table filters, the copy and compute encoder (`g_blit`, 26 end sites), buffer copy / fill / update, deferred inline updates: the seam of stage SK |
| 13 | upload | 478 | the upload batch, zero and initial fills, old-queue synchronisation |
| 14 | sparse | 506 | sparse textures and tiles |
| 15 | vin | 517 | vertex input: buffers, formats, conversions, pull layouts |
| 16 | tex | 519 | host textures for guest textures: creation, upgrade, packages, CPU-written and linear textures, mirror readbacks |
| 17 | pso | 769 | pipeline keys, descriptors, builds, pending builds, hybrids, depth-stencil states, the compute pipeline cache |
| 18 | treg | 521 | the descriptor registry (textures, images, samplers), views, texel buffers, finalisation |
| 19 | tbdr | 405 | tile-memory optimisations: store lookahead, attachment ledger, zero-source skip |
| 20 | pass | 780 | render passes and their encoder state machine, segments, allocators |
| 21 | present | 972 | present queue, display link and pacing, MetalFX, snapshots, streaming |
| 22 | ixconv | 248 | index, indirect and multi-draw conversions |
| 23 | args | 699 | argument encoding (`encode_args_`) |
| 24 | xfer | 726 | copies, clears, lazy clears, texel readbacks, DLSS |
| 25 | warm | 615 | prepare, shader and pipeline prewarm, prebuild, predicted pipelines |
| 26 | dump | 742 | pass dumps and reports behind the hook table |
| 27 | rewrite | 760 | replay rewrites: deferred draws, pass fusion, hoists, load elision |
| 28 | capture | 509 | frame capture (`nvn_capture.inc` becomes `mtl_capture.m`) |
| 29 | geo | 949 | geometry emulation, mesh draws, transform feedback (`nvn_geometry.inc` becomes `mtl_geo.m`) |
| 30 | draw | 494 | the draw and dispatch ops (`draw_`, `dispatch`, `image_prepare`) |
| 31 | exec | 248 | one submission: `mtl_sub_begin`, the op loop `mtl_exec`, `mtl_sub_commit`, and one `mtl_submit` that `hle_nvn.c` and `nvn_replay` both call |
| 32 | facade | 94 | what stays in `nvn_mtl.m`: `mtl_init` as the composition root, a few public wrappers |

Changes against the map's table, checked on its matrix:
- sink and copy are one module after hazard, since the copy encoder is the seam SK replaces; upload moves after it (it calls sink three times and nothing between hazard and itself), and shader, state and hazard call neither;
- texfmt reads prof's and dev's globals, so it follows both; only 1-2, 14-15 and 22-25 may swap among themselves;
- the merge removes the map's `copy_compute_begin` cut;
- the lazy switches dev holds only for the layering (`tbdr_on`, `rt_range_on`, …) may become a `cfg` module at the bottom; M0 regenerates the map on the post-U tree with these changes and fixes the table;
- exec and facade may merge.

Why the 16-module draft did not hold: a single diagnostics module cannot sit at the bottom (dumps end passes and read textures), submission's begin and commit call nearly every layer, the registry needs the serial table below textures, and `S` / `R` are read by 13 modules and written by 11 (module map, section 1).

Cuts before the moves (each its own commit inside `nvn_mtl.m`, right before the first module that needs it): today 27 modules form one call cycle (17 upward pairs, 31 calls). Cut 1 (19 rows) moves well over 100 functions to the module that owns their data (27 format helpers, 15 serial functions, 15 prebuild functions, the copy encoder, the mirror readback, …); cut 2 sends 11 hook sites through the const hook table defined in dump, and the 6 former init-filled slots become link-time `const` tables (above); cut 3 replaces 6 upward data accesses: the map's three (a merge flag, a `busy` parameter for `sub_cut`, a log formatter; `g_fz.active` is written only at 9101, 9471 and 9472) and three its pipeline dropped because their source is dump, capture or facade (`shot` writes and reads rewrite's `g_defer_ab_on` / `g_defer_ab`, 12003, declared 8304; `mtl_mem_stat` reads exec's `g_ap_bytes`, 3423, written in `mtl_exec` 11731). About 30 cut commits in all.

End state of the other files:
- `nvn_mtl.h` becomes the single C header of the API for `hle_nvn.c` and the other host files; it takes the 46 `mtl_*` prototypes out of `nvn_obj.h` and declares the 26 that no header declares today. No module header is included by `hle_nvn.c`.
- `hle_nvn.c` (2,926 lines) is not above the modules today: `nvn_mtl.m` calls up into it through local prototypes (`nvn_sparse_alias` 1083, `nvn_host_readable` 1282 and 2320, `nvn_sparse_*` 2321-2322 and 2706-2708, `nvn_flushed` 2564, `nvn_dpool_base` 8431, `nvn_ft_written` 10972). Stage N gives those services one header owned by `hle_nvn.c` (or moves them down) and splits the file by concern.

The three hard problems, and how the plan meets them:
1. **`S`, `R` and `g_pass`**: shared by most modules, copied whole at 7 sites (`nvn-state.md`, constraints 1-8). Step 10 gives them named typedefs, `state_save` / `state_restore`, and one mutable header; stage I narrows who includes it (target there).
2. **The encoder state machine**: `rp_end`'s 12-step order, `blit_raw` → `rp_end` → `ubd_flush`, and 26 copy-encoder end sites. The pass-end `const` table and a merge table keep the order; the review of step 20 checks `rp_end` line by line.
3. **Calls back into draw**: rewrite and geo re-enter `draw` / `dispatch`, under locks held by lower modules, and `draw_` reaches 17 modules. D6 decides the mechanism and writes the contract down.

## Oracles

- **Command-stream digest** (S3a, `nvn_replay --digest`): the Metal command stream of a replay, objects named by first appearance in the frame, hashed. Identical across `--repeat` on every capture. It judges every pure move (M): the digest must not change. A step meant to change commands changes it, and the diff is read: `--digest-dump` from the previous step and from HEAD, through a differ that normalizes arena offsets.
  - What it does not hash (S3a as built): texture and sampler bindings (spec `'i'` hashes a constant), buffer contents (`'a'` hashes a buffer and offset, never the bytes: argument blocks, uniform shadows, `c0` rows, index and indirect data), pipeline and depth-stencil contents (only the label, and only `PSO_WHOLE` pipelines are labelled, 6311), sampler states, CPU uploads and `replaceRegion`, residency changes (`res_add_at`, `res_remove`), post-op writes into guest memory (`post_run`, 1566); addresses outside a resident buffer hash as `?`.
  - It sees only the recorder path: `--digest` forces the recorder, which on the Mac only DK runs, so the direct branches (991, 998, 1014, 11561, 12956) are checked by pixels only on Pokopia and by boots only on MKW.
  - Under `--digest` the translator's `dispatch_async` blocks run inline: the digest is that of a translation whose background pipeline builds take no time; timing-dependent paths (a draw waiting on a background pipeline) are judged by the plain replays and the boots.
  - S3b closes the first list before I: resource IDs named through a reverse map (filled where the host takes an ID, `tex_rid_` 5296 and sampler creation), each pipeline's key or descriptor hashed at creation (`pso_key_fill`, `pso_desc`), argument-block bytes hashed at commit with in-buffer addresses and resource IDs replaced by names, sampler states, uploads, residency and post-ops recorded.
- **Pixel replay**: `nvn_replay`, within each capture's noise (`agents/refactor/captures.md`). It is the only check of the direct path until SK.
- **Deterministic instruction count** (new in M0): replay-thread instructions with `DM_NVN_UB_COPY_THREAD=0` (no `ubc_wait` spin, `nvn_rec.h` 40-48), background work inline (the `--digest` dispatch switch) and a fixed `DM_NVN_ENC_THREAD`. Baselines at the start of M0 (the unity replayer, with the count mode added first) and at its end, so M0's own change is measured; reported per step and in total, a gate for none.
- **Call check** (new in M0): per step, the `bl` targets inside `draw_`, `encode_args_`, `rp_begin_ex_`, `rp_end` and the functions that inline `tex_fast*` (`always_inline`, so they have no symbol of their own), in `draw` if ThinLTO inlines `draw_` into it, with `.llvm.*` suffixes stripped (`otool -tvV` of the host), against the previous step, with the allowlist from map section 6 and D8. Any other new call is fixed before the next step.
- **Move check** (new in M0): the multiset of lines removed from the source files (`nvn_mtl.m`, `nvn_rec.h`, the `.inc` files) equals the lines added to the module, apart from the declared edits: linkage in a move commit; in a cut commit that edits code (hook guards, `const` tables, `sub_cut`'s `busy`, the `PD` formatter), the edits its message lists.
- **Replay CPU**: the method in `commands.md` (median submit instructions of replays 6-15 of `--warm 15`). From M0 on the replayer links module objects; comparisons use the replayer of M0's end, never the unity binary of `base-b0d98ee7`. Reported, a gate for none.
- **Boots** through the guard: the three games (D10); MKW only by boots (its sparse virtual pools cannot be captured).
- **iOS link**: an unsigned Release link of the iOS project (no signing, no install), and a sideloadable IPA for the user at the end of each stage.
- **Structure**, per step: the lines left in `nvn_mtl.m`, each module's size, the dependency check, the cross-module globals still named; at the end of I none. At the end of CL, over the `mtl_*` files and `nvn_mtl.m`: functions over 100 lines and lines over 200 characters, both 0; `hle_nvn.c`'s are N's.
- **What the replay does not see**:
  - the present path (`mtl_present`, `present_snap`, present-time MetalFX): the replayer digests the presented texture after `mtl_sub_commit`;
  - `nvnQueueSubmitCommands` itself, until M0's `mtl_submit` makes the replayer call the same sequence as `hle_nvn.c` (1286-1291 today, `nvn_replay.m` 383-385);
  - GPU writes that never reach the present (queries, events, counters, next-frame state);
  - mesh draws on a fresh process: mesh pipelines build in the background, so use `--warm 3`;
  - MKW;
  - PSO stand-ins: captures run with `DM_PSO_HYBRID=0`;
  - the digest's blind spots above.

  Boots cover these. From S5 on, a replay through the real submit entry covers the submit path too.

## Stages

In order. Old S3b (one context struct) is replaced by M + I; old S6 (modules at the end) is M. HT runs in parallel.

Check tiers in M (D10):
- **each commit** (cut or move): the three hosts and two replayers build with no new warnings, the digest on every capture, the deterministic count, the call check, the move check, and the tests that name the moved module (the map's Tests column);
- **each module step** (its cuts plus its move): also the pixel corpus, the three boots, and the doc lines that name the moved code rewritten to name functions (`nvn_mtl.m` is named 78 times in `docs/reference`: `rendering.md` 43, `shaders.md` 15, `nvn-objects.md` 12, `frame-rate.md` 6, `packing.md` 1, `memory.md` 1; 8 times in `docs/agents`, 7 in `docs/development.md`); an independent review of the non-moved lines (`git diff --color-moved=dimmed-zebra`);
- **every third module step**: also both full gfx suites and the iOS link.

`agents/architecture` is pinned to its commit and a verbatim move changes no fact in it: it is rewritten once, after I.

| # | Stage | Acceptance criterion | Status |
|---|---|---|---|
| S0 | Safety net | ≥ 5 kept captures each for Pokopia and DK, each replaying on base within its noise; base replay CPU per capture; white-box tests inventoried. | done 2026-11-04 07:10: Pokopia 7, DK 6 (`captures.md`); U recaptures what no longer replays |
| S1 | Build flags | `-O2` + ThinLTO for the host and both test trees; `noinline` on every reader of `__builtin_return_address` / `__builtin_frame_address`; the three games build; tests and one sanitizer pass; corpus green; boots as base. | done: `0eec4184` |
| S2 | Local fixes, low risk | Per item: covering tests, corpus within noise, independent review, one commit. Next, as they reach shipping builds: F1, `fz_p2_draw` calls `tex_fast_rid` without `g_rmu` (9602) while `mtl_reg_tex` may `realloc` `g_treg` under it (5006), and the view it returns is unretained: a use-after-free window on the submit thread; F2, `fb_prepare`'s stale serial: compare `g_treg[tid].t.serial == ser` inside the 9859 lock. Each with its test and a `docs/reference` entry. C9 and C10 (fewer bumps of the global generations `g_reg_gen` / `g_ser_gen`; they change commands) go here as their own items, not inside I. | C7, P2, C1, C3, C6 committed; F1, F2, C9, C10 next; the rest is a backlog (the user, 11:40) |
| S2b | Local fixes, medium risk | Each item keeps the caveats in `catalog.md`. | backlog (the user, 11:40) |
| S3a | Command-stream digest | The test sink plus `nvn_replay --digest`; the digest is identical across `--repeat` on every capture; a capture whose digest varies is listed with its cause, never dropped silently. The code is committed before U; the criterion is checked again on U's recaptured corpus, and the baseline digests are taken there. | implemented (`reports/20261104-1445-S3a-impl.md`): one digest in 8 of 8 fresh replays on all 13 captures, after `--digest` runs the translator's background builds inline (dk_ypunch's pass count followed when `sm_amp_get`'s background pipeline landed); pixels within noise through the recorder and the Metal sink; host `__text` byte-identical; replay CPU unchanged within noise; baselines at `a8114711`; review running |
| U | Upstream sync (D7) | Before it: S3a's code and H5 committed and HT paused; the user settles the uncommitted `docs/env_switches.tsv` (14 upstream commits touch it); `rules.md` gets the user's exception for U's commits on `main` (today: work only on `refactor`, no other checkout). Then `git fetch upstream`, `git branch -f nxnative upstream/main`, and what reaches the three games cherry-picked onto `main` (`CLAUDE.md`, "Branches"), MKW as D7 decides; shaders rebuilt per game (`dmsh_build.py`), hosts rebuilt; the three games boot on `main`; `main` merged into `refactor`; S0's corpus recaptured where the old captures no longer replay, base replay CPU and S3a's baselines taken on the result. From then on `nvn_mtl.m` is frozen on `main` until M ends. | pending: after S3a's and H5's commits; the commit survey runs first |
| S3b | Digest coverage | DK's pixel nondeterminism root-caused (night file, Open 07:10: the upgrade of ser 4624 at pass 94; the live game crosses frames the same way): S3a shows the command digest identical while the pixels vary, so the cause lies outside what it hashes. The digest names resource IDs, hashes pipeline keys or descriptors, argument-block bytes (addresses and IDs by name), sampler states, uploads, residency changes and post-ops; `--digest-dump` plus the offset-normalizing differ; still identical across `--repeat`; a deliberately wrong binding, argument byte and pipeline key each change it (tests). | pending; before I at the latest |
| M0 | Split mechanics | (1) `nvn_replay`, `t_capture_live` and `t_rec_digest` link module objects built with the host's flags: their 22 `nvn_mtl.m` internals become real APIs, and the `hle_nvn.c` statics the replayer uses (`pk_get` 638, `g_tpb` / `g_spb` / `g_ntpb` / `g_nspb` and `struct dpool_base` 278, `thr_instr` 1239) become APIs too, or `hle_nvn.c` stays in the replayer's own translation unit; `NVN_REC_TAP` and the inline `dispatch_async` of `--digest` become runtime switches of the recorder; one `mtl_submit` used by `hle_nvn.c` and the replayer; (2) the unity `nvn_mtl_all.inc` and a `MTL_MODS` list in `dm/gfx/tests/Makefile` (12 places), the other 72 white-box tests including the unity; `t_gfx_suspend` and `t_nvn` link (lines 50-53 lack `t_host_stubs.c`); the tests' non-included sources built once per game as native `-O2` objects; (3) the seven files keyed to the name `nvn_mtl.m` follow (`lint_c_baseline.tsv`, `impact_map.tsv`, `test_dmsh_abi.py`, doc links); (4) the dependency check in `dm/tools/tests`, with `hle_nvn.c` as a node and local prototypes refused, the up-calls of `nvn_mtl.m` into `hle_nvn.c` declared in a header `hle_nvn.c` owns; (5) the host Makefile builds one object per file with dependency files (`-MMD -MP`, `make -j`) under `gen/<id>/obj/` (`game_profile.h` feeds `DM_GAME_ENC_THREAD` and `DM_GAME_RENDER_COND` into the translator, so objects of one game must never serve another), `DM_HOST_REV` through a generated header rewritten only when it changes (`stream_mac.m` 145); `dm/ios/tools/gen_build.py` and `compile_check.py` adapted, with the same stdout and `Gen/src` listing before and after up to order; (6) first the deterministic count and its start baseline, then the move tool, the move check and the call check; (7) the module map regenerated on the post-U tree (AST, `headfuncs`, `rep.py`) with the module table's changes, and its pipeline turned into the move tool's input under `dm/tools`; (8) `commands.md` updated (MKW boots outside HT, the tiers). The three games build; both suites pass with no exclusion; the iOS Release links unsigned; digest identical on every capture; pixel corpus within noise; the three games boot as before. | pending |
| M | Modules | One module step per module, in the order of the module table, leaves first: its cuts, then a verbatim move (code and comments) by the move tool, the module's header, its callers switched to it, the module added to the unity file in its original place; globals that other modules still touch are declared in its header (hidden `extern`) until stage I. Checks by tier (above). Per-draw switches with lazy caches (`tbdr_on`, `rt_range_on`, `sm_on`, …) stay out of line as they are: resolving them at init moves `getenv` and their `MLOG` lines, a behaviour change left to I. Ends when `nvn_mtl.m` is the 94-line facade. | pending |
| I | Interfaces and ownership | Per module: no `.m` names another module's global; only the owner's header inlines do; the dependency check enforces it. The straddling functions (`draw_`, `encode_args_`, `rp_begin_ex_`, `mtl_exec`) divided along the seams, each part in its owner; the D8 callees kept beside their callers move to their owners. `S` / `R` / `g_pass`: at the end only rewrite, geo, warm, draw and args include the mutable state header; every other write (today pass, xfer, dump, tbdr, hazard write `S`; xfer, pass, tbdr write `R`) becomes a named state function, as `dss_get`'s parameter replaces the write to `S.ds.df`. Lock rules of the design principles hold, and the `locks.md` nesting analysis is re-run. Lazy switches resolved once at init (into a `cfg` module), each with its `MLOG` line kept. Per-object generations replace `g_reg_gen` / `g_ser_gen` where a module owns the objects, as their own catalog items with their digest diffs read. The `DM_NVN_FUSE_CHECK` re-entry under `g_rmu` (night file, Open 05:00) fixed with its test; its `docs/reference` entry is written in S2. The fan-out targets for draw, exec, geo, xfer and pass, set at the end of M from the post-M map, met. `agents/architecture` rewritten for the new layout; a module guide in `docs/reference` (or `docs/agents/04-graphics.md`) and a "Where to start" row in `CLAUDE.md`, within `test_docs.py`'s word limits (the row replaces text there, or links out). Digest identical except where a step changes commands (diff read); corpus green; boots clean. | pending (needs S3b) |
| N | `hle_nvn.c` | The services the modules call (virtual and sparse pools, descriptor pools, CPU-written spans) in one header owned by `hle_nvn.c`, or moved down into the module that owns their data; `hle_nvn.c` split by concern (API entry points, pools, queues and submission, windows), each part a node in the dependency check; no function over 100 lines and no line over 200 characters. Digest identical; corpus green; three boots. | pending; after I, may overlap T |
| T | Tests leave the unity (D4) | Every white-box test includes only the module(s) whose statics it reaches (or checks the stream through S3a's recorder digest, or uses `NVN_TESTABLE`, as D4 says); no test includes `nvn_mtl_all.inc`, and the file is deleted. Order of the mechanics report 2.4: the 17 tests with ≤ 8 internals, then the 9-25 bands by owner module, then the interposing tests after their seams exist, last `t_geometry` and its includers, `t_perf_order`, `t_pso_archive`, `t_pso_warm`, `t_pso_depth_stencil`, `t_arena_args`, `t_image_attachment_store`. Both suites pass. | pending; after I |
| CL | Cleanup (D9) | Per module, under D9's rules: lines over 200 characters wrapped; comments citing line numbers name functions; functions of 100 lines or more divided (`geo_prep` 165, `tex_mtl_` 136, `present_now` 122, `fuse_try` 117, `copy_t2t` 114, `pso_desc` 103, `pkg_upload_` 100, and those I leaves). Structure oracle: both counts 0. Digest identical; call check clean. | pending; after I |
| SK | Command sink | The translator writes through the sink; Metal, recorder and test sinks. Before the recorder tap goes, the tap's digest equals the test sink's on every capture. The test sink checked against the Metal sink on the corpus; the direct path (Pokopia, MKW) gets digests from here on; the stream-oracle tests move from the recorder digest to the test sink. Digest identical. Recorder costs weigh more than on the Mac: iOS runs the recorder for every game. | pending |
| S4 | Data model | Written first: S5's threading design (where translation runs, what it reads). Then compiled-program metadata, a registry view for wherever S5 translates (it cannot be a read-only copy, because `tex_by_id` writes view caches into `g_treg`), hot objects as C structs. Digest identical; corpus green. Replay CPU reported against SK. | pending |
| S5 | Asynchronous submission | The game thread only enqueues; translation and encoding run on their own threads. The test-first list is below the table. A replay through the real submit entry; its digest equal between asynchronous and synchronous submission; a stress replay that rewrites guest memory after each submit returns; a TSan run of the host tests. Corpus green, boots clean, DK's `pcore` reported against S4. | pending |
| HT | Host threads (parallel track) | H2, H3 and H5 of the catalog, then `SetThreadActivity`'s use after free (`hle_thread.c`, the file HT owns). `make -C dm/host/tests GAME=<id> run preempt` pass; boots clean. | H2 committed `f243f605`; H3 committed `32913850`; H5 pending (implementing); `SetThreadActivity` pending |
| X | The rest of the repository | After the graphics core: a survey of the other large files (`hle_cheats.c` 2,103 lines, `hle_gl.m` 2,069, `hle_vk.m` 1,554, `front_mac.m` 1,407, `hle_thread.c` 1,295) and of the host's open bugs, then a plan of its own. | pending |

S5 tests, written before its code:
- queue order;
- `nvnQueueFinish`, syncs, queries and fences;
- two-queue ordering under `g_sub_mu` (`hle_nvn.c` 1271-1300);
- guest memory read after the submit returns: uniform shadows, vertex CPU copies, dirty-tracked uploads, `bh_fresh`, indirect counts (around `nvn_mtl.m` 10116), geometry arguments;
- objects finalized while a queued submission still uses them: `serial_del` at `g_fence + 1`, `vpool_drop` unmapping;
- the present invariant that a submission publishes its records before it returns (`nvn_rec.h` 227-229, `nvn_mtl.m` ~12867);
- capture inside the submit.

## Root causes

| Cause | Catalog items | Fixed by |
|---|---|---|
| One translation unit with 1,064 shared file-scope names: no boundaries, no owners, tests pinned to internals | — | M, I, T |
| `nvn_mtl.m` calls up into `hle_nvn.c` through local prototypes | — | M0 (header), N |
| The translator writes to Metal directly: no test without a GPU, no move off the game's thread | — | SK |
| The host has been built at `-O1` without LTO since the first commit (`dm/host/Makefile:18`, `d1b17080`); iOS Release is still `-Os` without LTO | B1 | S1 (done, Mac); D5 (iOS) |
| Program-static facts are recomputed on every draw: no compiled-program object holds them | C2 | S4 |
| The texture registry is shared state under `g_rmu`, locked per binding and per lookup, and read without it in one place | C3, C4, C8, F1 | S2 (C3 done, F1 next), I, S4 |
| Invalidation is global (`g_reg_gen`, `g_ser_gen`) | C9, C10 | S2 (C9, C10), I (per-object generations) |
| Program binds dirty every stage's arguments (`args_dirty_all`) | C13 | I |
| Per-draw ARC traffic on ObjC objects | C1, C6 | S2: C1 converted `encode_args_`'s allocations (25 other callers remain), C6 has 8 sites left |
| Translation is synchronous on the game's thread (`nvnQueueSubmitCommands`, under `g_sub_mu`) | — | S5 |
| Recorder costs of the encode thread (on the Mac only DK pays them; on iOS every game) | E1-E4 | SK |
| Guest-thread waits sat in one global list; condition signals were sent under `G` | H2, H3 | HT (done) |
