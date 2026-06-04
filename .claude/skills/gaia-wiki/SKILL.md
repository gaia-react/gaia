---
name: gaia-wiki
description: GAIA wiki maintenance, sync, consolidate, lint. Runs the full chain with no sub-arg, or a single stage when named (sync | consolidate | lint); append --force to override drift gating. Trigger on `/gaia-wiki <stage>` or natural-language asks like "sync the wiki", "run the wiki maintenance chain", "consolidate the wiki", or "lint the wiki".
---

Run the GAIA **wiki** maintenance workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/wiki.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input (a stage name such as `sync`, `consolidate`, or `lint`, and/or a trailing `--force` token, all of which the reference detects). If no arguments were provided, follow the reference's full-chain path.
