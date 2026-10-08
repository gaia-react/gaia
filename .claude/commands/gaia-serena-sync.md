---
name: gaia-serena-sync
description: Detects the languages Serena is not indexing and, on explicit consent, additively appends them to the `language_servers:` list (`languages:` before Serena 1.7) in `.serena/project.yml`, then prompts a Serena restart. Never mutates without a yes; inert without Serena.
disable-model-invocation: true
argument-hint: []
---

Run the GAIA **serena-sync** workflow.

## Pre-flight: Worktree check

This command rewrites the clone's `.serena/project.yml` language list, which is clone-level index configuration. If invoked from a linked worktree, reject hard: `gaia_refuse_if_worktree` (`.gaia/scripts/main-only-lib.sh`) asks the shared resolver which tree this is and refuses out loud, naming the main checkout, when the answer is a worktree.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_refuse_if_worktree "/gaia-serena-sync" || exit 1
```

If the detection does not fire, fall through to the workflow dispatch line below.

Read `.claude/skills/gaia/references/serena-sync.md` from the project root and follow it exactly. No arguments are needed.
