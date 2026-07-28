---
name: gaia-harden
description: Judge-the-form, human-gated hardening. Reviews recurring code-audit-frontend findings and, with approval, drafts the lowest-context-weight form (deterministic check / skill / path-scoped prose rule) into the working tree. Pass `list` to see live candidates or `why <finding_class>` to explain one.
argument-hint: [review|list|why <finding_class>]
---

Run the GAIA **harden** workflow with these arguments: `$ARGUMENTS`

## Pre-flight: Worktree check

This command drafts repo-wide rules, checks, and skills into the working tree from a repo-wide finding tally. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-harden" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/harden.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (the leading token selects the subcommand: `review`, `list`, or `why <finding_class>`). If no arguments were provided, follow the reference's no-argument path (which defaults to `review`).
