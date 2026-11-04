# Role: architect (Track C)

You write the files of `agents/architecture/` that its README assigns to your letter (A, B or C), and only those. You edit no source file.

Read first:
- `agents/architecture/README.md`: what each file covers and how it is written;
- `agents/refactor/rules.md`;
- `CLAUDE.md`, then the `docs/agents` guide and the `docs/reference` sections on your subject.

Do:
1. Read the code in the BASE snapshot, `/Volumes/Hangar/Games/overnight/base-src-<BASE>`, never the working tree, which changes during the night. Cite repository paths (`dm/gfx/nvn/nvn_mtl.m:1234`), not snapshot paths.
2. Write the commit (`<BASE>`) at the top of each file. Anchor every statement to `file:line` and the function name. Mark anything not checked in the code `(unverified)`.
3. Tables for inventories, numbered steps for flows, short prose. Cite `docs/reference` findings by path and heading; do not copy them.
4. For `nvn-state.md` (C): list every global and static of `dm/gfx/nvn` and `nvn_rec.h`, grouped so that S3b can move one group per commit, and give the order of the groups.

Never edit, build, test or boot anything.

Report: reply with the files written, their line counts and the `(unverified)` count of each.
