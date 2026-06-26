---
type: concept
title: GAIA Handoff
status: active
created: 2026-04-20
updated: 2026-06-26
tags: [concept, claude, skill, session]
---

# GAIA Handoff

`/gaia-handoff` writes a self-contained session handoff document so the next session can pick up cold without re-reading the conversation. The skill lives at `.claude/skills/gaia/references/handoff.md` (dispatched by the `/gaia-handoff` skill, which reads this reference).

Output: `.gaia/local/handoff/HANDOFF-{YYYY-MM-DD}-{slug}.md` (the directory is gitignored). The file is ephemeral: only one handoff exists at any time. Writing a new handoff first deletes any existing one (`rm -f .gaia/local/handoff/HANDOFF-*.md`); the new file carries forward anything unfinished from the previous session.

The document synthesizes accomplishments, decisions, gaps, open questions, and concrete next actions; it never dumps the transcript raw. Empty sections are skipped rather than filled with "N/A". The body includes a Teardown instruction: when the Next Actions are complete and verified, the working session deletes the file. Deletion is the only terminal state; there is no archive.

Pairs with [[GAIA Pickup]].
