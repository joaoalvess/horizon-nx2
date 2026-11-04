# Split mechanics for `nvn_mtl.m`: builds, white-box tests, inlining, ARC, symbols

Read-only analysis for S6. Tree: `refactor` at `f318380d`. `8a51577a`, committed during the run, touches only `agents/refactor/*.md`. The working tree holds S3a's uncommitted sink: `nvn_rec.h` `NVN_REC_TAP`, `nvn_replay.m --digest`, `dm/gfx/tests/nvn_rec_digest.inc`, the untracked `t_rec_digest.m`. Nothing in the repository was built, run or edited.

Probes: `/private/tmp/claude-501/-Users-joaoalves-Developer-switch/fd5fcbce-ad70-4407-952b-560d6e7b6b20/scratchpad/split-probe/` (`p1` to `p8`, plus `classify.py`, `cat.json`, `per_test.json`). Toolchain: Apple clang 21.0.0 (clang-2100.4.1.1), ld-27106.1, Xcode 27.2 (27B52), on the 10-core M4 Air. The declaration inventory comes from one `clang -fsyntax-only -Xclang -ast-dump` of `nvn_mtl.m` at HEAD, using the compile line from `dm/host/gen/compile_commands.json` (the line in `split-probe/toplevel.py`).

## In brief

1. **Builds.** The Mac host and iOS pick up a new `dm/gfx/nvn/*.m` or `*.h` with no edit (wildcards; iOS reads `make -n -B dmhost`). `dm/gfx/tests/Makefile` needs a module list in 12 places. Seven other files are keyed to the name `nvn_mtl.m`: lint baseline, impact map, `test_dmsh_abi.py`, `HOST_DIRS` ×2, `usage.py`, doc links.
   - Keep the modules flat in `dm/gfx/nvn`, with one common prefix and no `_mac` suffix.
2. **Tests.** The 75 white-box sources reach 555 internal names. Of these, 390 are used by exactly one test.
   - Recommended: a transitional unity file for the split itself, which is zero-risk for the host.
   - `nvn_replay` (and the two digest/capture tests) move first onto objects built like the host. Otherwise the replay-CPU oracle stops describing the split host.
   - The rest then migrate, in order of internals reached, to module headers, with an `NVN_TESTABLE` linkage macro.
3. **Inlining across modules.** On the Mac, ThinLTO inlines small cross-module callees. It does not inline:
   - functions above the plain inline threshold: there is no single-caller bonus across modules (335 static functions have exactly one call site today);
   - functions referencing ObjC class literals, `@"..."`, `@selector`, `dispatch_once` or `used` statics.

   It also leaves an `objc_retain`/`objc_release` pair on inlined ObjC returns. iOS Release is `-Os` with no LTO, so it inlines nothing across modules.
   - Hot shared helpers belong in headers as `static inline` (`always_inline` where per draw), reading `extern` state.
   - Single-caller callees stay in their caller's module.
4. **ObjC/ARC.** Direct access to an `extern __strong` global costs the same as a static. An out-of-line accessor returning `id` adds retain/release.
   - `@public` ivars read from another module cost 5 instructions instead of 2 on iOS.
   - Lazy `static v = -1` caches must not go into header inlines.
   - `nvn_rec.h`'s three `@implementation`s must move into a `.m`.
5. **Symbols.** No nvn_mtl.m static collides with a host export or a test's global.
   - 1 collides with a `hle_nvn.c` static (`g_ft`), 5 with `hle_vk.m` statics and 11 with `hle_gl.m` statics, all link-safe while they stay static.
   - Under `-export_dynamic`, every static made extern with default visibility becomes exported, preserved and `@set:`-visible. Hidden visibility avoids all three.
   - `-Wl,-exported_symbol,'_g_*'` is verified to keep `@set:` working under ThinLTO.

## 1. Builds that compile `nvn_mtl.m`

`rg -n 'nvn_mtl' --hidden -g '!*.md'` gives 71 files. Most mentions are comments. The ones with mechanics follow.

### 1.1 Mac host: `dm/host/Makefile`

- **Flags.** Line 18: `CFLAGS=-O2 -flto=thin -Wl,-export_dynamic -g -Wall -Wno-unused-function`.
- **Sources.** Line 23: `GFX=$(sort $(wildcard ../gfx/*.c ../gfx/nvn/*.c ../gfx/nvn/*.m ../gfx/nvn/*.S ../gfx/tex/*.c ../gfx/tex/*.m ../gfx/vk/*.m ../gfx/gl/*.m))`.
- **Header prerequisites.** Line 24: `GFX_H=$(sort $(wildcard ../gfx/nvn/*.h ../gfx/nvn/*.inc ../gfx/nvn/include/*.h ../gfx/tex/*.h))`.
- **Rule.** Lines 70-71: `dmhost:` depends on `$(SRC) $(GFX) … $(GFX_H) $(GAME_H) …` and runs one `clang … -fobjc-arc -o $@ $(SRC) $(GFX) …`.
- **A new `dm/gfx/nvn/<x>.m`:** nothing to add. **A new `.h` or `.inc` there:** nothing either; it is a prerequisite through the wildcard.
- **Not picked up:**
  - a subdirectory (`dm/gfx/nvn/mtl/…`): neither its sources nor its headers;
  - any explicit duplicate: `gen_build.py:29-30` stops the iOS build when a source appears twice in the compile line.
- **Header-only change:** picked up, but any change relinks and recompiles every host source. The rule is a single clang command, so the frontends run one after another.
  - Probe `p4`: four copies of a TU with nvn_mtl.m's system-header set, in one `clang -c` command, take 2.49 s; one takes 0.59 s.
  - B1 measured the host at 17.8 s real / 23.8 s user (`scratchpad/b1/build_pk_o2.log:282-283`).
  - The ThinLTO backend runs in parallel inside ld.

### 1.2 gfx tests: `dm/gfx/tests/Makefile`

- **Source lists.**
  - Line 14: `CFLAGS` as the host, with `-Wl,-export_dynamic`.
  - Line 15: `GFX` is a wildcard of `../nvn/*.c *.m *.S ../tex/*.c *.m`, minus `hle_nvn.c`.
  - Line 16: `GFX_H` covers `../nvn/*.h *.inc include/*.h ../tex/*.h`, the game header and the MSL header.
  - Line 27: `MTL_T_DEP` = `hle_nvn.c crash.c hle_bigstack.c t_host_stubs.c $(GFX) $(GFX_H)`.
  - Line 28: `MTL_T_SRC` = the same, with `$(filter-out ../nvn/nvn_mtl.m,$(GFX))`.
- **Link modes for `nvn_mtl.m`:**
  - **White-box: the test `#include`s it and links `MTL_T_SRC`.** About 60 rules: 46, 108, 110, 127, 129, 135, 143, 148, ….
  - **White-box with the filter-out spelled out:** 75, 168, 174, 186, 282, 359, 361.
  - **Black-box, linking `$(GFX)` whole:** `t_gfx_suspend` (51) and `t_nvn` (53). New modules come in automatically.
  - **Black-box, with `nvn_mtl.m` written out:** `t_thermal` (97), `t_thermal_tsan` (99), `t_vk_desc` (427), `t_gl_imports` (429).
  - **Prerequisite only:** `t_sparse_tile` (72) lists `../nvn/nvn_mtl.m` without compiling it. It breaks with "No rule to make target" once the file is gone.
- **For a new module `dm/gfx/nvn/mtl_<x>.m`**, with one wildcard such as `MTL_MODS = $(wildcard ../nvn/mtl_*.m)` (no existing `dm/gfx/nvn` file starts with `mtl_`):
  - (a) line 28 and the 7 explicit filter-outs filter `../nvn/nvn_mtl.m $(MTL_MODS)`. Otherwise a test that includes the unity also links the modules: duplicate symbols and duplicate ObjC classes.
  - (b) lines 97, 99, 427 and 429 take `$(MTL_MODS)` where they write `../nvn/nvn_mtl.m`.
  - (c) line 72 drops or retargets the prerequisite.

  Without a common prefix, the list has to be spelled out, because `nvn_refl.m` and `host_msl.m` already sit in `../nvn/*.m`.
- **Header-only change:** picked up through `MTL_T_DEP`, which rebuilds every white-box test. There is no `-MMD`. Pre-existing gap: `dm/host/dm.h` and `front.h`, which `nvn_mtl.m` includes, are not prerequisites of the tests.

### 1.3 iOS

- **`dm/ios/tools/gen_build.py`.**
  - Lines 11-12 run `make -s -n -B -C dm/host dmhost MSL_SDK=iphoneos`; line 26 takes every `.c`/`.m`/`.S` token of the expanded command.
  - Line 37 drops files whose stem ends in `_mac`. Line 40 symlinks each source as `Gen/src/<path with __>`, for example `gfx__nvn__mtl_x.m`.
  - Line 42 puts every source directory on `HEADER_SEARCH_PATHS`, so quoted includes still resolve from the symlinks.
- **`dm/ios/project.yml`.**
  - Line 22: `Gen/src` is a source folder. Line 80: ARC on. Line 79: `OTHER_CFLAGS -mcpu=apple-a18`.
  - It sets neither `GCC_OPTIMIZATION_LEVEL` nor `LLVM_LTO`. XcodeGen's `Configs/release.yml` sets neither.
  - The defaults therefore apply (Xcode's `Clang.xcspec`, `SWBUniversalPlatform.framework/…/Clang.xcspec` lines 968-983 and 1035-1047): `GCC_OPTIMIZATION_LEVEL` = `s` and `LLVM_LTO` = `NO`. There is no `-export_dynamic` either: `gen_build.py` passes only `-I`, `-D`, sources and frameworks.
- **`dm/ios/tools/build_ipa.sh`.** Line 74 runs `rm -rf Gen`, line 75 runs `gen_build.py`, line 156 runs `xcodebuild … -configuration Release … -derivedDataPath "$DD"` (`$DD = $O/dd`, kept between runs).
- **`dm/ios/tools/compile_check.py`.** Same `make -n` source list; it compiles each file with `-O1 -w` and has no dependency tracking.
- **`scripts/build_ipa_from_nsp.py`** calls `build_ipa.sh`. Its host fingerprint is `HOST_DIRS` (line 1287, used at 1313): flat folders only.
- **A new module needs:** nothing, if flat in `dm/gfx/nvn` and not named `*_mac.m`. Xcode tracks headers through clang's dependency files and compiles the modules in parallel, so the split shortens the iOS critical path.

### 1.4 `dm/gfx/nvn` generators

- `dm/gfx/tools/gen_protos.py` writes `nvn_protos.h`, `nvn_thunks.S` and `nvn_count.h` from `nvn.h`. They are not part of the Makefiles; their consumer is `hle_nvn.c` (lines 12-13, 45-93: `nvn_slot`, `nvn_unimpl_c`).
- No `.S` file references an `nvn_mtl.m` symbol, and `nvn_mtl.m` has no inline asm. Nothing to change.

### 1.5 Other files keyed to the name `nvn_mtl.m`

| File | What breaks when code leaves `nvn_mtl.m` |
|---|---|
| `dm/tools/lint_c_baseline.tsv` 24-36 | 13 rows of per-file clang-tidy counts. The findings move to the module files. `lint_c.py tidy --update` only shrinks, `--against` (CI) fails on new rows (`lint_c.py:175-186`), and the header says "never edit by hand to add". The split commit has to move the rows by hand and say why. |
| `dm/tools/impact_map.tsv` 39-51 | 13 rules `dm/gfx/nvn/nvn_mtl.m:<function regex>`. They stop applying to moved functions; retarget them to the module files (the column is a glob, so `dm/gfx/nvn/mtl_*.m:<regex>` works). `test_usage.py` fails on a glob that matches no file. |
| `dm/tools/tests/test_dmsh_abi.py` 25, 116 | The per-file ABI literal baseline for `nvn_mtl.m`, and `assertIn('#include "dmsh_abi.h"', nvn_mtl.m)`. Both move to the modules that hold the literals and the include. |
| `scripts/build_ipa_from_nsp.py:1287`, `scripts/regress.py:93`, `dm/tools/usage.py:146-147` | Flat folder lists of host sources (fingerprint, regress trees, call graph). A subdirectory needs an entry in each, and in both Makefiles' wildcards. |
| `docs/geometry-metal-research.md` | 2 markdown links to `../dm/gfx/nvn/nvn_mtl.m`, checked by `test_docs.py`. 176 prose mentions with line numbers in `*.md` and ~100 in code comments go stale; nothing checks them. |
| `dm/tools/env_switches.py` | Scans `git ls-files`. A new module must be tracked before `env_switches.py --check`, or its `getenv` switches read as unread. |
| `.github/workflows/tests.yml` | Lists tests by name only. Unaffected unless tests are renamed. |

## 2. The white-box tests

### 2.1 What they reach

- **Which files.** 75 sources `#include "../nvn/nvn_mtl.m"`: 74 tracked, plus the untracked `t_rec_digest.m`. `nvn_replay.m` is among them. `t_geometry_hazards`, `t_geometry_feedback` and `t_geometry_primitive_id` reach it through `#include "t_geometry.m"`. 12 of them also `#include "../nvn/hle_nvn.c"` in the same TU (`nvn_replay`, `t_capture_live`, `t_copy_alias`, `t_cpu_tex`, `t_linear_readback`, `t_link_ticks`, `t_mip_extent`, `t_present_crop`, `t_present_snap`, `t_queue_origin`, `t_readback`, `t_sparse_tex`), and so reach `hle_nvn.c`'s statics too (`g_spb`, `g_tpb`, `g_sub_mu`, …).
- **`testrefs.tsv` format.** Columns `name, number of tests, comma-separated tests`, 390 rows, variables only:
  - 248 file-scope statics of `nvn_mtl.m`, plus 1 extern;
  - 141 names that are not file-scope in `nvn_mtl.m`: function-local statics or `hle_nvn.c` statics, partly noise from locals that share a name (`after`, `again`, `all`).
- **Method.** I classified every top-level declaration of `nvn_mtl.m` and its includes (`.inc`, `nvn_rec.h`) from the AST, then intersected with the identifiers of each test (comments and strings stripped, member accesses skipped). Result: `split-probe/classify.out`; per test, `per_test.json`.

| Kind (defined in nvn_mtl.m + includes) | Defined | Reached by tests | Tests reaching one |
|---|---|---|---|
| static variables | 1,073 | 258 | 72 |
| static functions | 819 | 201 | 75 |
| static inline functions | 77 | 27 | 22 |
| macros | 63 | 12 | 36 |
| ObjC classes | 16 | 8 | 36 |
| types / enum constants | 80 / 170 | 10 / 26 | 9 / 13 |
| non-static functions declared in no header | 89 | 12 | 44 |
| non-static functions with a public header | 98 | 44 | 68 |

- **Most shared.**
  - Static functions: `bp_now` 74, `state_reset` 37, `serial_put` 34, `tex_mtl` 26, `blit` 19, `tex_desc` 14, `q_cb` 12.
  - Variables: `g_dev` 63, `R` 35, `S` 21, `g_ft` 12, `g_q` 10.
  - Other kinds: the macro `res_add` 26, the classes `NvShader` 29 and `NvProg` 27, the header-less `mtl_last_commit_error` 36.
- **Long tail.** 390 of the 555 internal names are used by one test only. A shared test header with the 30 most used names covers 4 tests fully; 320 names cover 36. For the tests to link against separately compiled modules, 472 names would need external linkage: 258 static variables, 201 static functions, 13 header-less externs.
- **Spread over the file.** Taking the file's 30 `// ----------` sections and 5 included files as module proxies, a test reaches 2-13 sections. With the 30 most shared names exposed as module API (they will be cross-module anyway), 43 tests reach ≤ 2 sections and 55 reach ≤ 3.
- **Internals per test** (static functions + static variables + macros + classes + header-less externs + types):
  - 0-8 (17 tests): `t_rt_range_ro` 3, `t_initial_uncached` 4, `t_integer_blend` 4, `t_rt_range_shape` 4, `t_ub` 4, `t_ms_slot` 5, `t_cube_placeholder` 6, `t_first_sampled` 6, `t_stream` 6, `t_depth16_clear` 7, `t_float_pad` 7, `t_stream_sock` 7, `t_tex_fit_root` 7, `t_view_levels` 7, `t_clear_layers` 8, `t_shmap_warm` 8, `t_stencil_view` 8.
  - 9-15 (22 tests): `t_border`, `t_clear_tex`, `t_link_ticks`, `t_missing_src1`, `t_clear_ds`, `t_rec_digest`, `t_linear_readback`, `t_pfv`, `t_rt_depth_ro`, `t_capture_live`, `t_primitive_restart`, `t_pull`, `t_image_usage`, `t_rast_discard`, `t_alpha`, `t_copy_alias`, `t_cpu_tex`, `t_defer_chain`, `t_fuse_check`, `t_gpuprof`, `t_mip_extent`, `t_reorder_chain`.
  - 16-25 (22 tests): `t_direct_upload`, `t_image_primitive_id`, `t_logic`, `t_ubp_running`, `t_view_swizzle`, `t_zskip`, `t_attachment_capacity`, `t_queue_origin`, `t_sbw`, `t_transform_feedback`, `t_upgrade_alias`, `t_upload_budget`, `t_upload_slots`, `t_present_alloc`, `t_readback`, `t_present_rescue`, `t_unwritten_store`, `t_xv`, `nvn_replay` 22, `t_image_alias`, `t_pso_bundle`, `t_pso_stall`.
  - 26 and more (14 tests): `t_feedback` 26, `t_pso_pending` 26, `t_rt_range` 26, `t_present_snap` 28, `t_present_crop` 29, `t_sparse_tex` 31, `t_vbuf` 33, `t_image_attachment_store` 34, `t_arena_args` 35, `t_pso_depth_stencil` 36, `t_pso_archive` 38, `t_pso_warm` 38, `t_perf_order` 55, `t_geometry` 77.

### 2.2 Couplings that are not names: macros defined before the include

These work only because the test and `nvn_mtl.m` are one TU. Separate compilation silently stops applying them.

| Test (lines) | Macro | Where `nvn_mtl.m` uses it |
|---|---|---|
| `t_perf_order.m` 43-45 | `clock_gettime_nsec_np`, `clock_gettime`, `pthread_cond_timedwait` → test versions (virtual time) | `clock_gettime_nsec_np` at 10 sites from line 144 to 12525, `clock_gettime` at 9, `pthread_cond_timedwait` at 6 |
| `t_link_ticks.m` 17-19 | `clock_gettime`, `pthread_cond_timedwait`, `nvn_game_fps` | as above |
| `t_present_rescue.m` 25 | `CAMetalDisplayLink` → `SilentDisplayLink` | 12633-13051 |
| `t_pso_archive.m` 21 | `confstr` → `archive_confstr` | 6546 |
| `nvn_replay.m` 14-18 | `NVN_REC_TAP` (compile-time hook in `nvn_rec.h` 77-79, 190-192), `dispatch_async` → a wrapper that runs inline under `--digest`, `nvn_game_fps` | `dispatch_async(` at `nvn_mtl.m` 6593, 6862, 6943, 7184, 7512, 10817 and `nvn_geometry.inc` 423 |
| `t_rec_digest.m` 1 | `NVN_REC_TAP` | |
| 12 tests with `hle_nvn.c` in the same TU | `#define nvn_game_fps nvn_game_fps_mtl_default`, `#define g_ft g_ft_hle` | They rename the weak `nvn_game_fps` (`nvn_mtl.m` 11528) and the colliding static `g_ft`. Not needed once `hle_nvn.c` is linked separately. |

The S3a sink (`nvn_rec_digest.inc`) also reaches `nvn_rec.h` internals: the `RO_*` enum, `rec_blk` and `g_rec`. Before a test can use it against separately compiled modules, it needs a runtime tap and a "background work inline" switch in the recorder module.

### 2.3 Options

- **(a) Transitional unity source.** `dm/gfx/nvn/nvn_mtl_all.inc` `#include`s the module `.m` files in their original order, then `rt_range_check.inc` and `nvn_capture.inc`.
  - Why `.inc`: no `*.m` wildcard compiles it, and `GFX_H` already tracks it. The 75 includes become `#include "../nvn/nvn_mtl_all.inc"` (one `sed`). Alternative: keep the name `nvn_mtl.m` for the unity and filter it out of `GFX` in both Makefiles (iOS follows); then no test edit, at the price of a misleading file name.
  - Tests Makefile: `MTL_MODS` as in 1.2.
  - Cost: about an hour. Suite build time unchanged.
  - Host and iOS: untouched by this option.
  - It keeps all 75 tests and the macro interposition working at every split commit, so the digest can be compared at each step.
  - Risk: low. The constraints are mechanical:
    - module statics unique across modules, and macros identical where several modules define them;
    - `#pragma once` on every module header (a duplicated `@interface` is an error: probe `p1` failed exactly so);
    - no `static` forward declaration left for a function that another module now defines `extern` (static after non-static is an error).
  - The unity hides a missing `#include`, which the host build catches. The host hides static name clashes, which the unity catches.
  - Weakness: a unity `nvn_replay` inlines across modules the way one TU does, unlike the host (section 3). Replay CPU would then measure a binary that does not exist.
- **(b) Per-module internal headers, tests linking module objects.**
  - The 472 names above need external linkage. Making them plainly extern costs the host:
    - default visibility under `-export_dynamic` loses single-caller inlining and dead-stripping (probe `p6`);
    - on iOS, any extern loses single-caller inlining.
  - Mitigation: `NVN_TESTABLE`, `static` in the host and iOS builds and `__attribute__((visibility("hidden")))` when the modules are compiled for tests with `-DNVN_TESTING`. The modules are then compiled once more per game for the suite.
  - Cost: high (~470 declarations, every test touched). Risk to the host: none with the macro.
  - This is the plan's S6 end state: "tests and `nvn_replay` include headers, never a `.m` file".
- **(c) Public headers plus the test sink.** Tests assert on the command-stream digest or dump, pixels and public state.
  - Cost: highest (rewrites).
  - Risk: coverage of internal invariants the stream does not show is lost: `t_ub`'s phase table, pipeline-cache states (`t_pso_*`), upload-slot reuse, `t_perf_order`'s wait ordering.
  - Prerequisite: the sink as a runtime API (2.2).
- **(d) Per-module white-box include.** A test `#include`s only the module(s) whose statics it reaches, and links the other modules' objects with those filtered out.
  - Statics stay static, and the macros of 2.2 still apply to the included module.
  - Cost: per-test Makefile lists (or a rule derived from each test's `#include` lines). Risk: low to moderate.
  - Fits the 43-55 tests that reach ≤ 2-3 sections. A poor fit for the clock-interposing tests (`clock_gettime_nsec_np` sits in 10 places across the file) and for `t_geometry` / `t_perf_order`.

### 2.4 Recommendation and migration order

Use (a) for the split commits. Then (b), with `NVN_TESTABLE`, as the end state the plan asks for. (d) is the fallback for heavy tests, and (c) for tests whose natural oracle is the stream.

Order:

1. **Before the first module leaves `nvn_mtl.m`: `nvn_replay.m`, then `t_capture_live.m` and `t_rec_digest.m`.** They carry the oracles.
   - `nvn_replay` must link the same module objects with the host's flags, or "replay CPU not above S5's" compares different binaries. Today it already compiles `hle_nvn.c` into its own TU, unlike the host.
   - This needs real extern APIs, not `NVN_TESTABLE`, for its 22 internals: `cap_digest`, `cap_hash_block`, `cap_hex`, `cap_iface`, `cap_plane_opt`, `CAP_IFACE`, `td_dump`, `g_td_done`, `g_td_frame`, `prog_get`, `tex_mtl`, `q_cb`, `g_dev`, `g_rec`, `g_by_serial`, `g_seg`, `g_ghost`, `NvProg`, `dm_gfx_texdump_next`, ….
   - It also needs `NVN_REC_TAP` and the `dispatch_async` macro as runtime switches, and `hle_nvn.c` linked separately (so the renames go).
2. **The 17 tests with ≤ 8 internals** (list in 2.1), `t_ub` among them: `ub_skip`, `g_ubp_c` and `g_ubp_sum_us` become `NVN_TESTABLE`.
3. **The 9-25 bands**, grouped by the module that owns most of their internals, as that module's internal header settles.
4. **The interposing tests, after their seams exist:** `t_present_rescue` (a display-link class hook), `t_pso_archive` (a `confstr` hook), `t_link_ticks` and `t_perf_order` (a clock / condition-wait seam). Or keep them on (d) with the relevant modules.
5. **Last, or rewritten to (c):** `t_geometry` and its three includers, `t_perf_order`, `t_pso_archive`, `t_pso_warm`, `t_pso_depth_stencil`, `t_arena_args`, `t_image_attachment_store`.

The unity file goes when the last includer leaves it.

### 2.5 Build time

**Today:**
- The suite build is 445 s (Pokopia) / 442 s (DK) at `-j4` for 99 tests (B1), about 18 CPU-s per test.
- Each white-box test compiles `nvn_mtl.m` itself: 1.26 MB, 13,110 lines plus 1,876 lines of `.inc` / `nvn_rec.h`.
- Through `MTL_T_SRC`, it also recompiles `hle_nvn.c` (2,926 lines) and every other gfx source, then runs the ThinLTO backend for all of them. Nothing is shared between tests: there are no object files.

**What the split changes:**
- Under (a): nothing. The cost is the Makefile's (no objects), not the file layout's.
- The host gets about +10 s: 0.6-0.8 s of system headers per new TU (`p4`; 0.07 s with `-fmodules` and a warm cache), times ~14 TUs, serial in its single clang command. The exception is a host Makefile with per-object rules (`-MMD -MP`) and `make -j`: then the split shortens the longest job, and edits rebuild only their dependents.
- Under (b) or (d) with module objects built once per game, the per-test ThinLTO backend still reruns over every bitcode object. Probe `p5`: `-Wl,-cache_path_lto` reuses everything when the same test relinks, but makes new entries for a shared object linked into a different test. The suite saving therefore needs native (`-O2`, no `-flto`) library objects for the tests. The exception is `nvn_replay` (and whatever must match the host), built exactly like the host.

## 3. Inlining across translation units

Probes `p1`, `p2`, `p6`, `p7`: two ObjC ARC files, Foundation. For each case, the caller is a `noinline` wrapper in `b.m` calling into `a.m`; I disassembled it with `otool -tvV` and confirmed with `-Wl,-mllvm,-pass-remarks=inline -Wl,-mllvm,-pass-remarks-missed=inline` (these remarks work through ld64).

| Callee in `a.m`, caller in `b.m` | One TU, ThinLTO + `-export_dynamic` | 2 TUs, ThinLTO + `-export_dynamic` (host) | 2 TUs, ThinLTO, no export | 2 TUs `-O2`, no LTO | iOS `-Os`, no LTO (Release today) | iOS `-Os` + ThinLTO |
|---|---|---|---|---|---|---|
| small C function | inlined | inlined | inlined | call | call | inlined |
| big function (cost 330 > threshold 250), one caller | call | call | call | call | call | call |
| big hidden-visibility function, one caller | inlined | call | call | call | call | call |
| reads a local `__attribute__((used))` static | inlined | call: not imported | call | call | call | call |
| reads a plain static | inlined | inlined (static promoted) | inlined | call | call | inlined |
| sends an ObjC message (`s.length`) | inlined | inlined | inlined | call | call | inlined |
| `[Foo class]`, `[Foo new]`, `isKindOfClass:[Foo class]`, `@[…]`, `@"…"`, `@selector`, `dispatch_once` | inlined | call: not imported | call | call | call | call |
| `@protocol`, block literals (global and capturing), function-local static, `_Thread_local`, `@autoreleasepool`, C string + `fprintf` (MLOG), `getenv` cache | inlined | inlined | inlined | call | call | – |
| extern `always_inline`, any size | – | inlined | – | – | call | – |
| weak definition | call | call | call | call | call | call |
| `static inline` in a header | inlined | inlined | inlined | inlined | inlined | inlined |
| `id o = x_get(); [o hash]`, `x_get` returning a `__strong` static | 3 instructions, no ARC call | inlined, but `objc_retain` + `objc_release` stay (15 instructions) | same | call + ARC return handshake | call + `objc_claimAutoreleasedReturnValue` + `objc_release_x19` | inlined + retain/release (14) |
| `static inline` header accessor of an `extern __strong` global | – | no ARC call | – | – | no ARC call | – |
| `@public` ivar read from the other TU | 2 instructions | 2 | 2 | 5 (loads `OBJC_IVAR_$_…`) | 5 | 2 |

Findings:

- **Small cross-module callees are inlined by ThinLTO** whether or not `-export_dynamic` is set; the flag does not affect importing (this confirms B1).
- **There is no single-caller bonus across modules.** In one TU, a static (or internalized) callee with one call site is inlined whatever its size: the remark reads `cost=-14670, threshold=250`.
  - Across modules, the callee is either not imported, or imported and judged at the plain threshold. `x_big` was imported: the remark reads "too costly to inline (cost=330, threshold=250)".
  - Raising `-Wl,-mllvm,-import-instr-limit=400` changed nothing.
  - At BASE (`scratchpad/ast/nvn_mtl.m.tsv`), 335 of the static functions have exactly one call site and are never address-taken. Each becomes a real call if the split puts it in a different module from its caller.
- **Probe `p6`: single-caller, same-module callees.** The callee has cost 330, and its caller is not itself imported elsewhere:

  | | static | hidden extern | default extern |
  |---|---|---|---|
  | ThinLTO + `-export_dynamic` (host) | inlined | inlined (internalized) | call: preserved by `-export_dynamic` |
  | ThinLTO, no export | inlined | inlined | inlined |
  | `-O2` / iOS `-Os`, no LTO | inlined | call | call |

  In the first `p6` variant the caller itself was imported into `main`'s module. The callee then counted as referenced from another module and stayed a call even when hidden.
- **ObjC class references, NSString literals, `@selector` and `dispatch_once` block importing.** So do the `used` statics B1 noted. Plain message sends do not: they are external `objc_msgSend$sel` stub calls.
- **ARC after cross-module inlining.** The pass that removes retain/release pairs runs in clang's own optimization pipeline, not in the ThinLTO backend that ld64 drives. That is why a cross-module-inlined ObjC return keeps a retain/release pair that the one-TU build removes (row `x_get`).
- **iOS Release today has no LTO.** After the split it inlines nothing across modules: every cross-module helper becomes a call, including the tiny ones. One example already exists: `tex_fast` (`nvn_mtl.m` 5177) calls `nvn_dirty_now()`, a one-line extern in `nvn_dirty.c:200`. The Mac inlines it; iOS calls it. `LLVM_LTO = YES_THIN` in `project.yml` would give iOS the Mac's behaviour. S1 kept iOS untouched, so that is the user's decision.

Recommendations for hot helpers:

- **Hot and shared:** `static inline` in the owning module's header, with `__attribute__((always_inline))` on per-draw or per-binding paths, as `tex_fast`, `tex_rid_`, `samp_fast` (5177, 5296, 5344) and nvn_rec.h's `rec_on` already are. It is the only form inlined on both platforms and ARC-optimized in the caller.
  - The state such a helper reads (`g_treg`, `g_ntreg`, `g_ser_gen`, `g_sview`, `g_sreg_ok`, `g_rec`) becomes `extern` and hidden, or a context-struct member (S3b).
- **`always_inline` on an extern function in another `.m`** works on the Mac only. Do not use it as the sharing mechanism.
- **Single-caller callees stay `static` in their caller's module.** Write this into the module map as a constraint.
- **Functions that create ObjC objects from class literals, or use `@"…"`/`@selector`/`dispatch_once`,** stay in the module that calls them on hot paths. `rec_table_real` (`nvn_rec.h:259`, `[DmRecTable class]`), called by every recorded `setArgumentTable`, is one.
- **Check after the split.** Both commands below need the full `CFLAGS` given on the command line, because the Makefile sets it with `=`:
  - inlining remarks for the hot functions: `make -C dm/host GAME=<id> CFLAGS='-O2 -flto=thin -Wl,-export_dynamic -g -Wall -Wno-unused-function -mmacosx-version-min=26.6 -Wl,-mllvm,-pass-remarks-missed=inline'`, filtered by name;
  - `otool -tvV dm/host/dmhost`: look for `bl _<helper>` inside them.

## 4. ObjC / ARC specifics

**Inventory** (HEAD AST):
- 1,075 file-scope variables. 116 hold ObjC objects or blocks: `__strong` by default, for example `g_dev`, `g_q`, `g_q4`, `g_cb` (764), `g_enc` (3479), the argument tables `g_vt` / `g_ft` / `g_ct`, `g_res`, `g_ev`, `g_deferred`, and `g_rx_cb` / `g_rx_enc` in `nvn_rec.h`.
- 90 `_Atomic`, 49 locks / conditions, 9 `_Thread_local`.
- 76 `__unsafe_unretained`, 22 `CFBridgingRetain` / bridge casts (the table-held objects of `g_treg`), no `__weak`.
- 18 struct definitions with `id` members.
- `R` (3445), `S` (5387) and `g_pass` (3482) are anonymous struct types. Sharing them needs a named typedef in a header. `R` and `S` are plain C; `g_pass` has `__unsafe_unretained id` members, so its header is ObjC-only.
- `hle_nvn.c` is C and includes `nvn_mtl.h` / `nvn_obj.h`. Module headers it includes must stay C, or use the `#ifdef __OBJC__` pattern of `nvn_refl.h:70`.

**Statics made extern, by access pattern:**
- **Direct use of an `extern __strong` global from another module** generates the same code as a static: `[g_ext hash]` and `id o = g_ext; [o hash]` are 4 instructions with no ARC call, on the Mac with or without LTO and on iOS (`p1` `t_ext`, `t_ext_local`; `p2` `t_uu_direct`).
- **An out-of-line accessor returning `id` adds traffic on a hot path.**
  - Mac ThinLTO: one `objc_retain` plus one `objc_release`, even after inlining.
  - iOS: a call plus `objc_claimAutoreleasedReturnValue` plus `objc_release`.
  - Neither `ns_returns_not_retained` nor an `__unsafe_unretained` local removed the pair in the ThinLTO build (`p1` `t_get_uu`: 12 instructions, retain + release); `__unsafe_unretained` on a return type is ignored with a warning.
  - Use a `static inline` header accessor (`p2` `t_hget`: no ARC call), the global itself, or `void *` table storage (the existing `g_treg[tid].view` pattern).
- **`@interface` / `@implementation`.** The 16 classes are `NvImageHeap`, `NvDeferredRelease`, `NvPkg`, `NvShader`, `NvProg`, `WarmItem`, `FnDev`, `NvArena`, `ArchEpoch`, `PbaseBuild`, `WarmTask`, `WarmLoad` and `NvMetalDisplayLinkDelegate` in `nvn_mtl.m`, plus `DmRecTable`, `DmRecEnc` and `DmRecCB` in `nvn_rec.h` 251-332.
  - Most have `@public` ivars read with `->`. The `@interface` goes into a guarded header, the `@implementation` into exactly one `.m`.
  - `nvn_rec.h` today defines three `@implementation`s in a header. A second including TU gives duplicate `_OBJC_CLASS_$_DmRec*` at link, so they must move into a `.m`.
  - Cross-module `->ivar`: 2 instructions on the Mac (ThinLTO folds the ivar offset), 5 on iOS (it loads `OBJC_IVAR_$_Class.ivar`). In the implementing TU it is 2 on both. This is one more reason for S4's hot C structs.
- **Blocks.** 44 lines with block literals and 7 `dispatch_async(` sites. Blocks reference globals directly and capture only locals, so static to extern changes neither block layout nor retain traffic. Block-containing functions import fine (`p2`).
- **`@autoreleasepool`.** 22 in `nvn_mtl.m` and 1 in `nvn_rec.h` `rec_thread` (around line 193). Pools are dynamic scopes: a function moved to another module keeps its pool only if the `@autoreleasepool` moves with it.
  - Thread entries keep theirs: `rec_thread`, `ubc_thread`, the present thread, the prebuild and warm workers. `docs/reference/memory.md` has a past leak from a drain without a pool.
  - Objects returned across modules keep ARC's return handshake (`objc_autoreleaseReturnValue` / `objc_claimAutoreleasedReturnValue`) when both sides are ARC at `-O`, so they do not reach the pool. ThinLTO inlining turns the pair into retain/release.
- **Lazy switch caches.** There are 88 `static … = -1` caches (29 function-local `static int v = -1` inside `*_on()` functions).
  - A function holding one must not become a header `static inline`. Each including TU would get its own cache: `getenv` and its MLOG line once per module, and writes not shared.
  - Keep such functions out of line in one module, or use one extern variable read by an inline (`rec_on` / `g_rec`, `nvn_rec.h` 82-91).
- **Others.**
  - `_Thread_local`: on Darwin, access goes through the TLV thunk whatever the linkage. Extern TLS behaves like static TLS and imports fine.
  - The static constructor `bp_t0` (1409) is the only one. Constructor order across TUs is unspecified; nothing depends on it.

## 5. Symbols

- **`-Wl,-export_dynamic`** (host `Makefile:18`, tests `Makefile:14`) keeps every default-visibility global exported and preserved by LTO. `nm -gU dm/host/dmhost` (10:51 build) lists 2,057.
  - A static made extern with default visibility joins that list: an export-trie entry, a kept out-of-line copy, and no single-caller inlining (`p6`). If it is an `int`, `ub_var` can find it.
  - Hidden visibility (`p3`) is not exported and not found by `dlsym`, and ThinLTO internalizes it when only its own module references it.
  - Recommendation: compile the nvn modules with a hidden default (an `NVN_INTERNAL` macro, or `-fvisibility=hidden` with the public `mtl_*` / `nvn_*` API marked default).
- **`ub_var` and `@set:`** (`nvn_mtl.m` 1430-1437) check a table, `{ "g_dm_present_link", &g_dm_present_link }`, then `dlsym(RTLD_DEFAULT, nm)`.
  - `nvn_mtl.m` has one non-static variable, `g_dm_present_link` (line 122). It is the only `@set:` target the file offers today; the 88 switch caches are statics, unreachable before and after the split.
  - Wherever `ub_var` lands, the `extern int g_dm_present_link` must resolve; the table is what makes it work on iOS.
  - Probe `p3`, which settles the B1 review's open option (b) on ld-27106.1: with ThinLTO and `-Wl,-exported_symbol,'_g_*'`, `dlsym` finds `g_switch_a` (a module's) and `g_t_ub_var` (the test's), and `x_helper` is internalized. `_main` and `__mh_execute_header` are no longer exported; the only `dlsym` in `dm` is `ub_var`'s.
- **`t_ub`.** It defines its own `g_t_ub_var` / `g_t_ub_var2` (`t_ub.m:9`), which `dlsym` must find. So its link needs `-export_dynamic` (B1) or the `_g_*` export list, with or without the split.
  - It reaches `ub_skip`, `g_ubp_c` and `g_ubp_sum_us` (statics) and `mtl_set_frame` / `mtl_ub_present` (public).
  - Under (a) nothing changes. Under (b) the three statics become `NVN_TESTABLE`. Under (d) it includes the module that holds `ub_*`.
- **Collisions** (HEAD ASTs of `nvn_mtl.m`, `hle_nvn.c`, `hle_vk.m`, `hle_gl.m`, plus the host's exports):
  - nvn_mtl.m statics vs the 2,057 host exports: 0.
  - vs non-static names the test files define: 0.
  - vs `hle_nvn.c` statics: `g_ft`. `nvn_replay` and the others rename it with `#define`.
  - vs `hle_vk.m` statics: `blit`, `g_dev`, `g_done`, `g_ev`, `g_q`.
  - vs `hle_gl.m` statics: `S`, `arena_alloc`, `dss_get`, `g_cb`, `g_cur_arena`, `g_dev`, `g_done`, `g_enc`, `g_ev`, `g_q`, `pso_get`.

  All link-safe while the other side stays static. But a TU that includes an nvn module header declaring `extern … g_dev` and keeps its own `static … g_dev` fails to compile, and lldb / nm show several same-named symbols. Give every name that leaves its module a prefix (`nvn_` / `mtl_`), or a context-struct member.
- **Same-named statics in two modules.** No clash under ThinLTO on ld64 (`p8`): two promoted `_s_x`, both "non-external (was a private external)", correct values, no `.llvm.` suffix (the host has 0 `.llvm.` symbols). lldb's `image lookup -s` lists both.
- **ObjC class names** share one runtime namespace. A duplicate fails at link (`_OBJC_CLASS_$_…`); in a unity TU it fails at compile.

## Probe index

| Dir | What | Build |
|---|---|---|
| `p1` | small, big, hidden, `used` static, plain static, message, accessor, ext global, class ref, ivar, header inline, static single-caller | `build.sh`: 4 Mac variants, 3 iOS variants (`xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=26.0 -mcpu=apple-a18 -Os`); `python3 -I dis.py <bins>` |
| `p2` | ObjC constructs and import; `always_inline` extern; weak; header accessors | `build.sh`; `python3 -I dis2.py unity lto_ed lto_ed_lim400 ios_os` |
| `p3` | `dlsym` under `-export_dynamic`, none, `-exported_symbol,'_g_*'`, no LTO; hidden | `build.sh` |
| `p4` | system-header cost per TU; serial inputs in one clang command | inline commands |
| `p5` | ThinLTO cache reuse across test links | `build.sh` |
| `p6` | single-caller inlining by visibility | `build.sh`, remarks command |
| `p7` | MLOG / once / `getenv` patterns import | inline command |
| `p8` | same-named statics promoted in two modules | inline command |
