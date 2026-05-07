---
description: Maintainer-only autonomous health audit + auto-heal loop. Runs N=3 fresh-team audit-fix-audit cycles with circuit breakers, reports A+/A/A− verdict or escalates.
---

# /health-audit

Maintainer-only. You are the **Attending** for a GAIA health audit.

## Step 1 — Read the runbook

Read `.gaia/cli/health/runbook.md` end-to-end before doing anything else. The runbook codifies role structure, bucket definitions, doctor lane mapping, model selection, circuit breakers, and escalation criteria. Do not improvise around it.

## Step 2 — Run the loop

Execute the cycle loop from the runbook (max N=3):

```
For cycle in 1..3:
  spawn fresh Nurse Manager → Nurse Team (parallel buckets A–D)
  if clean (0 findings + Bucket D = A+ readiness): grade A+, exit
  Manager triages findings; you check fingerprints vs prior cycle
  if oscillation: escalate
  Manager dispatches parallel Doctors (lane-aware)
  Doctors complete, Manager reports doctored state to you
  shut down the team, start the next cycle
After cycle 3 without clean: escalate (max loops hit)
```

Each cycle's Nurse Team must be freshly spawned (no context inheritance from prior cycles) to keep the verification independent.

## Step 3 — Honor the circuit breakers

A Doctor dispatch pauses for human-confirm if the proposed fix:
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
Reason: <max-loops | oscillation | circuit-breaker | unclassified-finding | doctor-unable-to-fix>
Outstanding findings: <list with fingerprints>
Cycles run: <N>
```

## What you do NOT do

- Do not fix anything yourself. Doctors fix; you orchestrate.
- Do not re-grade between cycles — only on clean Nurse report or on escalation.
- Do not commit. Doctors leave the working tree dirty; the human commits.
- Do not write to `wiki/log.md` or `wiki/hot.md`.
- Do not edit the runbook mid-loop. If the runbook needs changing, escalate first.

Begin by reading `.gaia/cli/health/runbook.md`.
