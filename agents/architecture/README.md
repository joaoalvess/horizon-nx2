# Architecture

This folder explains how the host works, for agents: the structure, data flow, state, locks, threads and object lifetimes of the code. Every fact is anchored to `file:line` and to the function name, since line numbers move.

What does not go here:
- Findings, meaning a symptom with its cause and fix. Those live in `docs/reference/<subsystem>.md` and are cited here by path and heading in code spans, never copied.
- Player and build documentation: `README.md` and `docs/development.md`.
- Task guides: `docs/agents/`.

| File | Covers | Writer | State |
|---|---|---|---|
| `overview.md` | The whole system: patched modules running natively; gates and SVCs (`entry.S`, `hle.c`, `hle_svc.c`); services; NVN HLE; the Metal layer; present; audio; input. Every thread, what it does and who starts it | architecture subagent A | pending |
| `host-threads.md` | Guest threads on host threads: `G`, the wait list, the semantics of the sync SVCs, QoS, the big stack, same-core handoffs | architecture subagent A | pending |
| `nvn-pipeline.md` | One frame through the NVN layer: recording on the game thread (`hle_nvn.c`), `nvnQueueSubmitCommands`, the `mtl_exec` op loop, passes and encoders, argument encoding, segments and commits, present. Also the encode thread (`nvn_rec.h`) and capture / replay | architecture subagent B | pending |
| `lifetimes.md` | How objects live and die: ARC and `objc_externally_retained`, `defer_obj_release` and fences, residency sets, arenas, serials (`g_by_serial`), pool finalize | architecture subagent B | pending |
| `nvn-state.md` | An inventory of the global state of the translation layer. For each global: what it holds, who writes it, who reads it, the lock that guards it, and the generation counter that invalidates it. This is S3's input | architecture subagent C | pending |
| `locks.md` | Every lock in `dm/gfx/nvn` and `dm/host`: what it guards, which threads take it, its nesting order, and where it is held across calls into other locks | architecture subagent C | pending |

How these files are written:
- Read the code; never guess. During the night of 2026-11-04 read the BASE snapshot in `/Volumes/Hangar/Games/overnight/base-src-<BASE>`, not the working tree, and cite repository paths.
- Put the commit the file was written against at its top. Every statement carries `file:line` at that commit.
- Mark any statement not checked in the code `(unverified)`.
- Keep prose short. Use tables for inventories and numbered steps for flows.
- Link the other files of this folder with relative links. Write every other path as a code span.
- When code changes a fact, the change rewrites the line that states it.
