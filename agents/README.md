# AI coordination docs

Working documents for AI agents: the main session and the subagents it briefs. They are not for players or developers, who read `README.md` and `docs/`. Each effort has its own folder. That folder's `README.md` is the entry point and names the writer of each file.

Rules for every folder here:
- One writer per file, named in the folder's README. Other agents read it; a subagent with something to say writes its own report file.
- Update in place: rewrite the line that changed, never append a second version of a fact.
- Link to a fact instead of repeating it. Keep measured and estimated values apart.
- English, like the rest of the repository. Write repository paths as code spans, not links (`dm/tools/tests/test_docs.py` checks every relative link).

| Folder | Effort | State |
|---|---|---|
| [architecture](architecture/README.md) | How the host works: structure, data flow, state, locks, threads, lifetimes | being written |
| [refactor](refactor/README.md) | Refactor of the NVN / Metal layer for CPU time | active |
