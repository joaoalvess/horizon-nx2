# Upstream ideas

Since 2026-11-04 the fork no longer syncs with `seedds/nxnative` (`CLAUDE.md`, Branches). This folder maps what upstream does from that point on. A change worth having is re-implemented on the fork's own code, checked on the games and joined through a pull request.

| File | What | Writer |
|---|---|---|
| `nxnative.md` | the map: the last upstream commit mapped, a verdict for each commit, and the picks with their state | the session that runs a round |

## A round

1. Update the reading clone: `git -C /Volumes/Hangar/nxnative pull --ff-only`. The clone exists only for reading; this repository has no `upstream` remote.
2. List the commits after `nxnative.md`'s "Mapped up to": `git -C /Volumes/Hangar/nxnative log --reverse --format='%h %s' <mapped>..main`.
3. Subagents read the commits in batches (shader chain, NVN layer, host and front ends, tools, profiles and docs) against the current `refactor`, read only. Each commit gets one verdict:
   - **NEW**: it adds something the fork lacks.
   - **PARTIAL**: the fork has part of it.
   - **DONE**: the fork already has it.
   - **OURS**: the fork did the same thing its own way, which it keeps; ideas missing from its version are named.
   - **NO-VALUE**: CI, a gallery, upstream's own process, or nothing the fork can use.
4. An independent reviewer tries to refute the claims behind the picks before any is chosen.
5. Each pick is re-implemented with its tests and goes to `refactor` in a pull request, one commit per upstream idea. The pull requests are grouped by when they can join: at any time, after the refactor's M0 (the frozen paths in `agents/refactor/plan.md`), or with a shader chain change. A pick is measured on the games it claims to help before it joins; when its pull request could not run the games, the join does it.
6. "Mapped up to" moves to the last commit read, and each pick's row says what happened to it.
