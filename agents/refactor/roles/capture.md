# Role: capture (S0, Track A)

You build the replay corpus with the base binaries. You edit no source file. In `agents/refactor/` you write only `captures.md`, where you are the only writer, and your reports.

Read first:
- `agents/refactor/rules.md`;
- `agents/refactor/commands.md`;
- `agents/refactor/captures.md`;
- the S0 row and the Oracles section of `agents/refactor/plan.md`;
- `docs/development.md`, section "Frame capture and replay".

Do:

1. **Use the base binaries** from the Base binaries table in `captures.md`, which the main thread fills at setup. Never use `dm/host/dmhost` from the tree: it changes during the night.
2. **Find the frames.** Make one discovery boot per game with `DM_NVN_SHOT` screenshots at fixed frames, and look at the pictures.
   - Pokopia: from a save copy, pressing `A` a few times at the title continues the save and reaches walking in about 110 s (`dm/games/0400A3A01EE4C000/README.md`, line 33). Aim for: title, world outdoors, world indoors, a menu, a UI-heavy screen.
   - DK: from a copy of `runs/save_empty`, use the `opening` route keys `15:A*10/3`. Aim for the opening cutscene (20-70 s) and the first scene.
3. **Capture.** One boot per frame through the guard (`--game pokopia` or `--game dk`, started with `run_in_background`, never killed), with the command in `commands.md`: `DM_NVN_CAPTURE=<frame>:1:<work>/capture/<tag>_f<frame>.nvncap`, `DM_PSO_HYBRID=0`, `DM_PSO_ARCHIVE=<work>/runs/pso_archive` and a fresh save copy made in `<work>/runs/`. Get at least 5 frames per game.
4. **Keep or drop.** Keep a capture only when:
   - its log has no `[RED] DM_NVN_CAPTURE` line;
   - `<base replayer> <cap> --repeat 8` exits 0. Frames with mesh draws also need a separate `--warm 3` run, since `--repeat` drops `--warm`. Replays run under the guard with `--game gfx`, after the boot has ended.

   For each kept capture, record its noise (the most pixels any replay differed by) and its base replay CPU (`commands.md`).
5. **Do not capture MKW.** Its sparse virtual pools are not capturable.

Boots go through the guard, one at a time. The main thread may be booting too; the guard's lock orders the two, so wait for it.

Report:
- Update `captures.md` one row at a time, as each capture is kept or dropped. Give a reason for each one dropped.
- At the end, write `agents/refactor/reports/<YYYYMMDD-HHMM>-S0-capture.md`.
- Reply `S0: <n> Pokopia, <n> DK kept`, followed by the report path.

If the harness refuses your report file, put the full report in your reply instead; the main thread saves it.
