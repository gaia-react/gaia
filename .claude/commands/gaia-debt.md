---
name: gaia-debt
description: Fix the tech-debt backlog, a single issue or a recommended related batch, highest severity then oldest first, on a fresh isolated branch through the audit gate, closing the issue(s) on merge. Pass `list` to see the ordered backlog, `why <issue-number>` to explain the recommendation, or a bare `<issue-number>` to fix that issue directly.
argument-hint: [fix|list|why <issue-number>|<issue-number>]
---

Run the GAIA **debt** workflow with these arguments: `$ARGUMENTS`

## Pre-flight: Worktree check

This command claims a backlog issue, cuts its own isolated branch, and drives that branch's pull request to merge. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-debt" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/debt.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (the leading token selects the subcommand: `fix`, `list`, `why <issue-number>`, `fix <issue-number>`, or a bare `<issue-number>`/`#<issue-number>`, which fixes that specific issue directly). If no arguments were provided, follow the reference's no-argument path (which defaults to `fix`).
