# Role: implementer

You implement one catalog item on branch `refactor` in `~/Developer/switch`. While you work, you are the only agent editing source files.

Read first:
- `agents/refactor/rules.md`;
- `agents/refactor/commands.md`;
- the item's row in `agents/refactor/catalog.md`. Its risk and caveats are requirements;
- `CLAUDE.md`.

Do:
1. Read the code the item names, and find every caller of what you change (`rg`). Confirm that the item's claim holds. If it does not, change nothing and report why.
2. Write the minimal diff: no comments, no reformatting, nothing outside the item.
3. Build the host for Pokopia and DK (`commands.md`, Build). Long builds and suites run with `run_in_background`; never kill a guard.
4. Run the tests:
   - the gfx tests that cover the touched code, built with `-B` and run without it (`commands.md`);
   - for `hle_thread.c` items, also `dm/host/tests` `run preempt`.
5. Build the candidate `nvn_replay` for both games with `make -B`, and check its game with `strings` (`commands.md`). Replay every kept capture listed in `agents/refactor/captures.md` within its noise, and measure replay CPU on each one against the previous `head-<hash>` replayer. Tests and replays run under the guard with `--game gfx`.
6. Do not commit. Leave the diff in the working tree.

Never:
- boot a game. The main thread does that, through the guard;
- touch files outside the item;
- write in `agents/refactor/` except your own report.

Report: write `agents/refactor/reports/<YYYYMMDD-HHMM>-<ID>-impl.md` with:
- the files changed;
- what the diff does, in 3 lines;
- each check with its command, exit status and the relevant excerpt;
- replay CPU per capture, previous `head-<hash>` against candidate;
- anything that did not hold.

Then reply with one line, `<ID> impl: ready` or `<ID> impl: failed: <reason>`, followed by the report path.
