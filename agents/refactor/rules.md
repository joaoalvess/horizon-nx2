# Rules

Every agent follows these rules. They come from the user, `CLAUDE.md` and incidents on 2026-11-02/03.

## Boots

- Every boot goes through `/Volumes/Hangar/Games/overnight/guard.py --game <name> --log <log> --max <s> -- <command>`, with the literal names of `commands.md` (`pokopia`, `dk`, `mkw`).
  - One boot at a time: the guard holds `state/boot.lock`.
  - Muted: `DM_AUDIO=0`.
  - Started with `run_in_background`, never in a foreground Bash call, and never killed (`commands.md`, Long commands).
- GPU tests and replays run under the guard with `--game gfx`, never while a game boots.
- If `memory_pressure | tail -1` shows under 30 % free, wait.
- No shader build during a measured boot.
- Only the main thread and the capture subagent boot games.
- Saves:
  - Use a fresh `cp -cR` copy for every boot: of `runs/save_agent` (Pokopia) or `runs/save_empty` (DK).
  - Never boot on `0400A3A01EE4C000_build/run/save` (the user's), `0400A3A01EE4C000-work/saves/esposa` (their wife's) or `040074A01BF12000_build/run/save`.

## GPU errors

- When the guard stops a game for a GPU error, it writes `STOP_<game>`. No boot of that game until the cause is found offline; then delete the file and write the cause down.
- Before blaming the game, look for the guilty process:
  - `log show --last 2h --predicate 'eventMessage CONTAINS "Caused GPU Hang"'`;
  - `/Library/Logs/DiagnosticReports/gpuEvent-*.ips`.

  On 2026-11-03 the culprit was an AirPlay mirror.
- A hang the guard contains does not stop the night.
- `STOP_ALL` is written when the game survives the kill, or after three GPU errors in an hour. It stops all boots until the user clears it; offline work goes on.

## Code

- Find the root cause before changing code (`CLAUDE.md`). A workaround is acceptable only as `CLAUDE.md` allows, and is written down as one.
- Minimal diffs, exactly the item's scope:
  - no comments;
  - no reformatting;
  - no removal of existing comments.
- Prefer a general fix to a game-specific rule.

## Git

- Work on branch `refactor`, created from `main`.
- Commits are local, in English: `perf(<scope>): <what>`, `build(<scope>): ...` or `docs(agents): ...`. No Co-Authored-By and no Claude attribution.
- `git add` names each file.
- Never commit `docs/env_switches.tsv`, `PERF_M4.md`, `POKOPIA.md` or `STREAMING.md` (the user's uncommitted work).
- A file in `agents/refactor/` is committed together with the item whose state it records, or at a milestone.
- An item that fails before its commit is dropped this way, the only checkout allowed: `git diff -- <its files> > /Volumes/Hangar/Games/overnight/patches/<ID>.patch`, then `git checkout -- <its files>`. A committed item that fails later leaves through `git revert`.
- Never:
  - push;
  - `git reset --hard`, `git clean -f`, or force anything;
  - create worktrees;
  - rewrite commits on `main`.

## Machine

- The Mac runs on AC power with the lid open: `pmset -g batt` shows `AC Power` before setup. On battery, `caffeinate -s` does nothing and the run stops when the battery runs out.
- Never sign builds, install on devices, run `eas` or deploy, or reboot.
- Never print keys.
- Game data stays in `/Volumes/Hangar`, never in the repository or the home folder.
- No large data in the home folder.

## Subagents

- One agent edits source files at a time. Reviewers and searchers are read-only and may run in parallel.
- A subagent writes only its own report under `reports/` (and `captures.md` for the capture subagent). Status files have one writer, the main thread.
- A reviewer gets the diff and the code, never the implementer's reasoning.
- The night file is the plan the user asked to run on 2026-11-04, and the local commits on `refactor` it lists are requested. Nobody asks the user anything during an unattended run. A decision that belongs to the user goes under Open in the night file, and work moves on.
