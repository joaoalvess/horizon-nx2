# Commands

Game IDs and the guard's `--game` names (use these literal names, so a `STOP_<name>` file stops every agent that boots that game):
- Pokopia: `0400A3A01EE4C000`, guard name `pokopia`. Work folder `/Volumes/Hangar/Games/Pokopia_v2.0.1a/0400A3A01EE4C000-work`, build folder `.../0400A3A01EE4C000_build`.
- DK: `040074A01BF12000`, guard name `dk`. Work folder `/Volumes/Hangar/Games/DKBananza_v458752/040074A01BF12000-work`, build folder `.../040074A01BF12000_build`.
- MKW: `0400C3F00006E000`, guard name `mkw`. Work folder `/Volumes/Hangar/Games/MarioKartWorld_v1.0.0/0400C3F00006E000-work`, build folder `.../0400C3F00006E000_build`. Every MKW `make` needs `DM_GAMES_DIR=/Volumes/Hangar/Games/MarioKartWorld_v1.0.0/0400C3F00006E000_build/profile`.
- GPU tests and replays outside a boot: guard name `gfx`.

## Long commands

- A Bash call stops at 120 s by default and 600 s at most. Run every `guard.py` call, every build of more than a few files and every full test suite with `run_in_background`, and wait for its notification.
- Never kill a guard. The game runs in its own session (`guard.py` line 82), so a killed guard leaves `dmhost` running unguarded. After any guard that was cut off, check `pgrep -x dmhost`; a survivor gets `kill`, then `STOP_ALL` if it survives that.
- Heavy jobs: `python3 /Volumes/Hangar/Games/overnight/heavy.py [--boot] <guard options> -- <command>` (`rules.md`, Worktrees): the guard, then a wait for 45 % free memory (50 % with `--boot`), then the command, at background priority unless `--boot`. `HEAVY_MEM_MIN` overrides the threshold.
- To stop a guarded run early (the guard reads `STOP_*` only before it starts): find the child as the guard's direct child, `pgrep -P <guard pid>`, and `kill -TERM -- -<child pgid>`. Never pick it by `pgrep -f` with the command's text: the guard's own command line contains it (2026-11-04 17:10, a DK bench: that killed the guard, and the orphaned `bench.py` and `dmhost` had to be stopped by hand).

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

- Replayers from R3 on refuse a capture without its Switch 2 keys (exit 2) unless given `--sdk-ounce 0|1`. Every capture of the corpus predates R3 and both games are Switch 2 builds, so every replay below passes `--sdk-ounce 1`; the DK opening captures also pass their `--max-pixels` from `captures.md`. Replayers before R3 (`head-*` up to `head-59d2272e`, `nvn_replay_count_r1`, `cand-C7`, `cand-P2`) reject the option and replay Switch 2 frames wrong: do not use them for the corpus.
- Check a capture: `<replayer> <capture> --sdk-ounce 1 --repeat 8 [--max-pixels <noise>]`.
  - Exit 0: within noise.
  - Exit 1: the frame differs.
  - Exit 2: this build cannot replay the capture (also: a replayer built for another game).
- Mesh frames: also `<replayer> <capture> --warm 3` as a separate run. `--repeat` does not pass `--warm` to its children (`nvn_replay.m` 204-210). The exit status of `--warm` also counts the first replay.
- Replay CPU (item R1): `<replayer> <clone of the capture> --sdk-ounce 1 --warm 15`, under the guard with `--game gfx`, on an APFS clone (`cp -c` into `/Volumes/Hangar/Games/overnight/rp-tmp/`: a replay writes PNGs beside the capture). The metric is the median `submit instructions` of replays 6-15 (replays 1-4 still build pipelines); on DK also report `process instructions` (the encode thread's share). Warm replays still vary 4-22 %, so one run resolves about 5 % on DK and 10 % on Pokopia: compare candidate and previous `head-<hash>` (the base replayer `<work>/runs/hosts/base-b0d98ee7/nvn_replay_count`, BASE with R1 and R3, in the summaries) with two runs each, alternating, and call a change only beyond the spread. `/usr/bin/time -l` totals measure the state restore, not translation: do not use them. Blind spots (R1 review): work the submit causes off the span (feedback handlers and deferred releases during `mtl_finish`, background pipeline builds) is not counted, so an item that moves work there looks like a win: say so when an item does; the `ubc_wait` busy-spin (`nvn_rec.h:40-48`) is counted, so a faster submit thread can show more instructions (control: repeat with `DM_NVN_UB_COPY_THREAD=0`).
- Replays run under the guard with `--game gfx`, never during a boot.
- Per item (from 06:25; the guard's lock is the night's bottleneck): replay each kept capture once with `--warm 15` on a clone. All 15 replays must match within the capture's noise (this replaces `--repeat 8` for items), and the median `submit instructions` of replays 6-15 is compared with the previous `head-<hash>` value recorded in `captures.md` only to catch a regression beyond the spread. The two-run base-against-HEAD comparison is made at the milestones (every 4 kept items) and before each summary.

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
- DK gameplay (the user's idea, 2026-11-04): `bootkeys.sh`'s keys plus Y presses after the "Y Punch" prompt, `DM_KEYS=f750:A~f9*10/180,f5400:Y~f6*40/45`, `--max 200`, shots from frame 5400. It breaks the wall into "Explore the mining tunnel" by frame 6600: about 5,400 draws and 50 M submit instructions a frame, against 944 and 13.7 M at the prompt.
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
