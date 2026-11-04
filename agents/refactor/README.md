# Refactor of the NVN / Metal layer: index

Start here. This folder is the single source of truth for the effort. `PERF_M4.md` holds the earlier optimization work: read it, do not write to it.

| File | Holds | Writer |
|---|---|---|
| [plan.md](plan.md) | goal, decisions, design principles, oracles, stages and their status, root causes | main thread |
| [catalog.md](catalog.md) | every finding: ID, cost estimate, risk, review verdict, stage, state | main thread |
| [rules.md](rules.md) | the safety, git, boot and subagent rules every agent follows | main thread (the user's rules) |
| [commands.md](commands.md) | build, test, replay, replay-CPU, bench and boot commands | main thread |
| [captures.md](captures.md) | the replay corpus: base binaries, captures, noise, base replay CPU | capture subagent |
| [night-2026-11-04.md](night-2026-11-04.md) | the run to 13:00: scope, setup, tracks, item order per stage, measurement, interim and final summaries | main thread |
| `roles/` ([implementer](roles/implementer.md), [reviewer](roles/reviewer.md), [capture](roles/capture.md), [search](roles/search.md), [architect](roles/architect.md)) | subagent briefs | main thread |
| `reports/` ([naming](reports/README.md)) | one file per subagent run | the subagent that ran |
| [goal.md](goal.md) | the `/goal` text for unattended runs | main thread |

Reading order for a new session: this file, `rules.md`, `plan.md`, the current night file, then `catalog.md` for the items in scope.

To brief a subagent, name its role file, the catalog item, what it may touch and the report path. The role file carries the rest; do not retype it. For example:

> Read `agents/refactor/roles/reviewer.md`. Review item C3; the diff is uncommitted in the checkout. Write your report to `agents/refactor/reports/20261105-0130-C3-review.md` and reply with its verdict line.

Since 2026-11-04 16:30 (the user) parallel work runs in Herdr worktrees, one branch and one implementer each, joined into `refactor` by the main thread (`rules.md`, Worktrees; the live list is in `plan.md`, Worktrees). In the main checkout only the main thread edits. Read-only agents run in parallel.
