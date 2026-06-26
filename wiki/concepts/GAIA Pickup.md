---
type: concept
title: GAIA Pickup
status: active
created: 2026-04-20
updated: 2026-06-26
tags: [concept, claude, skill, session]
---

# GAIA Pickup

`/gaia-pickup` restores "where did we leave off" at session start: reads the single handoff file, checks for branch/commit drift against current git state, and reports a ≤15-line status block with the suggested next action. The reference lives at `.claude/skills/gaia/references/pickup.md` (dispatched by the `/gaia-pickup` skill, which reads this reference).

On the happy path, the handoff deletes itself via its own Teardown instruction once Next Actions are complete and verified. If pickup finds a stale handoff whose work has already fully landed (branch merged or deleted, Next Actions reflected in git log), it deletes the file and resumes from `wiki/hot.md`. If work is still outstanding, the file stays in place so an interruption remains recoverable. Falls back to `wiki/hot.md` if no handoff exists.

As a defensive measure, if more than one handoff somehow exists, pickup keeps the newest and deletes the rest. Deletion is the only terminal state; nothing is ever archived.

Pairs with [[GAIA Handoff]].
