# Plan

## Goal

Lower the host's CPU time per frame on the fanless MacBook Air M4 (Pokopia, DK Bananza, Mario Kart World). Do it by restructuring the NVN → Metal layer (`dm/gfx/nvn`, `nvn_rec.h`) and the hot parts of the host, with the picture and the game-visible behaviour unchanged.

CPU matters on the hot Air for three reasons:
- the submit thread runs at about half clock: submit CPU is 5.0-7.5 ms a frame in Pokopia's hot windows, against 1.85-2.0 ms nominal;
- Pokopia's hot frames sit 2.0-2.6 ms above their GPU time;
- DK's frame-rate controller counts translation time: 5-9 ms on the M4 Pro, 10-15 ms estimated on the hot Air.

Measured background: `PERF_M4.md`, `/Volumes/Hangar/Games/Pokopia_v2.0.1a/0400A3A01EE4C000-work/host-opt/round2/cpu.md`.

Method:
- A capture/replay safety net comes first.
- Then stages, each keeping the replay corpus green and each delivering a measured gain.
- Every new component is written test-first. Everything moved or rewritten gets characterization (golden-master) tests.
- Several subagents throughout, for other points of view, code reviews and searches (the user, 2026-11-04).

## Decisions (the user's)

| # | Decision | Recommendation | State |
|---|---|---|---|
| D1 | Diverge from upstream (`seedds/nxnative`) in `dm/gfx/nvn` | Diverge from S3 on; S0-S2b stay cherry-pick friendly (small, local diffs) | decided 2026-11-04: diverge from S3 on |
| D2 | Scope: `dm/gfx/nvn` + `nvn_rec.h` only, or the whole host | `dm/gfx/nvn` + `nvn_rec.h`, plus the host-thread track HT; services and SVCs only where a finding shows a cost | decided 2026-11-04: `dm/gfx/nvn` + `nvn_rec.h` + HT |

## Design principles

- **Hot path: data-oriented.** Plain C structs in arrays. Facts computed once, when an object is created. No dynamic dispatch, and no ObjC message or ARC traffic per draw beyond the Metal calls themselves.
- **Boundaries: the SOLID principles that pay here**, each tied to a stage.
  - **Single responsibility** (S6, with the seams cut in S3-S5): one module per concern (memory / residency, programs / pipelines, arguments, passes, submission, present). Diagnostics (passdump, `DM_NVN_CPUPROF`, GPU profile, capture) go behind one hook layer that costs a predictable branch when off, instead of sitting inline in hot functions.
  - **Interface segregation** (S6, started as each module appears): one small header per module. Tests and `nvn_replay` include headers, never a `.m` file.
  - **Dependency inversion** (S3, S5): the translator writes to a command sink instead of to Metal directly. There are three sinks:
    - Metal;
    - the encode-thread recorder (`nvn_rec.h`);
    - a test recorder that names objects by creation order and digests the stream.

    The sink is chosen at build time or once per submission, never per call. S5's async boundary is this sink.
  - **Liskov** (S3, S5): every sink keeps the Metal semantics the translator relies on: a distinct object per encoder (`g_enc != en`, `nvn_mtl.m` ~10616), call order, and the lifetime of the objects passed. The test sink is checked against the Metal sink on the corpus.
  - **Open / closed**: per-game behaviour stays in the profiles (`game.tsv`, `patches.py`). The hot path extends through tables and `switch`, not callbacks.

## Oracles

- **Pixel replay**: `nvn_replay`, within each capture's noise. It judges every change.
- **Command-stream digest**: from S3 on, through the test sink. It judges pure refactors: S3 and S6 must leave it identical. An optimization changes it, and its diff gets read.
- **Replay CPU**: instructions retired per replayed frame. Take `/usr/bin/time -l` of `nvn_replay <cap> --warm 9`, subtract `--warm 1`, divide by 8. It is deterministic and needs no boot, so it is the CPU metric of the translation layer.
- **What the replay does not see**:
  - the present path (`mtl_present`, `present_snap`, present-time MetalFX): the replayer digests the presented texture after `mtl_sub_commit`;
  - `nvnQueueSubmitCommands` itself: the replayer calls `mtl_sub_begin` / `mtl_exec` / `mtl_sub_commit` directly;
  - GPU writes that never reach the present (queries, events, counters, next-frame state);
  - mesh draws on a fresh process: mesh pipelines build in the background, so use `--warm 3`;
  - MKW: its sparse virtual pools cannot be captured (`nvn_capture.inc` ~122);
  - PSO stand-ins: captures run with `DM_PSO_HYBRID=0`.

  Boots through the guard cover these. From S5 on, a replay through the real submit entry covers the submit path too.

## Stages

| # | Stage | Acceptance criterion | Status |
|---|---|---|---|
| S0 | Safety net | ≥ 5 kept captures each for Pokopia and DK, from direct `DM_NVN_CAPTURE` boots, one frame per boot (no game has the `dm/games/<id>/smoke.tsv` route that `regress.py capture` needs). Each replays on base within its noise (`nvn_replay --repeat 8`; mesh frames also `--warm 3`). Base replay CPU recorded per capture. White-box tests inventoried: what each one pins. | pending |
| S1 | Build flags | `-O2` + ThinLTO for the host, `dm/gfx/tests` and `dm/host/tests`. Every function that reads `__builtin_return_address` or `__builtin_frame_address` (`rg -n '__builtin_(return|frame)_address' dm`; at BASE in `hle.h`, `hle_audio.c`, `hle_sdk16.c`, `thread.c`, `hle_nvn.c` and `t_bigstack.c`), directly or through a macro, marked `noinline`. The three games build. Pokopia's and DK's gfx tests pass, and `dm/host/tests` `run` and `preempt` pass. One sanitizer pass recorded (`make -C dm/host/tests GAME=<id> asan`). Corpus green. Each game's boot shows the same screens as base. Replay CPU lower than base. iOS build (Xcode Release, `-Os`) untouched. | pending |
| S2 | Local fixes, low risk | Per item: covering tests, corpus within noise, independent review, one commit. Replay CPU not higher per item, and lower overall. | pending |
| S2b | Local fixes, medium risk (the catalog items with Stage S2b) | Each item keeps the caveats in `catalog.md`. Same checks as S2, plus a boot check for items the corpus cannot see (C11: PSO stand-ins; E1-E4: the encode thread, DK). The user asked on 2026-11-04 for the night to go as far as it can, so S2b does not wait for a review of S2. | pending |
| S3 | Translator context and command sink | (2026-11-04 11:45, the user: S3 starts without S2 / S2b settled; their remaining items are a backlog.) Built in steps. **S3a**: the test sink plus `nvn_replay --digest` (the Metal command stream recorded through the `nvn_rec.h` recorder, objects named by creation order, hashed); the digest is identical across `--repeat` on every capture; baseline digests recorded at the S3 start commit. **S3b and later**: the translation state (`S`, `R`, `g_enc`, `g_cb`, argument tables, static caches, generation counters) moved into one context struct, one group of globals per commit, in the order of `agents/architecture/nvn-state.md`, with the digest identical after each step. Then the translator writes through the sink. Corpus green; white-box tests still compile. | pending |
| S4 | Data model | Compiled-program metadata. A registry view designed for wherever S5 translates; it cannot be a read-only copy, because `tex_by_id` writes view caches into `g_treg`. Per-object generations. Hot objects as C structs. Corpus green. Replay CPU lower than S3. | pending |
| S5 | Asynchronous submission | The game thread only enqueues; translation and encoding run on their own threads. The test-first list is below the table. A replay through the real submit entry. Corpus green, boots clean, and DK holds interval 1 at a lower `pcore` than S4. | pending |
| S6 | Modules | `nvn_mtl.m` split along the S3-S5 seams, one header each. `nvn_replay` and the tests build against those headers; the white-box tests are ported here, not dropped earlier. Digest identical. Replay CPU not above S5's. | pending |
| HT | Host threads (parallel track; not the catalog item H1, which is in S2) | H2, H3 and H5 of the catalog. `make -C dm/host/tests GAME=<id> run` (`t_condvar`, `t_condvar_old`, `t_pollwait`, `t_system_event`, `t_thread_leak`) and `preempt` pass. Boots clean. | pending |

S5 tests, written before its code:
- queue order;
- `nvnQueueFinish`, syncs, queries and fences;
- two-queue ordering under `g_sub_mu` (`hle_nvn.c` 1271-1300);
- guest memory read after the submit returns: uniform shadows, vertex CPU copies, dirty-tracked uploads, `bh_fresh`, indirect counts (around `nvn_mtl.m` 10116), geometry arguments;
- objects finalized while a queued submission still uses them: `serial_del` at `g_fence + 1`, `vpool_drop` unmapping;
- the present invariant that a submission publishes its records before it returns (`nvn_rec.h` 227-229, `nvn_mtl.m` ~12867);
- capture inside the submit.

White-box coupling: 73 of the 106 sources in `dm/gfx/tests` `#include "../nvn/nvn_mtl.m"`, `nvn_replay.m` among them. They keep compiling through S5 and are ported to module headers in S6.

## Root causes

| Cause | Catalog items | Fixed by |
|---|---|---|
| The host has been built at `-O1` without LTO since the first commit (`dm/host/Makefile:18`, `d1b17080`): no vectorization, no cross-file inlining | B1 | S1 |
| Program-static facts are recomputed on every draw: no compiled-program object holds them. Each stage needs several masks, because the scans test different things | C2 | S4 |
| The texture registry is shared state under `g_rmu`, locked per binding and per lookup | C3, C4, C8 | S2 (local), S4 |
| Invalidation is global (`g_reg_gen`, `g_ser_gen`): local cases | C9, C10 | S2 |
| Program binds dirty every stage's arguments (`args_dirty_all`) | C13 | S2b |
| Per-draw ARC traffic on ObjC objects | C1, C6 | S2 |
| Translation is synchronous on the game's thread (`nvnQueueSubmitCommands`, under `g_sub_mu`) | — | S5 |
| Recorder costs of the encode thread. On the Mac only DK pays them (`game.tsv` `enc_thread on`); S5 does not remove them | E1-E4 | S2 / S2b |
| Guest-thread waits sit in one global list | H2 | HT |
