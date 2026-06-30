---
name: health-audit
description: Maintainer-only autonomous health audit + auto-heal loop. Runs N=3 fresh-team audit-fix-audit cycles with circuit breakers, reports an F-to-A+ verdict (folding in the shared Claude-integration fitness grade) or escalates.
---

# /health-audit

Maintainer-only. You are the **Orchestrator** for a GAIA health audit.

## Step 1, Read the runbook

Read `.gaia/cli/health/runbook.md` end-to-end before doing anything else. The runbook codifies role structure, bucket definitions, fixer lane mapping, model selection, circuit breakers, and escalation criteria. Do not improvise around it.

## Step 2, Run the loop

Execute the cycle loop from the runbook (max N=3):

```
if .gaia/local/audit/ exists: mv it to .gaia/local/audit.prev-$(date +%s)/
mkdir -p .gaia/local/audit

For cycle in 1..3:
  you create c<N>/ and bucket sub-dirs
  you spawn the five Audit buckets (A–E) as parallel, model-pinned leaf subagents
    each writes its raw output to disk under c<N>/ and returns a summary + path
  you spawn a fresh Adjudicator leaf for this cycle: it reads the c<N> bucket
    artifacts from disk, classifies, and writes c<N>/findings.json
    (includes shared_fitness_grade from Bucket E and overall_grade)
  if clean (no open findings + Bucket D = A+ readiness + effective Bucket E shared_fitness_grade = A+; non-blocking residuals exempt, see runbook §Termination):
    if the false-clean challenger has not run yet this run:
      you spawn the false-clean challenger lenses as parallel leaf subagents (BS/MC/GH always, FV when a prior cycle dispatched a Fixer); mark it run
      if a lens substantiates a finding: inject it into c<N>/findings.json (action=real-fix, bucket=challenger); at cycle < 3 fall through to fixers + next cycle; at cycle 3 escalate false-clean-refuted and preserve c*/
    if still clean: report honest overall grade (A+ when no findings at all, else the floor that residual info may cap at A), exit
  you compare open-finding (action=real-fix) fingerprints between
    c<N>/findings.json and c<N-1>/findings.json (jq + comm); escalate on intersection
  you spawn parallel Fixers (lane-aware) as leaf subagents; fitness findings → claude-surface lane
  Fixers complete and report post-fix state to you
  start the next cycle
After cycle 3 without clean: escalate (max loops hit)

On clean exit: rm -rf .gaia/local/audit/c* (whitelisted)
On escalation: preserve all c*/ dirs; surface paths in escalation report
```

**Oscillation threshold (definition).** The loop is oscillating when any fingerprint is present in both this cycle's and the prior cycle's open-finding set, where the open-finding set is the `action=real-fix` findings recorded in `c<N>/findings.json`. The check is a set intersection of those fingerprints against `c<N-1>/findings.json` (`jq` + `comm`); a non-empty intersection means a fix attempt left the finding unchanged. On any such intersection, escalate with reason `oscillation` rather than spending another cycle.

Bucket E runs the shared Claude-integration fitness protocol defined in `wiki/decisions/Claude Integration Fitness.md` over the seven fitness categories. The Bucket E auditor does not re-specify those checks, it reads the wiki page and runs its protocol. Fitness findings route to the existing `claude-surface` Fixer lane.

On the first cycle that meets the clean gate, you spawn a false-clean challenger (BS/MC/GH lenses always, FV when a prior cycle ran a Fixer) before the A+ report and the `c*/` deletion; a substantiated finding revokes the clean exit, injected as `real-fix` (non-cycle-3) or escalated `false-clean-refuted` (cycle 3). It runs at most once per run. The runbook's §False-clean challenger is the source of truth.

You spawn the five buckets, the Adjudicator, and the Fixers, and every one is a leaf subagent, because a subagent cannot spawn another subagent (the hard depth-1 limit). So you, the Orchestrator on this main thread, own every spawn. Stay mechanical: counters, directory creation, disk reads, the `jq`/`comm` oscillation compare, and dispatch. You never audit, adjudicate, or fix in your own context, so whatever session state you inherit cannot bias a grade.

A fresh Adjudicator per cycle keeps prior-cycle findings from bleeding into this cycle's verification: it never reads a prior cycle's `findings.json` (you own the cross-cycle oscillation compare), so every cycle's Adjudicator starts on clean context. **Bucket E** runs as its own leaf so its voluminous raw fitness output stays on disk and out of the Adjudicator's context: the Adjudicator reads only Bucket E's findings JSON. Each bucket is spawned with its assigned model (Haiku for the mechanical buckets, Sonnet for the judgment-bearing ones; see the runbook's model table), which pins per-bucket models correctly now that the Orchestrator dispatches them directly.

## Step 3, Honor the circuit breakers

A Fixer dispatch pauses for human-confirm if the proposed fix:

- Touches more than 100 lines.
- Modifies `.gaia/release-exclude`.
- Modifies `.claude/rules/`.
- Removes a check from `.gaia/release-scrub.yml`.
- Edits `.gaia/cli/health/taxonomy.md` "Decided / not findings" entries.
- Edits `wiki/decisions/Claude Integration Fitness.md` "Decided / not findings" section.

If the human refuses → escalate.

## Step 4, Report

On clean exit (no open findings remain; the reported grade is the honest floor: A+ when there were no findings at all, otherwise capped by any non-blocking residual `info`, typically A):

```
HEALTH AUDIT: <overall grade, A+ or A>
Overall grade: <A+ | A>
Shared-fitness grade: <honest floor of seven category grades>
Cycles: <N>
Findings closed: <count> (per cycle: <breakdown>)
Non-blocking residuals: <count> (e.g. wiki/.state.json post-sync drift, recorded not blocking)
Artifacts: cleaned (.gaia/local/audit/c* removed)
```

On escalation:

```
HEALTH AUDIT: ESCALATED
Overall grade: <F-to-A+, floor of Bucket D verdict, findings-count signal, shared-fitness grade>
Shared-fitness grade: <F-to-A+, floor of seven category grades from Bucket E>
Reason: <max-loops | oscillation | circuit-breaker | unclassified-finding | fixer-unable-to-fix | false-clean-refuted>
Outstanding findings: <list with fingerprints>
Cycles run: <N>
Artifacts: preserved at .gaia/local/audit/c1/, c2/, c3/ (see findings.json in each)
```

The overall grade is F-to-A+ and is never higher than the shared-fitness grade. Both grades appear in every report output (clean exit and escalation).

## What you do NOT do

- Do not fix anything yourself. Fixers fix; you orchestrate.
- Do not re-grade between cycles, only on a clean Adjudicator report or on escalation.
- Do not commit. Fixers leave the working tree dirty; the human commits.
- Do not write to `wiki/log.md` or `wiki/hot.md`.
- Do not edit the runbook mid-loop. If the runbook needs changing, escalate first.
- Do not delete `.gaia/local/audit/c*/` on escalation. Preserve everything for human review.

Begin by reading `.gaia/cli/health/runbook.md`.
