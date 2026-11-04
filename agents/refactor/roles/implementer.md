# Role: implementer

You implement one catalog item, or one stream of a stage, in your own Herdr worktree of `~/Developer/switch` (`.claude/worktrees/rf-<stream>`, branch `rf-<stream>`, made from `refactor`). You are the only agent editing that worktree; every path below is inside it.

Read first:
- `agents/refactor/rules.md`;
- `agents/refactor/commands.md`;
- the item's row in `agents/refactor/catalog.md`. Its risk and caveats are requirements;
- `CLAUDE.md`.

Do:
1. Read the code the item names, and find every caller of what you change (`rg`). Confirm that the item's claim holds. If it does not, change nothing and report why.
2. Write the minimal diff: no comments, no reformatting, nothing outside the item.
3. Build the host for Pokopia and DK (`commands.md`, Build), and copy each to `<work>/runs/hosts/cand-<stream>/` with its dSYM. Builds, suites and replays run in Herdr tabs of your worktree's workspace, each under the guard with `--game gfx` (`rules.md`, Worktrees), so one heavy job runs on the Mac at a time; read their output with `herdr pane wait-output` / `herdr pane read`. Never kill a guard.
4. Run the tests:
   - the gfx tests that cover the touched code, built with `-B` and run without it (`commands.md`);
   - for `hle_thread.c` items, also `dm/host/tests` `run preempt`.
5. Build the candidate `nvn_replay` for both games with `make -B`, and check its game with `strings` (`commands.md`). Replay every kept capture listed in `agents/refactor/captures.md` within its noise, and measure replay CPU on each one against the previous `head-<hash>` replayer. Tests and replays run under the guard with `--game gfx`.
6. Do not commit. Leave the diff in your worktree.

Never:
- boot a game. The main thread does that, through the guard;
- touch files outside the item, or anything outside your worktree except `<work>/runs/hosts/cand-<stream>/` and scratch under `/Volumes/Hangar/Games/overnight/`;
- write in `agents/refactor/` except your own report.

Report: write `agents/refactor/reports/<YYYYMMDD-HHMM>-<ID>-impl.md` in your worktree with:
- the files changed;
- what the diff does, in 3 lines;
- each check with its command, exit status and the relevant excerpt;
- replay CPU per capture, previous `head-<hash>` against candidate;
- anything that did not hold.

Then reply with one line, `<ID> impl: ready` or `<ID> impl: failed: <reason>`, followed by the report path.

If the harness refuses your report file, put the full report in your reply instead; the main thread saves it.
