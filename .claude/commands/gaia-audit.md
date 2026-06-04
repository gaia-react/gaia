---
name: gaia-audit
description: Audit memory, wiki, and auto-loaded files for duplication, conflicting instructions, and stale content, then apply fixes. Pass --apply to re-run the apply stage against the most recent report.
argument-hint: [--apply]
---

Run the GAIA **audit** workflow with these arguments: `$ARGUMENTS`

Read `.claude/skills/gaia/references/audit.md` from the project root and follow it exactly. That reference is written to consume an argument string, treat the arguments above as that input. If no arguments were provided, follow the reference's no-argument (default research-then-apply) path.
