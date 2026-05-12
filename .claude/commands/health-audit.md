---
name: health-audit
description: Maintainer-only autonomous health audit + auto-heal loop. Runs N=3 fresh-team audit-fix-audit cycles with circuit breakers, reports an F-to-A+ verdict (folding in the shared Claude-integration fitness grade) or escalates.
---

# /health-audit

Maintainer-only. You are the **Orchestrator** for a GAIA health audit.

## Step 1 — Read the runbook

Read `.gaia/cli/health/runbook.md` end-to-end before doing anything else. The runbook codifies role structure, bucket definitions, fixer lane mapping, model selection, circuit breakers, and escalation criteria. Do not improvise around it.

## Step 2 — Run the loop

Execute the cycle loop from the runbook (max N=3):

```
if .gaia/local/audit/ exists: mv it to .gaia/local/audit.prev-$(date +%s)/
mkdir -p .gaia/local/audit

For cycle in 1..3:
  spawn fresh Triager → Triager runs Audit Team in parallel (buckets A–E)
  Triager writes findings to .gaia/local/audit/c<N>/findings.json
    (includes shared_fitness_grade from Bucket E and overall_grade)
  if clean (0 findings + Bucket D = A+ readiness + Bucket E shared_fitness_grade = A+):
    overall grade A+, exit
  Triager classifies findings; compare fingerprints between c<N>/findings.json
    and c<N-1>/findings.json (jq + comm) — escalate on intersection
  Triager dispatches parallel Fixers (lane-aware); fitness findings → claude-surface lane
  Fixers complete, Triager reports post-fix state to you
  shut down the team, start the next cycle
After cycle 3 without clean: escalate (max loops hit)

On clean A+: rm -rf .gaia/local/audit/c* (whitelisted)
On escalation: preserve all c*/ dirs; surface paths in escalation report
```

Bucket E runs the shared Claude-integration fitness protocol defined in `wiki/decisions/Claude Integration Fitness.md` over the seven fitness categories. The Triager does not re-specify those checks — it reads the wiki page and runs its protocol. Fitness findings route to the existing `claude-surface` Fixer lane.

A fresh Triager per cycle keeps prior-cycle findings from bleeding into this cycle's verification. Within a cycle, the Triager may execute buckets directly via parallel tool calls or dispatch fresh subagents — see runbook §Roles.

## Step 3 — Honor the circuit breakers

A Fixer dispatch pauses for human-confirm if the proposed fix:
- Touches more than 100 lines.
- Modifies `.gaia/release-exclude`.
- Modifies `.claude/rules/`.
- Removes a check from `.gaia/release-scrub.yml`.
- Edits `.gaia/cli/health/taxonomy.md` "Decided / not findings" entries.
- Edits `wiki/decisions/Claude Integration Fitness.md` "Decided / not findings" section.

If the human refuses → escalate.

## Step 4 — Report

On clean exit:

```
HEALTH AUDIT: A+
Overall grade: A+
Shared-fitness grade: A+ (floor of seven category grades)
Cycles: <N>
Findings closed: <count> (per cycle: <breakdown>)
Artifacts: cleaned (.gaia/local/audit/c* removed)
```

On escalation:

```
HEALTH AUDIT: ESCALATED
Overall grade: <F-to-A+ — floor of Bucket D verdict, findings-count signal, shared-fitness grade>
Shared-fitness grade: <F-to-A+ — floor of seven category grades from Bucket E>
Reason: <max-loops | oscillation | circuit-breaker | unclassified-finding | fixer-unable-to-fix>
Outstanding findings: <list with fingerprints>
Cycles run: <N>
Artifacts: preserved at .gaia/local/audit/c1/, c2/, c3/ (see findings.json in each)
```

The overall grade is F-to-A+ and is never higher than the shared-fitness grade. Both grades appear in every report output (clean exit and escalation).

## What you do NOT do

- Do not fix anything yourself. Fixers fix; you orchestrate.
- Do not re-grade between cycles — only on a clean Triager report or on escalation.
- Do not commit. Fixers leave the working tree dirty; the human commits.
- Do not write to `wiki/log.md` or `wiki/hot.md`.
- Do not edit the runbook mid-loop. If the runbook needs changing, escalate first.
- Do not delete `.gaia/local/audit/c*/` on escalation. Preserve everything for human review.

Begin by reading `.gaia/cli/health/runbook.md`.
