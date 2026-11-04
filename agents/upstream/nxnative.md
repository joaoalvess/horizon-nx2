# nxnative map

What upstream `seedds/nxnative` did after the fork stopped syncing, judged against the fork's code. How a round runs: `agents/upstream/README.md`.

| | |
|---|---|
| Reading clone | `/Volumes/Hangar/nxnative` |
| Last meeting point | `6136418b` (2026-11-03), the merge base of `refactor` and upstream `main` |
| Mapped up to | `975bb4c1` (upstream `main`, 2026-11-04 17:29 UTC) |
| Round 1 | 2026-11-04 19:32 -03: 155 commits against `refactor` `9c1ff5da` |

Round 1 verdicts: NEW 111, PARTIAL 9, DONE 2, OURS 6, NO-VALUE 27. Most NEW rows fix games the fork has a profile for but its three main games do not reach (their modules import none of the calls).

## Picks

An independent reviewer checked the claims behind these against the fork's code and logs. "Lands" follows the refactor's windows: `free` at any time; `after-M0` for `dm/gfx/nvn`, `dm/gfx/tests`, `dm/host/Makefile`, `dm/ios/tools` and `dm/host/hle_thread.c`; `chain` after M0 is accepted, with every game's shaders rebuilt.

| Upstream | What it brings to the fork | Evidence in the fork, before the port | Check | Lands | State |
|---|---|---|---|---|---|
| `12915a31` | DK: `gpu_timestamps segment`, so the game's dynamic resolution sees the GPU in heavy areas (upstream: frame p50 50.2 → 33.3 ms on an M1 Pro) | `dm/games/040074A01BF12000/game.tsv` has no `gpu_timestamps`; the mechanism is there (`nvn_mtl.m` `seg_ts`); never measured together with `enc_thread on` | DK bench with `DM_NVN_GPU_TS=segment` against without, `enc_thread on` | free | ported in the "now" pull request; not measured on the games |
| `c96a5dce`, `869b9423` | Pokopia: `--seen-shaders`, a Mac build of only the shaders its playtests used (8,158 of 131,426) in minutes; `depth_mode zero` for a packed app's offline archive | no `--seen-shaders` in `scripts/build_ipa_from_nsp.py`; a full Mac shader build of Pokopia is estimated at 11 hours, and the last one here was stopped at 347 of 131,426 with an ETA of 51 h; Pokopia logs `depth mode: near=0` | a partial build, then a Pokopia boot through the guard with it | free | ported in the "now" pull request; not measured on the games |
| `aafe01d3` | the launcher's Game language row for games packed from dumps (no `control.nacp`) | the three games' folders have no NACP; `dm/games/settings.py` keeps only NACP languages | `settings.py` on the three profiles | free | ported in the "now" pull request; not measured on the games |
| `50675d51` | DK: present interval 3 back on the 60 Hz link: 20 fps instead of 15 in its interval-3 scenes | `hle_nvn.c` starts the 30 Hz run for any interval of 2 or more; DK bench frames at interval 3: p50 66.0 ms | DK bench over a cutscene | after-M0 | open |
| `56e4577b` (upsample part) | DK: the bloom upsample reads the level its sampler pins, not the level it draws (the stage intro's neon letters) | `ad1a5991aaad135e` draws level 3 of `ser=21882` and samples it; no `fb_pinned_level` | DK neon-intro shot before and after | after-M0 | open |
| `4e5582eb` | DK: a depth clear with a partial stencil mask draws only the stencil (upstream: load 22.8 → 4.6 MB a frame) | `nvn_mtl.m` takes the triangle clear for depth too; DK's first pass logs it | DK pass dump and GPU time | after-M0 | open |
| `04ef91eb` (IMAGE rule, prescan) | Pokopia: IMAGE BC textures in a CPU_UNCACHED pool no longer show the previous item's picture | `nvn_mtl.m` excludes IMAGE for BC; a BC7 texture fell to the one-time fill in a Pokopia log | Pokopia store and Pokédex icons | after-M0 | open |
| `3ace3df3` | c1 constants in banked slices when `c1_full.tsv` is missing, instead of a 64 KiB buffer each | Pokopia and MKW logs: "c1_full.tsv is stale or missing"; the cause in the fork is libraries built without a full `dmsh_build.py` run, so a stamped build is the other fix | residency-set count in a Pokopia boot | after-M0 | open |
| `92f223a7` | an sRGB and a linear texture over one storage are views of one texture (upstream: MKW's frozen Grand Prix movie) | the alias key includes the format, so the pair gets two textures; the movie is not recorded in the fork's MKW notes | MKW Grand Prix movie | after-M0 | open |
| `e250bb8b` | submit-thread CPU cuts: deferred-update scans and the counting trampoline's shared `stadd` (upstream: about 9 % of translation cycles on BotW) | no such cuts in `dm/gfx/nvn`; `nvn_thunks.S` counts every call | the refactor's replay instruction count | after-M0 | open, refactor catalog |
| `84ec307f`, `53ab7a9d` | DK: the depth prepass's mesh draws in one dispatch (upstream: 1.50 → 0.67-0.72 ms on an M1) | no run gathering in `nvn_geometry.inc` or `dmsh_mesh.py`; DK uses the same vertex and kernel pair | DK GPU time of the prepass | chain | open, refactor list |
| `e07cba1c` | MKW: the culling shaders' first-invocation reset goes to the host, so blocks of trees and bushes stop vanishing | `2ce9071c2f22d74f`, `5fea9b7ddb30e8a8` and `0823b08c2027a38d` are in the 1.8.0 build with no `first_store`; the translated `2ce9071c2f22d74f` zeroes the list counter under the first-invocation test and adds to it with `atomic_fetch_add` | `test_dmsh_first_store.py`; an MKW race on a tree-heavy course | chain | open |
| `1d4b8e82` (shader and mesh parts), `5ae0d9ae`, `e556f7a1` | MKW: task and mesh shaders (bushes, grass), the 48 KB DrivePass compute shaders through `tg_spill`, the sky panels | MKW logs `[RED] NVN unimplemented function called: nvnCommandBufferDrawMeshTasks` and `Threadgroup memory size (49152) exceeds` | MKW boot: no red line for either, the grass drawn | chain | open, large |
| `a70f0718` | the shader cache key covers `dmsh_ampere` | `dmsh_build.py` `CODE_FP` leaves it out; a cache hit skips `job_for`, where it runs | its test | chain | open |
| `e70fd69d`, `d361c5f8`, `13da1c52` | shader builds: packages read on demand (4.4 GB less for Pokopia), a precompiled header (half a Metal compile's CPU), one compile for a pixel shader's side entry points | none of the three in the fork's tools | Pokopia build time and peak memory | chain | open |

Rejected by the review:
- `185b7dbf`: it changes only the bindless depth-reader test, and none of Pokopia's 8,549 built shaders has a bindless binding. Pokopia's 99,245 splits are another rule's.
- `d6b432e5`: Pokopia keeps running out of focus (frame 8400, 300 of 300 frames shown, after focus left near frame 3300), and guard boots get focus back at boot.
- `56e4577b`, its pacing part: Pokopia takes the path but drops 19 frames in 60,000 presents, against upstream's 110 of 300.

Kept as the fork's own: `1110473c`. The fork shares sparse tiles by physical page since `8fa4f93b`: MKW boots after it hold about 15,700 tiles (980 MB), 12,188 of them shared, where `b55` before it grew to 61,361 tiles (3,835 MB). Two of upstream's ideas are missing: sharing for textures the GPU draws into, and the GPU's content kept across a remap.

## Map

| Commit | What it does | Verdict | Lands | Effort |
|---|---|---|---|---|
| `e58e4467` | `tex_by_id`: a D32F view as R32F (and D16 as R16) keeps the depth format and maps it to (depth, 0, 0, 1) before the NVN swizzle; `t_view_swizzle` `depth_red_case` | NEW | after-M0 | pick |
| `73f4a48b` | `fs::Unmount` releases a name held in the SDK's own mount table (a RAM disk the host does not mount), via the SDK's `IsMounted` + `Unmount`; host mounts stay a no-op | NEW | free | pick |
| `50675d51` | `present_period`/`nvn_game_fps` (hle_nvn.c): only even intervals count toward the 30 Hz display link; an odd one goes back to 60 Hz at once; the one-second test no longer wraps | NEW | after-M0 | pick (DK README conflict: union) |
| `de23ae82` | `nfp::GetState` returns the amiibo library's state (0 until `Initialize`, 1 until `Finalize`) instead of always 1 | NEW | free | pick |
| `3104c0af` | `nx_extract --keys` checks every NCA, including an NSZ's by its header, with LibHac's `CanOpenSection`. It names the newest missing key and its firmware (exit 6). The NSP script runs it right after the folder scan, before `nsz -D`, the survey and extraction | NEW (low) | free | pick |
| `7d260eef` | `nvn_rec.h`: separate `RO_C_COPY_BT_OPT`/`RO_C_COPY_TB_OPT` stand-ins for blits with options; `check_t_rt_range` also runs with `DM_NVN_ENC_THREAD=1` | OURS | - | - |
| `34459c91` | A same-pass feedback draw that samples its attachment at its own pixel (clip-to-screen varying ÷ w, proven on the vertex source by `screen_varyings`) reads the tile through `[[color(k)]]` (`fb_tile_plan`) instead of taking a snapshot and ending the pass; adds a per-300-frame snapshot/reuse/tile-read counter | NEW | after-M0, chain | pick (only `dmsh_chain.h` conflicts; re-apply refactor's 019a133f one-line `fb_prepare` change to the new loop) |
| `12915a31` | DK profile gets `gpu_timestamps segment`, so each timestamp report takes its segment's GPU start or end and the game's dynamic resolution sees real GPU time | NEW | free | port (union with `enc_thread on`; regenerate `game-patches.md`) |
| `8c10c011` | Princess Peach: Showtime! profile and note: UE 4.27 with Wwise, the small Unreal layout, `fps_target 60`, `depth_mode zero`, no rewriter cuts and no host change. Also records an open TXQ-on-3D red line | NEW (other game) | free | pick |
| `3fe755a2` | LDSM passes `stride: false` to `ALocalAddress`, because bits 78..79 hold its mode (MT88), not the LDS/STS stride | DONE | chain | — |
| `5f96f901` | CI workflow and tool that label PRs by area | NO-VALUE | - | - |
| `1b9fbea4` | `dmsh_wide.wide_loads`: neighbouring 32-bit words of one read-only storage buffer, which the translator split from LDG.64/.128, are read again as one `packed_uint2/3/4` | NEW | chain | pick |
| `4d3a9a53` | Adds an `impact_map.tsv` row for `dmsh_wide.py`, and a shaders.md sentence saying that computing the index once in the translator gains nothing | NO-VALUE (alone) | free | pick with 1b9fbea4 |
| `bd688163` | CI daily triage report of PRs and issues | NO-VALUE | - | - |
| `2c35f7b3` | Test fixture: the mocked `run` in `test_xcode_workflow.py` writes an empty log, because the key-age preflight reads `logs/keys.log` | NO-VALUE | free | pick (with 3104c0af) |
| `c3e66245` | A full `dmsh_build.py` run writes the digests it used (`b-<chain>/_b_cas.txt`). The NSP script's `prune_shader_cache` then deletes the other `cas/shader/<digest>` entries | NEW | chain (`dmsh_build.py`) + scripts | pick |
| `7db7ff09` | Pins `PlatformTarget AnyCPU` in `dmsh_xlate.csproj` and republishes, so the bundled dll loads on Intel Macs | NO-VALUE | chain | — |
| `d145b956` | A TXQ size query whose texture type was guessed (2D) takes the type that other instructions give the same texture slot (`TextureTypesOf`, second translation) | NEW | chain | port (`Program.cs` `Accessor` conflicts with ddd6d94b's `constantBanks`: keep both parameters) |
| `aa94702d` | `fb_snap` gives a new key an entry of the same format and size (not round robin); `mirror_readback` keeps landed readback buffers by power-of-two size (16 MB cap) | NEW | after-M0 | pick |
| `869b9423` | Adds Pokopia `shader_seen.tsv` (8,157 keys from upstream's Mac playtest, chain 38df94307792) and a "Building selected Mac shaders" recipe in development.md | NEW | free | pick |
| `fa681f94` | The watchdog runs `/usr/bin/sample` with `posix_spawn` and separate arguments instead of `system()` on a quoted, 1,200-byte buffer | NEW | free (only `dm/host/tests/Makefile` conflicts: union with refactor's -O2 flags) | pick |
| `1440a736` | `nvnProgramFinalize` drops the program from the active bindings and from every saved queue state under `g_sub_mu` (`mtl_prog_forget`), taking a composite again from the stages left; `t_queue_origin` case | NEW | after-M0 | pick |
| `7ef2aaf5` | AudioOut start moves off the game thread: the silent sink keeps releasing buffers while a GCD worker runs `AudioOutputUnitStart`; the device plays silence until its first callback; a late or failed start is retried; Close during a blocked start returns at once | NEW | free | large (JUDGEMENT: hand-merge with the fork's BK_STREAM, 805fb333, in `backend_stop` and the start path) |
| `f5d5327f` | a read-only, non-atomic fragment image of a colour attachment reads the same-pass snapshot (`fb_snapshot_slot`, `fb_image_view`); `t_feedback` image cases | NEW | after-M0 | port (one hunk: keep the fork's `tex_sampled_rid` on the texture path, 8021) |
| `0a05fb10` | Rewriter finds an int32 target frame rate the game steps by (`fps_target.py`, ≥8 readers of 60/target and a store of 30) and writes `FPS_TARGET_PTR` / `FIELD` into main's fixups; `hle_fpslock.c` writes the profile's `fps_target` there | NEW | free (the rewriter's `build_src.sha256` changes, so each game is rewritten once) | pick (comment union in `hle_fpslock.c`) |
| `b5910377` | Hooks SDK 22's `hid::ShowControllerStrapGuide(const StrapGuideArg&)` like the argument-less one (applet opens and closes) | NEW | free | pick |
| `6a16b7d3` | `tex_cpu_content`: an uncompressed 3D texture without IMAGE/COMPRESSIBLE is taken from its storage at first use | OURS | - | - |
| `379e885e` | Pyright fix in `test_txq_type.py` | NO-VALUE (alone) | free | pick with d145b956 |
| `e70fd69d` | `dmsh_build.py` indexes package records through a mapping it then closes, and `pread`s each record when needed, instead of holding every package in memory | NEW | chain | pick |
| `423a6745` | `scripts/pack_nup.py` reads a NUP container (SPEC v1, SHA-256 checks) with no prod.keys. It writes each version's modules, RomFS image and DLC through a shared `romfs_image.py` writer (`write` / `publish` / `reusable` refactor) | NEW (low) | free | port (README keep the fork's; development.md union) |
| `df60f631` | README gallery: FE Fortune's Weave at 60 fps, captions | NO-VALUE | - | - |
| `07ca3efc` | lint fixes: `t_queue_origin` checks `S.prog` before `prog_get` (NOLINT notes); `pack_nup.py` passes `n.copy` | NO-VALUE | after-M0 | fold into 1440a736 |
| `aa9fa765` | `pack_nup.py` rejects unsafe ExeFS file names (path traversal) in a NUP | NEW (with 423a6745) | free | pick |
| `d70ee900` | Hyrule Warriors: Age of Imprisonment bring-up: GameChat `Initialize` / `IsChatting` / `SetScreenSharingMode`, `oe::IsLanguageSelectionLimited` (no limit), `gs::sdk::SetGraphicsFrameLengthMode` (logged); plus the HW:AoI profile | PARTIAL | free | port (take `hle_oe.c` only; the `hle_misc.c` chat hooks would register `nn::chat` twice, per conflicts.md) |
| `3ace3df3` | a dedicated c1 constant block (shaders without `c1_full.tsv`) becomes an exclusive 64 KiB slice of a 4 MiB bank (`c1_bank`) instead of its own MTLBuffer | NEW | after-M0 | pick |
| `b64a5ff0` | README gallery: Age of Imprisonment screenshot | NO-VALUE | - | - |
| `cfcef15a` | README: a `.nup` file as the first way to build a Switch 2 game | NO-VALUE | - | - |
| `8c80f39a` | `aoc.key` also stamps the files in `aoc/` as extracted, so extracted NSP DLC is not reused after a NUP or dump build has written its own DLC images there | NEW (minor) | free | pick |
| `16a90a77` | Extends the tile read to samples at `gl_FragCoord.xy × 1/size`, with the uniforms proven at draw time (`fpos_proof`). Also reads inline uniform updates queued earlier in the submission, and fills the missing channels of R/RG attachments | NEW | after-M0, chain | pick (after 34459c91) |
| `85468b6c` | opt-in swap of a game's own agl NDSR upscaler dispatch for MetalFX's Metal 4 spatial scaler (`up_mfx_encode`, `DM_UPSCALER=metalfx`, launcher row, `game.py` upscaler keys); `rec_cb_block` lets MetalFX and DLSS encode on the encoding thread | NEW | after-M0 | port |
| `db8acc5c` | `pso_offline.py` streams the pipeline script to `.partial`, hashes the archive key as it encodes it, and frees the descriptors before metal-tt | NEW (low) | free | port (development.md union) |
| `84ec307f` | Mesh-path geometry draws that do not depend on order are collected into one dispatch through a draw table (`dm_mesh_run` twins in `dmsh_mesh.py`, `geo_mesh_take` / `geo_mesh_keeps`) | NEW | after-M0, chain | pick |
| `48888df5` | Mac: hold a controller's Home 2 s → ring "Keep holding to quit", then prompt "Quit <game>? Unsaved progress will be lost." (A quits as ⌘Q, B or Home cancels); game out of focus and gets no pad input while it is up; `DM_HOME_QUIT=0` off | NEW | after-M0 (`dm/host/Makefile` prerequisites; union with `stream_proto.h`) | port |
| `e2fadf22` | iOS: `DmLayout.h` lays the picture above the controls in portrait, on a half-folded iPhone Duo and in iPad windows (iPad drops `UIRequiresFullScreen`, all orientations); Fit/Fill picture (`DM_PICTURE_FIT`); the 2D/3D button becomes a gear menu with live Console mode / Picture / FPS counter / touch feedback / rumble; vibration handles also with rumble off | NEW | free | pick |
| `b2bdcbc9` | Age of Imprisonment `shader_seen.tsv` (15,445 keys) and a note: every boot starts at first-run settings because DATA.BIN is written only at autosave points | NEW (other game) | free | pick |
| `641d1480` | Ampere 0xf55 / 0xf56 (BMOV saving and restoring barrier B15 around SHFL blocks) become no-ops | NEW | chain | port (source + translator republish) |
| `56e4577b` | three fixes: (1) with present snapshots and a ticking link the acquire waits for the interval's ticks (hle_nvn.c); (2) `fb_pinned_level`: a sampler whose LOD clamp pins one level gets a view of that level alone in mip-chain feedback; (3) the segment draw count starts in `mtl_sub_begin` (`sub_cut_begin`) | NEW | after-M0 | pick |
| `c7ba23df` | indirect-count multi-draws above 1,024 recorded as one `OP_MULTI_DRAW` range and replayed whole through the GPU mask; captures relocate the range | NEW | after-M0 | large (hle_nvn.c conflict, capture format, 12 files) |
| `abd5ac2c` | `stage_resources.sh`: first copy of RomFS / shaders / AOC / PSO into the app is an APFS clone (`cp -c`), later builds rsync | NEW | after-M0 (`dm/ios/tools`) | pick |
| `cc4500c8` | iOS in-game menu: one compact text size, no section headings or value lines | NEW | free | pick |
| `ad7af9cb` | null checks for Metal buffers/bitmaps/events in tests from 85468b6c, 56e4577b, 48888df5; one lint baseline row removed | NO-VALUE | after-M0 | fold into those ports |
| `c94ce657` | LDC .IS / .ISL: run-time bank = the instruction's bank + Ra's high half. Candidates come from a scan of the decoded program (`ARuntimeBanks`: c1, the instruction's bank, every bank other constant reads name, never c0) | OURS | chain | port (only the c0 exclusion, in `ConstantBanksOf`) |
| `e2de8d39` | `t_upscaler_mfx` names the profile's first upscaler key (`DM_GAME_UPSCALER_KEYS`), not DK's shader, and skips profiles without one | NO-VALUE | after-M0 | fold into 85468b6c |
| `48d79ced` | BotW 1.9.0 renders a taller screen's own shape (`DM_SCREEN_ASPECT`, launcher "Picture shape", profiles with `screen_aspect on`): 1920x1344 output, wider fov stubs, HUD anchored to the taller edges (`duo_anchor.c`) | NEW | free (BotW is rewritten again: per-build patches) | pick |
| `2e804948` | BotW screen shape: the title menu backing and an NPC dialog backing at `DM_SCREEN_ASPECT=1.43` (`duo_anchor.c`, `patches.py`) | NEW (other game) | free | pick after 48d79ced |
| `b6e1f005` | ACNH screen shape: a `patches.py` (3.0.3 main) and `duo_anchor.c` for sizes, the camera FOV, the layout projection and edge widgets | NEW (other game) | free | pick after deps |
| `600c0b37` | the present reports the presented picture's shape (`front_picture_shape`); iOS layout and Mac mouse mapping use it instead of a fixed 16:9 | NO-VALUE | after-M0 | - |
| `cd7f3803` | `mtl_tex_release` walks a serial's descriptor list (`treg_retire_serial`) only when the serial was still live | NEW | after-M0 | pick |
| `c6e45e14` | `derive_profile` keeps in `modules` only those the version's ExeFS ships | NEW (minor) | free | pick |
| `d6a2808a` | uniform references in shader facts widened to slot << 16 and vec4 0..4095 (the whole 64 KB cbuf) for `uv_aff` and `frag_pos`; `ubo_float` takes `uint32_t` | NEW | after-M0 | port (uv_aff half) |
| `185b7dbf` | a bindless fragment shader counts as a reader of the depth attachment only when one of its TEXU handles names it (`fb_texu_reads`); pool handles, dynamic tables and TEXA still count | NEW | after-M0 | pick |
| `235eb516` | `nn::bluetooth` BLE calls answered offline (`InitializeBle` no session, events bound and never fired, scans and connects fail, lists empty) | NEW | free | pick |
| `acdeaeb1` | Movie decoder falls back to SDK 1's non-const `movie::Buffer` getters when the const ones are not exported | NEW | free | pick |
| `08a15900` | `vi::QueryDisplayBufferMaxResolution` answers, docked, the largest of 720p/1080p/1440p/4K the shown display holds (`front_display_pixels`, Mac and iOS), 1080p handheld; logs it once | PARTIAL | free | pick |
| `1e9e3df4` | `vi::OpenDisplay(out, "Default")` returns the host display, as `OpenDefaultDisplay` does | NEW | free | pick |
| `b7d7be11` | `ec` purchased-item notification offline: Initialize/Finalize no-ops, one persistent unsignalled event, Pop returns false | NEW | free (`dm/host/tests/Makefile` union) | port |
| `51574845` | The derived profile's header names the source profile by ID instead of by its absolute folder | NEW (minor) | free | pick |
| `230fe532` | RGBA4 takes the RGB565 family's conversion with all four nibbles reversed (uploads, copies, ReadTexels, readbacks, `rb_swap.metal`, `nvn_fmt_mtl.c` `SV`) | NEW | after-M0 | pick |
| `5a07ff2c` | Mac input box (`front_text_input`) up: the game window resigning key is not sent as out of focus (`g_text_box`) | NEW | free | pick (union with the fork's `g_window_visible` line) |
| `0fd9b1c8` | a frame-step probe's grace window repeats while its frames keep getting cheaper (`FSTEP_RAMP`, up to 180 frames; `DM_FSTEP_PROBE_RAMP=0` off) | NEW | after-M0 | pick |
| `f8c8e376` | `unityfs.py` learns the Unity 5.5 stripped-player Shader layout (hash 4496e93f) | NEW | after-M0 (touches `dm/gfx/tests`) | pick |
| `dfac27f5` | `account::LoadProfileImage` returns a plain 256x256 baseline JPEG (670 bytes) instead of failing with 0 bytes | NEW | free | pick |
| `998896ac` | The Mac app pack skips `._name` AppleDouble inputs, copies without xattrs, and strips the bundle before codesign | NEW (low) | free | pick |
| `fd14f3bc` | The GLSLC capture boot presses A every 4 s from 5 s (`GLSLC_KEYS`) | NEW (other games) | free | pick |
| `55fdf963` | A kept provisional profile packs the newest version in the folder, or stops with guidance when the profile does not describe it (`provisional_version`) | NEW (minor) | free | pick |
| `6a60b722` | When the profile names no capture files, an empty GLSLC capture passes if the offline split covers every shader key the capture boot submitted (`check_glslc_coverage`) | NEW (other games) | free | pick |
| `b3b38f4b` | fn+F toggles the Mac window to full screen from the key monitor (F no longer reaches the game) | NO-VALUE | free | — |
| `0b80fb6d` | `DM_PROBE_WATCH` / `DM_PROBE_POLL` take `heap+<offset>`, resolved when the game opens its heap | NEW | free | pick |
| `82246bd2` | `t_audio` drains every buffer a release event announces (a callback can finish several, wakes can merge) | NEW | free | pick |
| `442680db` | `ubo_read` copies bindless handles from the guest address (pools are no-copy wrappers) instead of `-[MTLBuffer contents]`; arena writes go through a kept CPU pointer | PARTIAL | after-M0 | port (`ubo_read` hunk only) |
| `6fc34217` | texture ID views valid per epoch: `ser_note` records which serial a `g_ser_gen` bump was about and `ser_sync` revalidates only that serial's IDs; a clean packaged texture keeps its view | PARTIAL | after-M0 | port (conflicts with `prog_serial_put` and `tex_rid_`) |
| `229fc22c` | a packaged sparse texture's CPU-write check (`nvn_sparse_since` → `vpt_walk`) runs once a submission (`NvPkg.sub`), and `run_written` keeps the dirty tracker's last range (`nvn_dirty_since_cached`) | PARTIAL | after-M0 | port (NvPkg ivars conflict: fork `sp` vs upstream `sub`) |
| `50363b14` | `texraw` (DM_CTL) saves every depth slice of a 3D texture, not only slice 0 | NEW (debug only) | after-M0 | pick |
| `d6b432e5` | `DM_FOCUS_KEEP=1`: the Mac front end does not report the window resigning key (minimizing still counts); `regress.py` sets it | NEW | free | pick (or 1-line port) |
| `0ad564a7` | Comment and an `audio.md` entry: `AcquireAudioOutputDeviceNotification` (SDK 21/22 name) also serves FE Fortune's Weave | DONE | free | pick (docs only) |
| `53ab7a9d` | Mesh-geometry runs (84ec307f) also take draws while samples-passed counting is on, because a report ends a run; each refusal reason is logged once | NEW (only with 84ec307f) | chain (through 84ec307f), after-M0 | pick once 84ec307f is in |
| `92f223a7` | An NVN texture whose alias key differs from a shared texture's only by the other half of an sRGB / linear pair becomes a Metal view of it (`srgb_twins`). A usage upgrade made through either one upgrades the parent and makes the view again; a stale view is dropped | NEW | after-M0 | port (tex_upgrade and the sparse branch of tex_mtl_ differ) |
| `5e62e207` | `vk_shaders.py` links its metallib with paths relative to the inputs' common folder | NEW (other games) | free | pick |
| `8f8b9d5a` | Renames ACNH `patches.py` helpers to lower case so `test_patches` does not read them as tables | NEW (with b6e1f005) | free | pick |
| `753fe273` | Rewriter: in a two-area split, `SPLIT` is no lower than `BACK_MIN`, so back-area sites stay within B's reach | NEW (other games) | free | pick |
| `1b94fab2` | fn (Globe) + a letter goes to the system, not the game: Globe-F full screen and other Globe shortcuts work in the game window | NEW | free | port (apply without b3b38f4b) |
| `620c68da` | Cheats' region 2 (alias) is the host's alias region (`svc_alias_range`), not heap − stack − profile alias | NEW | free | pick |
| `04ef91eb` | (1) A compute pipeline Metal refuses is remembered per shader and named. (2) The `IMAGE` flag keeps only uncompressed textures from taking their storage at first use. (3) `csh_dispatch_ahead`: the compute-hoist scan runs only when a dispatch follows (`DM_NVN_CSH_PRESCAN=0` for the old scan) | PARTIAL | after-M0 | port (2: one condition; 3: one function plus a call) |
| `9e757d07` | `shader_split.py` ignores `._` files in captured GLSLC and decoded Unreal shader folders | NEW (low) | free | port (development.md union) |
| `8148c343` | `uepak.py` reads version 8 paks (UE 4.22 to 4.25) | NEW (other game) | free | pick |
| `e2ab03aa` | Motion fusion rejects a non-finite accelerometer or gyro sample before it changes state; non-finite dt / gain neutralised; overflowing steps not committed | NEW | free | pick |
| `f3d8cf33` | `pack_app.py` writes `LSSupportsGameMode` true | NO-VALUE (alone) | free | pick only as cb59a672's base |
| `65cc2af4` | A PFS0 whose last name has no NUL is read: the NSP script bounds names by the string table, and nx_extract gives LibHac a virtual header | NEW (low) | free | pick |
| `b1c20372` | Rewriter: `tail_call_padded` accepts an unframed `ldr`/`ldp x18` thunk ending in `br x18` and followed only by `udf #0` as a tail call | NEW (other games) | free | pick |
| `6ddeda92` | `pso_offline.py --batch-size N`: metal-tt runs on groups of at most N bases, each group cached by key, then merged with metal-pack | NEW (tooling) | free (tool); after-M0 for t_pso_bundle.m | pick after db8acc5c |
| `de159bcb` | `attr_read` reads half2/3/4 positions and 8-bit indices, so the coverage proof (`first_draw_covers`) can prove more draws cover their target | NEW | after-M0 | pick |
| `e20888b4` | Lowers clang-tidy baseline counts that upstream's code no longer reaches | NO-VALUE | - | - |
| `4e5582eb` | A depth clear over the whole target, with a partial stencil mask and no pass open: the depth becomes the next pass's load action, and only the stencil is drawn as a triangle | NEW | after-M0 | pick |
| `8fc76577` | The pass number goes up before the render encoder begins, so GPU profiler rows carry the same label as the attachment and draw dumps | NEW (debug only) | after-M0 | pick |
| `79774e76` | Hooks the three `movie::Decoder` base-object constructors (C2) as the C1 ones | NEW | free | pick |
| `04923357` | unityfs.py: the Shader type tree of stripped Unity 2021.3 player files | NEW (another game only) | free (tool); after-M0 (test) | pick |
| `2670e6ad` | unityfs.py: the Unity 6000.3 Shader layout (version 4); one survey line in the NSP script | NEW (another game only) | free; after-M0 (tests) | pick |
| `ee01253d` | `profile_guess.py`: a main that imports nvnBootstrapLoader and `glslcCompile` and has GLSL sources and a GLSLC module is NVN, even when it links EGL | NEW (other games) | free | pick |
| `691e4775` | shader_split.py: MT Framework ARC v7 with 64-byte paths, and SPK with the control section first | NEW (another game only) | free; after-M0 (test) | pick |
| `e250bb8b` | Submit-thread CPU cuts: (a) `ubd_hits` / `ubd_covers` / `ubd_shadow` answers are kept per range until the list changes (`g_ubd_ver`), with a page bitmap over the guest window; (b) `prog_swrites`, `udc_note_draw`'s image write and `image_prepare`'s slots are cached on `NvProg`; (c) uncounted NVN trampolines unless `DM_NVN_COUNT=1` or a `DM_NVN_TSV` table asks for counts | NEW | after-M0 | port |
| `733dff9d` | The `COMPRESSIBLE` texture flag no longer keeps a texture out of `tex_init_fill` and `ft_add`, except in a CPU_NO_ACCESS pool | NEW (other games; general) | after-M0 | pick |
| `bd98317e` | Fixes a docs link in the COMPRESSIBLE entry | NO-VALUE (alone) | free | pick with 733dff9d |
| `45a3c987` | SDK 19 overloads: `fs::MountRom` and `QueryMountRomCacheSize` with a program index; `nvnTextureBuilderGetSwizzle` | NEW (another game only) | free (hle_fs.c); after-M0 (hle_nvn.c) | pick |
| `df7fa667` | `caps:su`, `caps:u`, `caps:a`, `caps:c`, `caps:sc`, `caps:ss` get host HIPC sessions in `hle_sf.c` (zeroed answers: empty album, no-op saves) | NEW | free | pick |
| `1d4b8e82` | MKW base-game bring-up. Shaders: task/mesh shaders (`shader_split` stages 6/7, ISBERD / 0x927 `AStageOut`, `dmsh_meshstage.py`, `DrawMeshTasks` through a Metal mesh pipeline), compute shared memory over 32 KB moved to a device buffer (`tg_spill`, `DMSH_TG_SLOT` 30), UP2UR with any mask, SURED.ADD.U32, integer entry point for a flat pass-through. Host: placement sparse textures of 64 MB and up, 512 MB pools in 16 MB chunks, a sparse mapping log, shading-rate calls accepted, SDK 19 decoder forms, `TryWaitSyncPointEvent`, per-build module lists, 1.8.0 services | PARTIAL | after-M0, chain (services free) | large (port the shader and mesh parts only) |
| `cb59a672` | `pack_app.py` writes `LSSupportsGameMode` false. A frame-rate.md entry records that macOS Game Mode holds the GPU at its lowest clock | NEW | free | port |
| `75e5ddd8` | Uncompressed 2D textures the CPU wrote, in a pool the GPU has not written (`pool_t.gpu_written`, set by render targets, texture clears, copies and downsamples into textures, image bindings), take their storage at first use. At the pool's first GPU write they become GPU textures again (`cpu_unc_drop`) | OURS | after-M0 | port (ideas) |
| `d361c5f8` | `dmsh_pch.py`: one precompiled header per compile convention, used through `-include-pch` by `dmsh_build.py` and `ios_metal.py`; libraries stay byte-identical | NEW | chain, after-M0 (`dm/ios/tools/ios_metal.py`) | pick (`docs/development.md` conflict) |
| `e07cba1c` | `first_store` recognizes more shapes of a first-invocation store: one guarded block a store, a local set to a constant, a local size with rows | NEW | chain | pick |
| `dd8eb14a` | Ampere translator tests: STS strides on 8- and 16-byte stores with offsets, BREV, HADD2 / HMUL2 on a live register; MKW froxel shaders as evidence for scaled shared-memory addresses | PARTIAL | after-M0 (tests) | port (add the four methods; the alu file conflicts add/add, keep the fork's) |
| `e556f7a1` | `dmsh_meshstage.to_stage` turns an unnamed kernel parameter into a `ValueError` (a refused shader) instead of a `TypeError` that stops the build; the Xcode fixture gets `modules_in` | NEW | chain | pick (with 1d4b8e82) |
| `a70f0718` | `CODE_FP` (the per-shader cache key) covers `dmsh_wide`, `dmsh_meshstage`, `dmsh_ampere` and `screen_varyings`; the chain version covers `dmsh_meshstage`; a test fails when an import is not accounted for | NEW (the `dmsh_ampere` part) | chain | port (one tuple entry + the test) |
| `02b0b662` | DualShock 4 rumble: the HID device is looked up in the IORegistry at each connect (`ds4_take`), not in a never-scheduled IOHIDManager from the first connect | NEW | free | pick |
| `c96a5dce` | NSP script `--seen-shaders` / `SEEN_SHADERS` for mac / mac-app (detail below the table); Pokopia gets `depth_mode zero` | PARTIAL | free | port (Pokopia README conflict with the `present_snap` row: keep both) |
| `a27d684b` | `realloc_or_die` for every growable table in nvn_mtl.m (27 sites), plus fixes for unchecked objects in tests; lint baseline 262 → 241 | NEW (hygiene, low) | after-M0 | port (the helper plus the fork's own sites) |
| `f2a50f35` | `dmsh_pch.compile` passes the MSL on stdin (`-x metal -`), so a library with function constants no longer depends on its file name | NEW (low) | free (`dmsh_mtlcache.py`, `dmsh_pch.py`; the chain version is unchanged) | pick |
| `a41b8054` | `test_shader_pch`: the fake `subprocess.run` requires stdin | NO-VALUE (alone) | free | pick with d361c5f8 |
| `cee65140` | `DM_UPSCALER=metalfx` reads each NDSR upscaler shader's colour handling from its code (`up_mfx_color`): linear in and out uses HDR mode, sRGB in and linear out uses perceptual mode with an sRGB view, and any other shape keeps the game's shader | NEW (only with 85468b6c) | after-M0 | pick with 85468b6c |
| `019a822d` | CI issue labels workflow and tools | NO-VALUE | - | - |
| `b6dbb851` | Mario Tennis Fever (Switch 2) profile plus host changes: `DM_NRO_CAPTURE` for an NRO decoded at run time, NRR version 1, `ro::Initialize` waits for started threads (`dm_thread_service_connect`), a minimum work buffer for font engines, the video decoder's ready event per taken packet (`CV_READY` 4, `CV_HOLD` 12), null vertex buffers past stream 16 ignored, no lean geometry path for a passthrough shader that writes the layer | NEW (another game; large) | after-M0 (hle_thread.c, dm/gfx/nvn) | large |
| `a4d7bb7b` | Kirby Star Allies port. Movie colour space (`nv12-colorspace`); `int_outputs` gives the mixed integer entry point (`main0_m`) only the outputs that really hold integers; a `[RED]` line when a float output meets an integer attachment; documents that a pipeline archive on an external drive is read into memory | NEW (other game) | after-M0, chain, free (movie) | port (README conflict; the profile is optional) |
| `eae1d0a0` | `snowdrop_pools.py` finds Snowdrop's three-pool allocator constructor by its structure, and the rewriter cuts it to the profile's `snowdrop_pools` sizes. Sparks of Hope's 64 KB pages go from 512 MB to 1.25 GB, and it adds `dual_want.tsv` | NEW (other games) | free | pick |
| `13da1c52` | `dmsh_side.py`: one Metal compile per pixel shader for its own, alpha-test (`_a`) and logic-op (`_l`) entry points, cut into `<key>_b` / `<key>_bx` that the host loads on first need | NEW | after-M0, chain | pick |
| `24a01b98` | DAVE THE DIVER profile; shader_split.py skips Unity compute kernels with empty code | NEW (another game only) | free; after-M0 (test) | pick |
| `5ccbeddb` | `g_red_once[153]` with a `_Static_assert` on the key; Python lint fixes in cra.py, shader_split.py and snowdrop_pools.py | NO-VALUE | - | - |
| `a3d85ae1` | Mario Tennis Fever gallery image | NO-VALUE | - | - |
| `4d5f0f52` | CI: a push to main does not cancel earlier runs | NO-VALUE | - | - |
| `0b8e0dc1` | Super Mario 3D All-Stars as one game of several programs: `oe::ExecuteProgram` restarts the host on the next program, `nn::jit` in MAP_JIT memory with iOS replay, offline HTML web view, Vulkan fixes, iOS per-program packing, Mac launcher | NEW (other games; large) | after-M0 (dm/host/Makefile, dm/ios/tools, dm/gfx/nvn) | large |
| `5061b2a1` | The Mac app is replaced by moves where `renamex_np(RENAME_SWAP)` gives ENOTSUP (HFS+, exFAT, FAT) | NEW (low) | free | pick |
| `d17e0ca5` | Lint fixes after the All-Stars commit: `jit_key_data` one-byte span TypeError, `jit_boot_done` closure | NO-VALUE (alone) | free | pick with 0b8e0dc1 |
| `7dc00e4d` | `files_with_suffix` finds `.NSP`, `.NSZ`, `.XCZ` and `.NUP` by lowercased extension. nsz gets a lowercase hard link or copy, and a folder named like a package no longer crashes the scan | NEW (low) | free | port |
| `c7da003c` | `test_architecture.py` fails on a game title ID in host code. `docs_patches.host_files()` also scans `.inc` | NEW (guard) | free | pick |
| `aafe01d3` | The Game language row shows when the packed game has no language list: `settings.py` offers every language with a note; the NSP script picks one `control.nacp` (`languages_control`) for the check, the Mac settings and `build_ipa.sh` (`CONTROL`) | NEW | free (settings.py); after-M0 (build_ipa.sh `CONTROL`) | port (settings.py + settings.tsv now; the rest when NUP lands) |
| `18b435ac` | M&L Brothership bring-up: `hle_audren.c` keeps per-renderer state (`ar_t`, `ar_of_sys`) so several renderers each get a thread and output; `shader_split` / `uepak` read inline shaders from UE 4.27 IoStore export bundles; `nx_extract` names a RomFS whose own tables fail the hash check (exit 3); the M&L profile | NEW | free (touch.tsv's chain=1 is the name `Program.cs`: this is `dm/tools/nx_extract/Program.cs`, not the translator) | pick (doc conflicts: README keep fork's, symptoms regenerate, shaders.md union) |
| `19a8574d` | `test_launcher_settings`: the helper returns rows by variable (pyright) | NO-VALUE | - | - |
| `abd7014b` | At each mount of a committed save, entries named by pre-7c23cc0 hosts (`\savedata0.bin`, `\dir\f`) are renamed to today's names (`save_old_names`) | NEW | free | pick |
| `ae031161` | `docs/frontends.md` "Following main", `Front-ends:` commit lines, PR template, AGENTS.md | NO-VALUE | - | - |
| `c0e150f3` | `pso_offline.py` compiles more than 1,000 bases in groups by default (merged with `metal-pack`; `--batch-size 0` = one run); a failed archive is a `[RED]` warning and the app packs without one | NEW | free (pso_offline.py, NSP script); after-M0 (build_ipa.sh) | port (with 6ddeda92) |
| `1110473c` | Placement sparse tiles shared by physical memory on upstream's own `NvSparse` (`sp_ph_*`, `nvn_sparse_tile_phys`). Drawn textures share too (every placement sparse texture has `allowGPUOptimizedContents = NO`). A drawn slot stays after its last place until its physical pool's Finalize (`mtl_sp_phys_gone`). An undrawn slot uploads again at each new place. Content is read from the physical address | OURS | after-M0 | port (ideas; a), b) need `allowGPUOptimizedContents = NO` measured on the Air) |
| `4447be11` | `scan_file_in` passes any `NARC` file to `scan_blob`, so packed members reach the cra reader | NEW (other game) | free | pick after b6dbb851 |
| `777a5f6c` | A NUP with no base record, or an empty base record, packs its newest standalone update. Control data comes from the metadata record | NEW (with 423a6745) | free | port (README keep the fork's; the MKW note line has no target in the fork) |
| `4e0333a5` | 120 fps for a profile with `fps_max 120`: the frame step counts in 1/120 s ticks, the game's target follows the hold, and the rate is capped at 60 below 120 Hz, during movies and under the thermal cap | NEW (other games; needs a 120 Hz screen) | after-M0 (hle_nvn.c, nvn_fstep.h, tests) | port |
| `02c91cd4` | README and the FE Fortune's Weave note: up to 120 fps in any version, because the host finds the frame rate in the game's code | NO-VALUE (alone) | free | pick with 0a05fb10 |
| `5ae0d9ae` | The task and mesh storage buffer tables are at c0 0x670 and 0x770, not 0x610 and 0x710 | NEW | after-M0, chain | pick (with 1d4b8e82) |
| `975bb4c1` | Upstream's MKW note: sky panels resolved on chain d5fe9ae8bfba | NO-VALUE (alone) | free | - |
