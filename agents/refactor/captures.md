# Captures (S0 corpus)

The capture subagent is the only writer. It builds and checks the corpus as described in [roles/capture.md](roles/capture.md).

## Base binaries

| Game | BASE | Host | Replayer |
|---|---|---|---|
| Pokopia | `b0d98ee7` | `/Volumes/Hangar/Games/Pokopia_v2.0.1a/0400A3A01EE4C000-work/runs/hosts/base-b0d98ee7/dmhost` | `/Volumes/Hangar/Games/Pokopia_v2.0.1a/0400A3A01EE4C000-work/runs/hosts/base-b0d98ee7/nvn_replay` |
| DK | `b0d98ee7` | `/Volumes/Hangar/Games/DKBananza_v458752/040074A01BF12000-work/runs/hosts/base-b0d98ee7/dmhost` | `/Volumes/Hangar/Games/DKBananza_v458752/040074A01BF12000-work/runs/hosts/base-b0d98ee7/nvn_replay` |
| MKW | `b0d98ee7` | `/Volumes/Hangar/Games/MarioKartWorld_v1.0.0/0400C3F00006E000-work/runs/hosts/base-b0d98ee7/dmhost` | — |

## Captures

Files are in each game's `<work>/capture/` (`commands.md`). Noise: the most pixels any replay differed from the live frame by, over `--repeat 8` and `--warm 3`. Base replay CPU: filled by the main thread with the replayer's submit-instruction counter.

| Game | File | Frame | Content | Noise (px) | Base replay CPU (instructions a frame) | State |
|---|---|---|---|---|---|---|
| Pokopia | `pk_title_f2000.nvncap` | 2000 | Title screen: logo, photo card and text over a blurred 3D background | 0 | pending (new metric) | kept: 8 of 8 fresh replays and `--warm 3` bit-exact |
| Pokopia | `pk_tip_f3000.nvncap` | 3000 | Loading screen after the title: 2D banner with Ditto and a tip panel (text) | 0 | pending (new metric) | kept: 8 of 8 fresh replays and `--warm 3` bit-exact |
| Pokopia | `pk_world_f4200.nvncap` | 4200 | Outdoors, standing: the player, Pokémon, ruins and the HUD | 504,636 | pending (new metric) | dropped: `--repeat 8` exits 1. Every replay (8 fresh, 3 warm) differs from the live frame by the same 504,636 pixels (largest byte difference 80, the whole frame); the replays equal each other (digest `93fe5b8f…`) and the pools after the frame equal the live run's. Cause open (report) |
| DK | `dk_mine_f2700.nvncap` | 2700 | Opening cutscene: the mine entrance with the miner monkeys and sparks | 4,660,428 | pending (new metric) | dropped: the capture log has `[RED] DM_NVN_CAPTURE: texture ser=21325 512x512 format 194 samples 1: content not captured (format the capture cannot read back)` (ASTC 8x8 sRGB, a copy destination), and every replay differs from the live frame in 4,660,426-4,660,428 of 4,665,600 pixels (largest byte difference 222): the rock turns magenta in the replay, likely that texture: its replay copy is never filled, and an invalid ASTC block decodes to magenta (cause not proven); `--repeat 8` exits 1 |
