---
name: health-audit
description: Maintainer-only autonomous health audit + auto-heal loop. Runs N=3 fresh-team audit-fix-audit cycles with circuit breakers, reports an F-to-A+ verdict (folding in the shared Claude-integration fitness grade) or escalates.
---

# /health-audit

Maintainer-only. You are the **Orchestrator** for a GAIA health audit.

## Step 1, Read the runbook

Read `.gaia/cli/health/runbook.md` end-to-end before doing anything else. The runbook codifies role structure, bucket definitions, fixer lane mapping, model selection, circuit breakers, and escalation criteria. Do not improvise around it.

## Step 2, Run the loop

Execute the cycle loop defined in the runbook's **§Cycle loop** (max N=3), applying the **§Termination** section's oscillation-threshold definition to detect a stuck fix. Both sections were already read in full at Step 1. **Do not restate the loop or the oscillation definition here.** The runbook is the single source of truth for this control flow.

Bucket E runs the shared Claude-integration fitness protocol defined in `wiki/decisions/Claude Integration Fitness.md` over the seven fitness categories. The Bucket E auditor does not re-specify those checks, it reads the wiki page and runs its protocol. Fitness findings route to the existing `claude-surface` Fixer lane.

On the first cycle that meets the clean gate, you spawn a false-clean challenger (BS/MC/GH lenses always, FV when a prior cycle ran a Fixer) before the A+ report and the RUN_DIR deletion; a substantiated finding revokes the clean exit, injected as `real-fix` (non-cycle-3) or escalated `false-clean-refuted` (cycle 3). It runs at most once per run. The runbook's §False-clean challenger is the source of truth.

You spawn the five buckets, the Adjudicator, and the Fixers, and every one is a leaf subagent, because a subagent cannot spawn another subagent (the hard depth-1 limit). So you, the Orchestrator on this main thread, own every spawn. Stay mechanical: counters, directory creation, disk reads, the `jq`/`comm` oscillation compare, and dispatch. You never audit, adjudicate, or fix in your own context, so whatever session state you inherit cannot bias a grade.

A fresh Adjudicator per cycle keeps prior-cycle findings from bleeding into this cycle's verification: it never reads a prior cycle's `findings.json` (you own the cross-cycle oscillation compare), so every cycle's Adjudicator starts on clean context. **Bucket E** runs as its own leaf so its voluminous raw fitness output stays on disk and out of the Adjudicator's context: the Adjudicator reads only Bucket E's findings JSON. Each bucket is spawned with its assigned model (Haiku for the mechanical buckets, Sonnet for the judgment-bearing ones; see the runbook's model table), which pins per-bucket models correctly now that the Orchestrator dispatches them directly.

## Step 3, Comprehensive phase (post-loop)

After the loop above breaks or escalates — clean exit and escalation both route through here — and before the Step 5 report is emitted, run the **Comprehensive Audit phase** per `.gaia/cli/health/comprehensive/runbook.md`. It is diff-gated (a pre-flight gauge picks skip / scoped / full), report-only (no auto-heal, files nothing), and maintainer-only.

- Runs **exactly once**, **never inside the loop above**.
- Pass `--comprehensive-full` through to the gauge when the maintainer invoked `/health-audit` with that force flag. Pass `--major` through when the maintainer invoked `/health-audit --major` (the gauge maps it to `source=major`).
- Surfaces only the **top findings by consequence** for the filing offer, discarding the lower-consequence tail (the runbook's `COMPREHENSIVE_FILE_CAP`); it never restocks the tech-debt backlog with every confirmed finding.
- **Do not copy the comprehensive protocol here.** The comprehensive runbook is the single source of truth; this command file only points to it.
- Does **not** recompute or mutate the integrity verdict math (the three-input floor). It reports alongside, in Step 5.

## Step 4, Honor the circuit breakers

Follow the runbook's **§Circuit breakers**, already read in full at Step 1. **Do not restate the breaker list here.** The runbook is the single source of truth for this list.

If the human refuses → escalate.

## Step 5, Report

On clean exit (no open findings remain; the reported grade is the honest floor: A+ when there were no findings at all, otherwise capped by any non-blocking residual `info`, typically A):

```
HEALTH AUDIT: <overall grade, A+ or A>
Overall grade: <A+ | A>
Shared-fitness grade: <honest floor of seven category grades>
Cycles: <N>
Findings closed: <count> (per cycle: <breakdown>)
Non-blocking residuals: <count> (e.g. wiki/.state.json post-sync drift, recorded not blocking)
Artifacts: cleaned (this run's .gaia/local/audit/archived/<stamp>/ folder removed)
comprehensive: skipped (no framework-facing changes since <tag>)
```

On escalation:

```
HEALTH AUDIT: ESCALATED
Overall grade: <F-to-A+, floor of Bucket D verdict, findings-count signal, shared-fitness grade>
Shared-fitness grade: <F-to-A+, floor of seven category grades from Bucket E>
Reason: <max-loops | oscillation | circuit-breaker | unclassified-finding | fixer-unable-to-fix | false-clean-refuted>
Outstanding findings: <list with fingerprints>
Cycles run: <N>
Artifacts: preserved at .gaia/local/audit/archived/<stamp>/c1/, c2/, c3/ (see findings.json in each)
comprehensive: skipped (no framework-facing changes since <tag>)
```

The overall grade is F-to-A+ and is never higher than the shared-fitness grade. Both grades appear in every report output (clean exit and escalation).

The `comprehensive:` line above is the Comprehensive phase's `skip`-depth result: interpolate `<tag>` from the gauge's resolved baseline (`jq -r '.baseline_tag' .gaia/local/audit/comprehensive/gauge.json`), never emit the literal placeholder. On a `scoped`/`full` depth, replace that line with the report path and its top-line counts:

```
Comprehensive: .gaia/local/audit/comprehensive/REPORT.md
  (<actionable> actionable across <lenses>; <refuted> refuted; depth <depth>)
```

If the round returned any `intent-dependent` verdict, add its count to that same parenthetical (`; <n> open question(s)`). Those findings are factually accurate but their disposition turns on product intent the repo records nowhere, so they are deliberately excluded from the actionable list and from the Step 6 filing offer. Point the maintainer at `REPORT.md ## Open questions` and let them answer; never answer on their behalf or fold one into the filing offer.

If the verification round confirmed a blocker, add a release-gate flag on its own line:

```
RELEASE-GATE: comprehensive audit confirmed <n> blocker(s) — see REPORT.md ## Priority index
```

The comprehensive line is additive: it does not change the `HEALTH AUDIT: <grade>` computation or the shared-fitness grade. The integrity verdict math above is untouched.

## What you do NOT do

- Do not fix anything yourself. Fixers fix; you orchestrate.
- Do not re-grade between cycles, only on a clean Adjudicator report or on escalation.
- Do not commit. Fixers leave the working tree dirty; the human commits.
- Do not write to `wiki/log.md` or `wiki/hot.md`.
- Do not edit the runbook mid-loop. If the runbook needs changing, escalate first.
- Do not delete this run's `.gaia/local/audit/archived/<stamp>/` folder (RUN_DIR) on escalation. Preserve everything for human review.
- Do not let the Comprehensive phase edit audited files or file issues; it is report-only, and it never feeds the integrity verdict math.

Begin by reading `.gaia/cli/health/runbook.md`.
