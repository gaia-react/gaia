---
type: concept
title: GAIA Handoff
status: active
created: 2026-04-20
updated: 2026-04-30
tags: [concept, claude, skill, session]
---

# GAIA Handoff

`/gaia handoff` writes a self-contained session handoff document so the next session can pick up cold without re-reading the conversation. The skill lives at `.claude/skills/gaia/references/handoff.md` (dispatched by the `/gaia` router skill).

Output: `.claude/handoff/HANDOFF-{YYYY-MM-DD}-{slug}.md`. Synthesizes accomplishments, decisions, gaps, open questions, and concrete next actions — never dumps the transcript raw. Empty sections are skipped rather than filled with "N/A".

Pairs with [[GAIA Pickup]].
