---
name: gaia-debt
description: Fixes the tech-debt backlog, a single issue or a recommended related batch, highest severity then oldest first, on a fresh isolated branch through the audit gate, closing the issue(s) on merge. With no argument it drains the top of the backlog; one issue number fixes that issue directly, and several issue numbers name the operator's own batch, budgeted. An optional trailing `[use] worktree|branch` picks the isolation mode. A named number that cannot be drained stops with a reason. Use when the user asks to drain, fix, or work the tech-debt backlog or a named tech-debt issue.
argument-hint: [<issue-number>...] [[use] worktree|branch]
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

Read `.claude/skills/gaia/references/debt.md` from the project root and follow it exactly, treating the arguments above as its input: zero or more issue numbers (one fixes that issue, several name your own batch) and an optional trailing isolation mode. The reference's argument parser owns the grammar, and an unrecognized argument stops the run with the accepted form; no argument runs the top-of-backlog flow.

`debt.md` routes each run to at most a few of these sub-references, all under `.claude/skills/gaia/references/debt/`. Read one only when a "Read ... now" line sends you there, and then read the whole file:

- `recommend.md`: the no-argument offer.
- `named.md`: validating named issue numbers and fixing one issue or a named set.
- `spec-handoff.md`: handing a spec-class issue off to `/gaia-spec`.
- `worktree-cleanup.md`: post-merge cleanup when the fix ran in a worktree.
