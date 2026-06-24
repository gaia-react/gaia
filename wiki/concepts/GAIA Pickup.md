---
type: concept
title: GAIA Pickup
status: active
created: 2026-04-20
updated: 2026-06-24
tags: [concept, claude, skill, session]
---

# GAIA Pickup

`/gaia-pickup` restores "where did we leave off" at session start: reads the latest handoff file, checks for branch/commit drift against current git state, and reports a ≤15-line status block with the suggested next action. The reference lives at `.claude/skills/gaia/references/pickup.md` (dispatched by the `/gaia-pickup` skill, which reads this reference).

Falls back to `wiki/hot.md` if no handoff exists. Archives the consumed handoff to `.gaia/local/handoff/archive/` only after work has actually begun.

Pairs with [[GAIA Handoff]].
