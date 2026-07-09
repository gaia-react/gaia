---
name: gaia-debt
description: Fix the tech-debt backlog, a single issue or a recommended related batch, highest severity then oldest first, on a fresh feature branch or worktree through the audit gate, closing the issue(s) on merge. Pass `list` to see the ordered backlog, `why <issue-number>` to explain the recommendation, or a bare `<issue-number>` to fix that issue directly.
argument-hint: [fix|list|why <issue-number>|<issue-number>]
---

Run the GAIA **debt** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/debt.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (the leading token selects the subcommand: `fix`, `list`, `why <issue-number>`, `fix <issue-number>`, or a bare `<issue-number>`/`#<issue-number>`, which fixes that specific issue directly). If no arguments were provided, follow the reference's no-argument path (which defaults to `fix`).
