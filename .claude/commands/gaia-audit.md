---
name: gaia-audit
description: Audit memory, wiki, and auto-loaded files for duplication, conflicting instructions, and stale content. The default path researches, then asks you a single Apply / Discuss / Decline question before any change. Pass --apply to re-run the apply stage against the most recent report.
argument-hint: [--apply]
---

Run the GAIA **audit** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/audit.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input. If no arguments were provided, follow the reference's no-argument (default research-then-gate) path: spawn Stage 1, then **in this conversation** relay Stage 1's summary and run the `AskUserQuestion` decision gate described in the reference's "Branch on `$ARGUMENTS`" section before branching. The gate (Apply / Discuss / Decline) MUST run here in the main conversation, not in a subagent, because only this layer can prompt the user.
