# Captures (S0 corpus)

The capture subagent was the only writer while it built and checked the corpus ([roles/capture.md](roles/capture.md)); it finished at 07:07 ([report](reports/20261104-0707-S0-capture.md)), and from then on the main thread writes this file.

## Base binaries

| Game | BASE | Host | Replayer |
|---|---|---|---|
| Pokopia | `b0d98ee7` | `/Volumes/Hangar/Games/Pokopia_v2.0.1a/0400A3A01EE4C000-work/runs/hosts/base-b0d98ee7/dmhost` | `/Volumes/Hangar/Games/Pokopia_v2.0.1a/0400A3A01EE4C000-work/runs/hosts/base-b0d98ee7/nvn_replay` |
| DK | `b0d98ee7` | `/Volumes/Hangar/Games/DKBananza_v458752/040074A01BF12000-work/runs/hosts/base-b0d98ee7/dmhost` | `/Volumes/Hangar/Games/DKBananza_v458752/040074A01BF12000-work/runs/hosts/base-b0d98ee7/nvn_replay` |
| MKW | `b0d98ee7` | `/Volumes/Hangar/Games/MarioKartWorld_v1.0.0/0400C3F00006E000-work/runs/hosts/base-b0d98ee7/dmhost` | — |

Captures from 05:25 on use the capture host `<work>/runs/hosts/base-b0d98ee7-cap/dmhost` (Pokopia and DK): BASE `b0d98ee7` plus only the R2 patch (`cap_pf_block` reads back the ASTC formats; replayer and file format unchanged). The replayer stays `base-b0d98ee7/nvn_replay`.

Keep or drop is settled with the R3 replayer `<work>/runs/hosts/cand-R3/nvn_replay --sdk-ounce 1` (06:42; it answers `dm_sdk_ounce()` for the replay). Every capture here predates R3's header field, and both games' live logs say `sdk: built for the Switch 2 (spec: Ounce)`. With the base replayer every Switch 2 frame that uploads textures from storage mismatched; the earlier rows are in the report.

## Captures

Files are in each game's `<work>/capture/` (`commands.md`). Noise: the most pixels any replay differed from the live frame by, over `--repeat 8` and `--warm 3`. Base replay CPU: the replay thread's submit instructions, median of replays 6-15 of `--warm 15`, median of two runs, with `base-b0d98ee7/nvn_replay_count` (BASE + R1 + R3), measured 08:15-08:54 (`night-2026-11-04.md`, interim summary).

Every replay of these captures passes `--sdk-ounce 1` (they predate R3's header field). The five DK opening captures replay nondeterministically (open, night file): they are kept within noise, with `--max-pixels` at about twice the noise measured over 11 replays. That still catches a broken frame (the R2 and R3 faults moved 0.3-4.7 M px) but not a change smaller than the threshold; for those, DK's bit-exact `dk_save` and Pokopia's seven captures are the oracle.

| Game | File | Frame | Content | Noise (px) | Base replay CPU (instructions a frame) | State |
|---|---|---|---|---|---|---|
| Pokopia | `pk_title_f2000.nvncap` | 2000 | Title screen: logo, photo card and text over a blurred 3D background | 0 | 5.73 M | kept: 8 of 8 fresh replays and `--warm 3` bit-exact (`439211fc…`); also exact with the base replayer |
| Pokopia | `pk_tip_f3000.nvncap` | 3000 | Loading screen after the title: 2D banner with Ditto and a tip panel (text) | 0 | 5.85 M | kept: 8 of 8 and `--warm 3` bit-exact (`a1b8cc57…`); also exact with the base replayer |
| Pokopia | `pk_ditto_f1050.nvncap` | 1050 | Boot loading screen: black with the animated Ditto icon at the bottom right (`base-b0d98ee7-cap`) | 0 | 1.44 M | kept: 8 of 8 and `--warm 3` bit-exact (`c378a721…`); also exact with the base replayer |
| Pokopia | `pk_world_f4200.nvncap` | 4200 | Outdoors, standing: the player, Pokémon, ruins and the HUD (base host, before 05:25) | 0 | 29.20 M | kept: 8 of 8 and `--warm 3` bit-exact (`51739736…`). With the base replayer every replay differed by 504,636 pixels: the replay deswizzled CPU-written textures with the Switch 1 GOB order (first: ser 8175, the 4x4 SSAO noise texture), fixed by R3 (report) |
| Pokopia | `pk_walk_f5030.nvncap` | 5030 | Outdoors, walking forward: the player by the ruins, the HUD (`base-b0d98ee7-cap`) | 0 | 29.41 M | kept: 8 of 8 and `--warm 3` bit-exact (`048c3450…`); base replayer 606,718 pixels (the R3 cause) |
| Pokopia | `pk_menu_f5550.nvncap` | 5550 | The main menu over the world: Pokédex app grid, the area map, the clock (`base-b0d98ee7-cap`) | 0 | 27.47 M | kept: 8 of 8 and `--warm 3` bit-exact (`1b5f041b…`); base replayer 324,022 pixels (the R3 cause) |
| Pokopia | `pk_bag_f6250.nvncap` | 6250 | The item bag panel over the world: berries, items, the button bar (`base-b0d98ee7-cap`) | 0 | 26.80 M | kept: 8 of 8 and `--warm 3` bit-exact (`cb8388df…`); base replayer 383,723 pixels (the R3 cause) |
| DK | `dk_save_f600.nvncap` | 600 | Boot: the autosave notice, white text and the banana icon on black (`base-b0d98ee7-cap`) | 0 | 6.19 M | kept: 8 of 8 and `--warm 3` bit-exact (`544d5d9b…`, the live digest). Before R2 the capture lacked an ASTC 8x8 texture (`[RED] DM_NVN_CAPTURE … format the capture cannot read back`); with R2 and the base replayer the banana icon still differed (1,096 pixels), so the icon was the R3 cause |
| DK | `dk_isle_f1800.nvncap` | 1800 | Opening cutscene: Ingot Isle from the sea under the moon, searchlights (`base-b0d98ee7-cap`) | 4,429 | 40.47 M | kept within noise (07:10, main thread): replays with `--max-pixels 10000`. The capture subagent dropped it: `--repeat 8` exits 1: 5 of 8 fresh replays are exact, the other 3 and the warm ones differ by 841-4,429 pixels (5 digests in 11 replays): the replay is not deterministic (open). The frame makes RG11B10 2304x1296 ser 4624 with no captured content |
| DK | `dk_neon_f2100.nvncap` | 2100 | Opening cutscene: the Ingot Isle neon sign on the mountain, the moon and searchlights (`base-b0d98ee7-cap`) | 1,314 | 56.65 M | kept within noise (07:10, main thread): replays with `--max-pixels 3000`. The capture subagent dropped it: `--repeat 8` exits 0 (8 of 8 fresh replays exact) but `--warm 3` exits 1: warm replays 2 and 3 differ by 1,314 pixels. Ser 4624 (no captured content) is the one texture a warm replay does not restore (report) |
| DK | `dk_cliff_f2400.nvncap` | 2400 | Opening cutscene: a rock pillar in smoke, miners and a barrier, the moon (`base-b0d98ee7-cap`) | 4,556 | 67.62 M | kept within noise (07:10, main thread): replays with `--max-pixels 10000`. The capture subagent dropped it: `--repeat 8` exits 0 (8 of 8 exact) but `--warm 3` exits 1: warm replays 2 and 3 differ by 4,556 pixels (as `dk_neon`) |
| DK | `dk_mine_f2700.nvncap` | 2700 | Opening cutscene: the mine entrance with the miner monkeys and sparks (`base-b0d98ee7-cap`) | 6,953 | 60.92 M | kept within noise (07:10, main thread): replays with `--max-pixels 14000`. The capture subagent dropped it: `--repeat 8` exits 1: 4 of 8 fresh replays are exact, the rest and the warm ones differ by 1,704-6,953 pixels (3 digests): not deterministic (open) |
| DK | `dk_ypunch_f3300.nvncap` | 3300 | First scene: DK inside dark rock, the `Y Punch` prompt (`base-b0d98ee7-cap`) | 13 | 26.99 M | kept within noise (07:10, main thread): replays with `--max-pixels 100`. The capture subagent dropped it: `--repeat 8` exits 1: no replay is exact; each differs by 3-13 pixels and no two agree (11 digests in 11 replays); after the frame 7 pool blocks are written only in the replay (open) |

## Replay CPU, base against HEAD

08:15-08:54, `base-b0d98ee7/nvn_replay_count` against `head-25446564/nvn_replay` (S1, R1-R3, C7), `--sdk-ounce 1 --warm 15` with the `--max-pixels` above, alternating base, HEAD, base, HEAD. Each cell is the median of replays 6-15 of one run, in submit instructions of the replay thread; the last columns are the median over both runs. Per-item checks compare against the HEAD columns.

| Capture | base 1 | base 2 | HEAD 1 | HEAD 2 | HEAD vs base (median of runs) | process instr. base / HEAD | all replays match |
|---|---|---|---|---|---|---|---|
| pk_title_f2000 | 5.61 M | 5.85 M | 5.34 M | 5.82 M | -2.6 % | 5.91 / 5.75 M | yes |
| pk_tip_f3000 | 6.08 M | 5.62 M | 5.17 M | 5.20 M | -11.3 % | 6.03 / 5.37 M | yes |
| pk_ditto_f1050 | 1.41 M | 1.46 M | 1.47 M | 1.41 M | +0.5 % | 1.54 / 1.55 M | yes |
| pk_world_f4200 | 28.57 M | 29.83 M | 27.38 M | 28.20 M | -4.8 % | 34.24 / 32.71 M | yes |
| pk_walk_f5030 | 29.66 M | 29.16 M | 28.09 M | 26.39 M | -7.4 % | 36.27 / 34.53 M | yes |
| pk_menu_f5550 | 28.49 M | 26.46 M | 26.24 M | 26.18 M | -4.6 % | 33.78 / 33.58 M | yes |
| pk_bag_f6250 | 26.77 M | 26.83 M | 25.90 M | 25.20 M | -4.7 % | 33.74 / 32.17 M | yes |
| dk_save_f600 | 6.19 M | 6.19 M | 6.00 M | 6.00 M | -3.0 % | 10.46 / 10.28 M | yes |
| dk_isle_f1800 | 40.48 M | 40.47 M | 38.84 M | 38.85 M | -4.0 % | 96.90 / 93.96 M | yes |
| dk_neon_f2100 | 56.77 M | 56.52 M | 55.10 M | 54.60 M | -3.2 % | 86.31 / 84.32 M | yes |
| dk_cliff_f2400 | 67.50 M | 67.74 M | 65.61 M | 65.19 M | -3.3 % | 105.68 / 103.12 M | yes |
| dk_mine_f2700 | 60.82 M | 61.01 M | 58.77 M | 58.63 M | -3.6 % | 96.46 / 97.14 M | yes |
| dk_ypunch_f3300 | 26.99 M | 26.99 M | 25.70 M | 25.68 M | -4.8 % | 61.58 / 60.20 M | yes |
