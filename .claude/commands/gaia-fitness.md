---
name: gaia-fitness
description: Health-check and auto-heal this project's Claude integration, triage, heal, verify, and report an F-to-A+ grade.
---

Run the GAIA **fitness** workflow.

## Pre-flight: Worktree check

This command heals this clone's Claude integration in place and reports a grade for the clone. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-fitness" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/fitness.md` from the project root and follow it exactly.
