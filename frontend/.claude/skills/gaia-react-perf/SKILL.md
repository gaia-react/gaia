---
name: gaia-react-perf
description: Diagnose React render performance by driving a micro-interaction, capturing real renders, and surfacing memo-defeating reference instability with a recommended structural fix. Measure-only: it emits a diagnosis, it does not auto-fix. Trigger on `/gaia-react-perf` or natural-language asks like "profile renders", "measure renders", "why is X re-rendering", or "diagnose render performance". Do NOT trigger on vague "feels slow", "janky", or "optimize my app".
---

Run the GAIA **react-perf** measure-only diagnostic with these arguments: `$ARGUMENTS`

## Pre-flight: Worktree check

This skill drives the app's dev server and profiles the clone's build. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-react-perf" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia-react-perf/references/measure-only.md` from the project root and follow it exactly. Treat the arguments above as an optional inline target (the page plus the micro-interaction to profile); if empty, ask the user to name a concrete micro-interaction before proceeding, per the reference.
