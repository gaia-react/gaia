---
name: gaia-wiki
description: GAIA wiki maintenance, sync, consolidate, lint. Runs the full chain with no sub-arg, or a single stage when named (sync | consolidate | lint); append --force to override drift gating. Trigger on `/gaia-wiki <stage>` or natural-language asks like "sync the wiki", "run the wiki maintenance chain", "consolidate the wiki", or "lint the wiki".
---

Run the GAIA **wiki** maintenance workflow with these arguments: `$ARGUMENTS`

## Pre-flight: Worktree check

This command rewrites tracked `wiki/` content and its state file for the whole repository. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-wiki" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/wiki.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (a stage name such as `sync`, `consolidate`, or `lint`, and/or a trailing `--force` token, all of which the reference detects). If no arguments were provided, follow the reference's full-chain path.
