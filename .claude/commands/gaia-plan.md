---
name: gaia-plan
description: Plans a complex feature with GAIA's task-orchestration pattern, structuring the work into fresh-context subagent phases for approval. Does not implement. Use when the user asks to plan a feature, break work into phases, or turn a SPEC into an execution plan.
argument-hint: [feature description]
---

Run the GAIA **plan** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/plan.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input. If no arguments were provided, follow the reference's no-argument path.

`plan.md` routes a run to these. Read one only when a line in `plan.md` says to, and then read the whole file:

- `.claude/skills/gaia/references/spec/lifecycle.md`: step 0's pre-flight sweep.
- `.claude/skills/gaia/references/plan/decomposition-audit.md`: step 4.6, when the gauge runs the audit.
- `.claude/skills/gaia/references/spec/lens-dispatch.md`: step 4.6, with the audit.
- `.claude/skills/gaia/references/plan/planner.md`: never read on this thread; the planner sub-agent spawned at step 4 reads it first.
