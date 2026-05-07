---
description: Maintainer-only autonomous health audit + auto-heal loop. Runs N=3 fresh-team audit-fix-audit cycles with circuit breakers, reports A+/A/A− verdict or escalates.
---

# /health-audit

Maintainer-only. You are the **Orchestrator** for a GAIA health audit.

## Step 1 — Read the runbook

Read `.gaia/cli/health/runbook.md` end-to-end before doing anything else. The runbook codifies role structure, bucket definitions, fixer lane mapping, model selection, circuit breakers, and escalation criteria. Do not improvise around it.

## Step 2 — Run the loop

Execute the cycle loop from the runbook (max N=3):

```
For cycle in 1..3:
  spawn fresh Triager → Triager runs Audit Team in parallel (buckets A–D)
  if clean (0 findings + Bucket D = A+ readiness): grade A+, exit
  Triager classifies findings; you check fingerprints vs prior cycle
  if oscillation: escalate
  Triager dispatches parallel Fixers (lane-aware)
  Fixers complete, Triager reports post-fix state to you
  shut down the team, start the next cycle
After cycle 3 without clean: escalate (max loops hit)
```

A fresh Triager per cycle keeps prior-cycle findings from bleeding into this cycle's verification. Within a cycle, the Triager may execute buckets directly via parallel tool calls or dispatch fresh subagents — see runbook §Roles.

## Step 3 — Honor the circuit breakers

A Fixer dispatch pauses for human-confirm if the proposed fix:
- Touches more than 100 lines.
- Modifies `.gaia/release-exclude`.
- Modifies `.claude/rules/`.
- Removes a check from `.gaia/release-scrub.yml`.
- Edits `.gaia/cli/health/taxonomy.md` "Decided / not findings" entries.

If the human refuses → escalate.

## Step 4 — Report

On clean exit:

```
HEALTH AUDIT: A+
Cycles: <N>
Findings closed: <count> (per cycle: <breakdown>)
```

On escalation:

```
HEALTH AUDIT: ESCALATED
Reason: <max-loops | oscillation | circuit-breaker | unclassified-finding | fixer-unable-to-fix>
Outstanding findings: <list with fingerprints>
Cycles run: <N>
```

## What you do NOT do

- Do not fix anything yourself. Fixers fix; you orchestrate.
- Do not re-grade between cycles — only on a clean Triager report or on escalation.
- Do not commit. Fixers leave the working tree dirty; the human commits.
- Do not write to `wiki/log.md` or `wiki/hot.md`.
- Do not edit the runbook mid-loop. If the runbook needs changing, escalate first.

Begin by reading `.gaia/cli/health/runbook.md`.
