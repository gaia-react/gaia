---
name: gaia-wiki
description: GAIA wiki maintenance. Runs the full wiki maintenance chain (sync, consolidate, lint with fixes) in one command. Trigger on `/gaia-wiki` or natural-language asks like "sync the wiki", "run wiki maintenance", "consolidate the wiki", or "lint the wiki".
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

Read `.claude/skills/gaia/references/wiki.md` from the project root and follow it exactly. The reference takes no arguments; when arguments were given above, it prints one notice naming them and runs the full chain anyway.
