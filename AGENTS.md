# AGENTS.md

**The rules for this repository live in [`CLAUDE.md`](CLAUDE.md). Read that file.**
It applies to every coding agent working here, whatever tool you arrived through.

This file is a pointer and nothing else — deliberately.

It used to be a full copy of `CLAUDE.md` with the assistant's name swapped, and by
the time anyone looked at it again the copy had gone stale in the worst possible
way: it was missing exactly the three sections that exist to stop an agent doing
damage.

| Missing from the copy | What it governs |
| --- | --- |
| **Merge authorization** | `main` has required checks and `enforce_admins` on, but review approval is deliberately NOT required — otherwise an agent merging its own PR would deadlock waiting for approval on it. The per-PR authorization phrase is the compensating control for that gap. |
| **Branch creation** | Always branch from `origin/main` in one command. Branching from whatever happens to be checked out silently stacks the work on an unmerged PR. |
| **Required status checks** | A check may only join the required list once its workflow is already on `main`, or it blocks every PR forever — including the one that would add it. |

An agent reading that copy would have held a rulebook with the merge control
quietly removed. Duplication is how that happened, so there is none here: one
source of truth, and this file points at it.

If you are adding guidance, add it to `CLAUDE.md`.
