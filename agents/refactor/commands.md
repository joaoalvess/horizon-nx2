# Commands

Game IDs and the guard's `--game` names (use these literal names, so a `STOP_<name>` file stops every agent that boots that game):
- Pokopia: `0400A3A01EE4C000`, guard name `pokopia`. Work folder `/Volumes/Hangar/Games/Pokopia_v2.0.1a/0400A3A01EE4C000-work`, build folder `.../0400A3A01EE4C000_build`.
- DK: `040074A01BF12000`, guard name `dk`. Work folder `/Volumes/Hangar/Games/DKBananza_v458752/040074A01BF12000-work`, build folder `.../040074A01BF12000_build`.
- MKW: `0400C3F00006E000`, guard name `mkw`. Work folder `/Volumes/Hangar/Games/MarioKartWorld_v1.0.0/0400C3F00006E000-work`, build folder `.../0400C3F00006E000_build`. Every MKW `make` needs `DM_GAMES_DIR=/Volumes/Hangar/Games/MarioKartWorld_v1.0.0/0400C3F00006E000_build/profile`.
- GPU tests and replays outside a boot: guard name `gfx`.

## Long commands

- A Bash call stops at 120 s by default and 600 s at most. Run every `guard.py` call, every build of more than a few files and every full test suite with `run_in_background`, and wait for its notification.
- Never kill a guard. The game runs in its own session (`guard.py` line 82), so a killed guard leaves `dmhost` running unguarded. After any guard that was cut off, check `pgrep -x dmhost`; a survivor gets `kill`, then `STOP_ALL` if it survives that.

## Build

- Host: `make -C dm/host GAME=<id> dmhost`. It writes one `dm/host/dmhost`, for the last game built. Copy each one to `<work>/runs/hosts/<name>/dmhost`, with its dSYM.
- Replayer: `make -B -C dm/gfx/tests GAME=<id> nvn_replay`. `-B` is required: the target has no game stamp, so without it a second game keeps the first game's binary. Check it with `strings -a dm/gfx/tests/nvn_replay | grep -x <id>` before copying it to `<work>/runs/hosts/<name>/nvn_replay`.
- Per-commit binaries: after each commit on `refactor`, while the tree is clean, the main thread builds and copies the host and the replayer of Pokopia and DK to `<work>/runs/hosts/head-<hash>/`. Implementers compare against the previous `head-<hash>`, boots use these copies, never `dm/host/dmhost`.
- Graphics tests: the rules that include `nvn_mtl.m` do not list it as a dependency, so build with `-B`, and run without it (`-B` passes into the nested `check_*` makes and builds everything twice):
  - one test: `make -B -C dm/gfx/tests GAME=<id> t_x`, then `make -C dm/gfx/tests GAME=<id> check_t_x`. Naming `t_x` only builds it;
  - the suite, through `bash -c` (under zsh the `$(...)` list reaches make as one word): `make -k -B -j4 -C dm/gfx/tests GAME=<id> $(cd dm/gfx/tests && ls t_*.c t_*.m | sed 's/\.[cm]$//' | grep -vxE 't_host_stubs|t_present_rescue_focus|t_atomic_return|t_geometry_primitive_id|t_gpuprof')` (the `RUN_TESTS` list of the Makefile, `NOT_RUN` left out), then the checks with `make -k -j1 -C dm/gfx/tests GAME=<id> check_<each> check_test_dmsh_pull check_test_tbdr_budget` (`make run` stops at BASE: `t_gfx_suspend` and `t_nvn` do not link there, see the night file's Open);
  - Both under the guard with `--game gfx` when no boot is running, in the background.
- Host tests: after any change of flags, `rm -rf dm/host/tests/build` first (no target depends on the Makefile). Then `make -C dm/host/tests GAME=<id> run preempt`.
- Sanitizers: `make -C dm/host/tests GAME=<id> asan` (ASan + UBSan, in its own folder). The gfx tests have no sanitizer hook.

## Replay

- Check a capture: `<replayer> <capture> --repeat 8 [--max-pixels <noise>]`.
  - Exit 0: within noise.
  - Exit 1: the frame differs.
  - Exit 2: this build cannot replay the capture (also: a replayer built for another game).
- Mesh frames: also `<replayer> <capture> --warm 3` as a separate run. `--repeat` does not pass `--warm` to its children (`nvn_replay.m` 204-210). The exit status of `--warm` also counts the first replay.
- Replay CPU: `/usr/bin/time -l <replayer> <capture> --warm 9`, take the `instructions retired` line, subtract the same with `--warm 1`, divide by 8. Report it per capture against the previous `head-<hash>` replayer (the base replayer only in the summaries).
- Replays run under the guard with `--game gfx`, never during a boot.

## Capture

```
python3 /Volumes/Hangar/Games/overnight/guard.py --game pokopia|dk --log <log> --max <s> -- \
  <work>/runs/run_pk.sh|<work>/runs/run_dk.sh <host> DM_AUDIO=0 DM_PSO_HYBRID=0 DM_SAVE=<fresh copy> \
  DM_PSO_ARCHIVE=<work>/runs/pso_archive \
  DM_NVN_CAPTURE=<frame>:1:<work>/capture/<tag>_f<frame>.nvncap [DM_KEYS=...] [DM_NVN_SHOT=<frame>,<frame>:<path with %d>]
```

- One frame per boot.
- `<work>/runs/pso_archive` is a clone of the build's `run/pso_archive` made at setup. Never point `DM_PSO_ARCHIVE` at the build's own archive: a run writes into it. Without the variable the archive sits beside the save copy and starts empty.
- A capture is game data: it stays in the work folder.
- The format and its limits are in `docs/development.md`, section "Frame capture and replay".

## Boots

- Boot check: 120 s through the guard, with the per-commit host, a fresh save copy and `DM_NVN_SHOT=<frames>:<work>/shots/<name>/f%d.png` at the frames of the base boots (`DM_NVN_SHOT` takes frame numbers, not seconds), then compare the pictures with the base ones in `<work>/shots/base/`.
- Pokopia and DK boot through `run_pk.sh` / `run_dk.sh` (above).
- MKW boots only for the HT items: `python3 /Volumes/Hangar/Games/overnight/guard.py --game mkw --log <log> --max 120 -- env DMHOST=<host> <MKW work>/run/boot.sh DM_AUDIO=0 DM_WINDOW=1 DM_SAVE=<fresh cp -cR of <MKW work>/run/save>`.
- `DM_NVN_CPUPROF=1` gives renderer CPU totals by operation. Use it for diagnosis; the measurement is replay CPU.

## Bench

```
python3 /Volumes/Hangar/Games/overnight/guard.py --game dk --log <log> --max 1500 --scan '<out>/*/log.txt' -- \
  python3 scripts/bench.py /Volumes/Hangar/Games/DKBananza_v458752/040074A01BF12000_build --route opening \
  --save <DK work>/runs/save_empty --pso-archive <DK work>/runs/pso_archive \
  --variant base:host=<work>/runs/hosts/base-<BASE>/dmhost --variant head:host=<work>/runs/hosts/head-<hash>/dmhost \
  --out <DK work>/bench/<ts>
```

- Never the default `--save` (the user's `run/save`).
- bench.py alternates the variants. Compare runs with a similar `pcore`.
- Submit CPU is `@sub_cpu_ms` in each run's `frames.tsv`; bench.py does not print it.
