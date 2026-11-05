# Overnight brief: Ocarina of Time on the MacBook Pro

You are one of two autonomous agents working through the night while the owner sleeps. Do not ask questions: decide, write the decision down, continue. Codex is the implementer, Grok the driver and analyst; both read this whole brief.

The owner's goal: The Legend of Zelda: Ocarina of Time (Switch 2, title `0400486024DEC000`, update v131072) playable on Apple silicon through this repository's host. Tonight's machine is the MacBook Pro M1 8 GB; the owner plays on a MacBook Air M4 16 GB. Absolute speed here will be worse. What counts is what carries over: fixes that make the game correct, and changes that make it faster on any Mac, measured as before / after ratios on the same machine.

## Start

1. The SSD: `/Volumes/Hangar` (APFS, encrypted) holds the game, its build folder and its work folder. If it is not mounted, do only the work of the Fallback section and say so at the top of the board.
2. The code: clone `joaoalvess/horizon-nx2` (with `gh` or `git`, whichever is authenticated) into `~/Developer/horizon-zelda`, branch `zelda`. Codex creates `zelda-night` from it and is the only agent that commits.
3. Read, in this order: `agents/zelda/plan.md` (its Handoff section first, then the Boots table, then Open), `CLAUDE.md`, `docs/agents/README.md`, `docs/agents/03-bringup.md`, `docs/agents/06-dev-loop.md`, `docs/development.md` (building the host by hand, routes, `scripts/bench.py`). Search `docs/agents/symptoms.md` for the text of every failure before working on it.
4. Tools: Xcode is installed. Install the .NET SDK with Homebrew if `dotnet` is missing (the translator is C#). Make the Python venv on the SSD (`/Volumes/Hangar/venvs/nxnative`; packages: lz4, capstone, fontTools, zbic, nsz), not in the home folder.
5. Build a host on this machine (`docs/development.md`; `make -C dm/host GAME=0400486024DEC000` with `DM_GAMES_DIR=/Volumes/Hangar/Games/ZeldaOcarinaOfTime_v131072/0400486024DEC000_build/profile`) into a new folder `<work>/hosts/pro1/`. Do not overwrite the Air's hosts (`z1`-`z6`). If it fails to build or crashes with an illegal instruction, check the compiler's CPU flags.
6. First boot: does the game run here at all? The guest wants about 9 GB of memory and this Mac has 8 GB. Boot headless, muted, through the guard, for 300 s with a fresh save, with screenshots at frames 900, 1800 and 2700. If memory makes it impossible (swap growth stopped by the guard, a crash at allocation), find whether a host limit can be lowered without changing what the game does: a root cause, documented. Only then fall back.

## Running the game

- Work folder `<work>` = `/Volumes/Hangar/Games/ZeldaOcarinaOfTime_v131072/0400486024DEC000-work/`. Tonight's files go in `<work>/night/`: `board.md` (the shared state), `routes/`, `shots/`, `logs/`, `runs/`.
- The run scripts `<work>/run/b23.sh` and `<work>/run/play.sh` show the environment a boot needs (`DM_ROOT`, `DM_ROMFS`, `DM_SAVE`, `DM_TEMP`, `DM_MSL_DIR`, the shader libraries `MSL=<work>/xlate_fix/msl4`). They name the Air's host and checkout: copy them into `night/runs/` and fix the paths. Never edit the originals.
- Every boot: `DM_AUDIO=0`; a fresh save folder `night/runs/<run>/save`, never another run's and never `play/save` (the owner's own save); through `python3 /Volumes/Hangar/Games/overnight/heavy.py --boot <guard options> -- <command>`. Read `guard.py` for its options (`--game`, `--log`, `--max`, `--stall`, `--lock-wait`) and do not disable its limits. `heavy.py --boot` waits for 50 % free memory before it starts; if it waits more than 10 minutes, run it with `HEAVY_MEM_MIN=30`. One boot at a time. GPU work outside a boot (the Metal harnesses in `<work>/explore/`) takes the lock `<work>/explore/gpu.lock` (mkdir to take it, rmdir to release it).
- Input (`docs/agents/05-debugging.md`, Scripted input):
  - `DM_KEYS`: presses at seconds or frames from start, `f<frame>:<button>[+button][~hold]`, repeats with `*count/interval`.
  - `DM_CTL=<file>`: drives a running game. Append lines: presses, `shot <path>`, `passdump <n>`, `peek`, `memdump`.
  - `DM_REC`: records your physical input as `DM_KEYS` steps.
  - Button names are in `dm/host/hle_hid.c`.
- Pictures: `DM_NVN_SHOT=f1,f2,...:<path>_%d.png`, or `shot` lines through `DM_CTL`. Look at every screenshot you take and write in the board what you see: the menu or scene, missing or wrong geometry, black or pink areas, blocks, text.
- Speed: `DM_NVN_GPUPROF=every:600` gives the GPU time of each encoder; also read the log's `[longframe]` lines and the fps of its power lines. Compare medians of the same frames between two runs on this machine, alternating A and B: the machine slows as it warms.

## Goals, in order

1. **Reach gameplay.** The path is title movie, title screen, new game, file name, then the first playable area, walking around.
   - Explore step by step with `DM_CTL`: screenshot after each press, and choose the next press from the picture.
   - Once a stretch works, keep it as a frame-stamped `DM_KEYS` route in `night/routes/`.
2. **Fix every failure on the way** (a crash, a hang, a `[RED]` line, a wrong picture, an untranslated shader, a missing service) at its root cause, as `CLAUDE.md` and `docs/agents/` describe.
3. **Performance that carries over to the Air.**
   - Title movie: the plan lists what is left: `0a56002cdc7e1fce`, the upscaler and its 2560x1440 output against the 2048x1152 shown, and the storage slot sums, not yet measured in the game.
   - Gameplay: profile first, then work on the largest cost.
   - Prefer general changes (host, translator, chain) to game-specific ones.
4. **The handoff's pending steps for the storage slot sums**, with paths fixed for this machine: the Mario Kart World and Pokopia comparison, `exp_build5.sh`, `explore/slots/cmp5`, a measured boot.
   - The chain bump comes only after those pass. It rebuilds every Zelda library, which takes hours here.
   - Until then, boots keep the pinned experiment setup (`xlate_fix/dm4`, chain `7186a88fd701`).

## Roles

- **Codex (implementer):**
  - code changes, translator and host builds, shader rebuilds;
  - unit tests: `make -C dm/gfx/tests GAME=0400486024DEC000 <test>`, and `dm/gfx/tests/test_dmsh_*.py` with `DMSH_TEST_XLATE` set to a translator built from the sources;
  - commits on `zelda-night`.

  It takes tasks from the board and marks each done with its commit.
- **Grok (driver and analyst):**
  - boots, routes, screenshots and their analysis, GPU profiles;
  - triage: each problem goes to the board as a task with its evidence (log lines, frame, screenshot path) and, once found, its root cause.

  Grok does not edit the repository. It writes scripts only under `night/`.
- **`night/board.md`:**
  - a status block at the top, rewritten in place at each milestone, with times from `date`;
  - Tasks, one line each: id, owner, state, evidence, result;
  - a Log, appended.

  Each agent rewrites only its own lines. Before a long job, write in the board what it is and how long it should take.

## Rules

- **Root cause first.** Find the cause before changing code. A workaround is allowed only where the cause is known and cannot be fixed, and the code and the plan say so.
- **Per-game values** go in the profile, not in code.
- **The shader chain procedure** in `CLAUDE.md` applies to any change to the chain's tools.
- **Git:**
  - Commits are English conventional commits (`fix(shaders): ...`), small, with only the files of their item.
  - No Co-Authored-By and no attribution lines of any kind.
  - Push `zelda-night` to `origin` at each milestone. Never force-push. Never push to `main`, `refactor` or `zelda`.
- **The repository is public.** Never commit or upload:
  - game files or keys;
  - anything extracted from the game: shaders, MSL, metallibs, SPIR-V;
  - logs or screenshots of the game;
  - `docs/env_switches.tsv`, `PERF_M4.md`, `POKOPIA.md` or `STREAMING.md`.
- **Findings:**
  - A fact about this game goes in `agents/zelda/plan.md`: a row, rewritten in place.
  - A general mechanism goes in its `docs/reference/<subsystem>.md` entry, then run `python3 dm/tools/docs_symptoms.py`.
  - `dm/tools/tests/test_docs.py` must pass.
- **This Mac:**
  - Do not stop or touch the Docker containers it runs.
  - No IPA builds, no signing, nothing installed on devices.
  - Delete nothing on the SSD outside `night/` and your own build folders.
- **A GPU hang** (the display corrupts or flashes, WindowServer restarts, a kernel panic report): stop booting for the rest of the night, write down the last command and frame, and continue offline. Do not reboot.
- **Never stop for a question.** When a decision is the owner's, take the reversible choice, note it under "For the owner" in the board, and keep going.

## Fallback (no SSD, or the game cannot run here)

Offline work:
- translator correctness and its unit tests (`dm/gfx/tests`);
- the plan's open items, read in their code;
- GPU micro-benchmarks of the shader helpers.

Apple's simdgroup matrix layout was verified on the M4 only: run `dm/gfx/tests/test_dmsh_hmma.py` here before trusting any HMMA result on the M1.

## Morning report

Put it at the top of `night/board.md` and in your final message:
- the furthest screen reached, with its screenshot path;
- each problem found, with its cause and fix (commit);
- each measured gain: the A/B ratio, the frames, the shader or pass;
- what is still open;
- how the owner reproduces each result on the Air: `git fetch && git checkout zelda-night`, then the commands.
