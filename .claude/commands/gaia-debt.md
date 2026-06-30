---
name: gaia-debt
description: Drain the tech-debt backlog one issue at a time, highest severity then oldest first, on a fresh branch through the audit gate, closing the issue on merge. Pass `list` to see the ordered backlog or `why <issue-number>` to explain the recommendation.
argument-hint: [drain|list|why <issue-number>]
---

Run the GAIA **debt** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/debt.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (the leading token selects the subcommand: `drain`, `list`, or `why <issue-number>`). If no arguments were provided, follow the reference's no-argument path (which defaults to `drain`).
