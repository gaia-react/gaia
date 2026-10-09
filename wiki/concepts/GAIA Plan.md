---
type: concept
title: GAIA Plan
status: active
created: 2026-04-30
updated: 2026-07-08
tags: [concept, claude, skill, orchestration]
---

# GAIA Plan

`/gaia-plan [description]` plans a complex feature using GAIA's [[Task Orchestration]] pattern, without implementing anything. The skill lives at `.claude/skills/gaia/references/plan.md` (dispatched by the `/gaia-plan` command, which reads this reference).

## Steps

1. **Get description.** Use `$ARGUMENTS` if provided; otherwise ask "What do you want me to orchestrate?" and wait. A bare `SPEC-NNN` id (the standard [[GAIA Spec]] handoff) resolves the plan from that SPEC's `.gaia/local/specs/SPEC-NNN/SPEC.md`, reading its sibling `AUDIT.md` too when the audit produced one, no path or intent text needs to travel in the invocation.
2. **Pick the planner model.** The planner's model is pinned at spawn, so it runs on a top-tier model even when the session is on Sonnet. Opus and Fable are both top-tier planning models. If the session is on Opus or Fable, the planner inherits the current model. When the run is non-interactive (a headless or automation context with no interactive user to prompt), the planner defaults to Opus without a prompt. Otherwise (the session is on Sonnet, Haiku, or another lesser model) ask via `AskUserQuestion` which model should plan, with "Use Opus (Recommended)" as the default option, "Use Fable" as a second top-tier choice, and "keep the current model" as the alternative.
3. **Spawn the planner.** Launch a `general-purpose` Agent with the chosen model and a short prompt that passes only the plan-specific inputs (plan folder, SPEC and AUDIT paths or `unset`, branch id, feature description); the planner reads its instructions from `.claude/skills/gaia/references/plan/planner.md` and builds the plan files: per-task docs, `README.md` (task graph + frozen interface contracts), `ORCHESTRATOR.md` (execution playbook), and `KICKOFF.md` (the cold-start prompt). A spec-less plan writes these to `.gaia/local/plans/PLAN-NNN/` (allocated from `.gaia/local/plans/ledger.json`); a plan derived from a SPEC colocates them inside the SPEC's own folder at `.gaia/local/specs/<SPEC-ID>/plan/` (`plan-2`, `plan-3`, … for a revision). The planner is a leaf sub-agent: it investigates with parallel tool calls and writes the files, and it does not spawn sub-agents (see [[Task Orchestration#Topology]]). See [[Task Orchestration]] for the artifact contract.
4. **Decomposition audit.** After the planner returns and its artifacts pass the existence check, a lightweight adversarial audit of the decomposition itself runs automatically with no prompt: the plan is gauged and the audit runs on a non-trivial plan (parallel tasks in a phase, multiple phases, or a shared frozen contract), skipped on a trivial single-phase one; it never blocks the handoff. Each auditor writes its findings to a file under the plan folder that is checked after it finishes, so a silent auditor cannot pass as a clean decomposition (see `.claude/skills/gaia/references/spec/lens-dispatch.md`). Three parallel `general-purpose` auditors run: decomposition and dependency soundness (same-phase tasks that actually share state or order, phase order that ignores a real dependency, a shared contract two tasks read inconsistently), contract grounding (every file, export, type, and signature named in a task contract resolves against the real repo and `node_modules`), and SPEC coverage (the success-criteria-and-UAT-to-task matrix, dispatched only when the plan derives from a SPEC; see [[GAIA Spec]]). It targets the one artifact neither the upstream SPEC-audit nor the downstream pre-merge `code-review-audit` can inspect, and stays deliberately narrow: no refutation pass, since its findings are checkable rather than severity-debatable. Localized findings fold into the task docs; a structural finding re-spawns the planner with the findings as a correction directive. Interactive surfaces each material finding before applying; auto-mode applies the unambiguous ones.
5. **Hand off.** Print a short summary of the plan, then a fenced one-line resume prompt (`Read /abs/path/to/<plan-dir>/KICKOFF.md and execute it.`, where `<plan-dir>` is `.gaia/local/plans/PLAN-NNN/` or the colocated `.gaia/local/specs/<SPEC-ID>/plan/`). The skill prints the prompt as a fenced code block, then a single trailing `Type /clear and paste the prompt above.` line.

## Plan mode is not this skill

The harness's own plan mode (`ExitPlanMode`, a single markdown written to `~/.claude/plans/`) is a different mechanism from `/gaia-plan`. Plan mode can wrap a `/gaia-plan` invocation, but the skill's real deliverable is still the artifact set under `.gaia/local/plans/` (or the colocated SPEC folder) plus the KICKOFF resume prompt, not a plan-mode markdown. Follow the skill's Steps above even when plan mode wraps the call.

## Orchestrator contract

`ORCHESTRATOR.md` pins each task sub-agent to `model: sonnet` by default, decoupling execution from the orchestrator's own session model, since the spec and plan audits resolve the complexity upstream so execution runs on the cheaper model. The planner escalates a specific phase to Opus only when it names a genuinely deep-synthesis reason. `ORCHESTRATOR.md` also mandates a brief **final summary** before awaiting merge confirmation: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, and quality-gate status. A few lines, not a recap of every change. The close runs in two halves around the merge. After the user confirms the PR is ready to merge, consolidation produces a verified `SUMMARY.md` and the wiki promotion step acts on it, both before the merge. After the merge is confirmed, the post-merge close removes a spec-colocated plan's `SPEC.md` and `AUDIT.md` once `SUMMARY.md` re-verifies, and the archive step runs: a spec-less plan's folder is kept, reduced to `SUMMARY.md` with its `RUNNING` sentinel cleared, gated on `usage.sh represented` finding the plan's `gaia-plan` close on the usage ledger, which with the two id-ledgers is the whole durable record that survives; a spec-colocated plan deletes only its own `plan[-N]` subfolder once the parent SPEC's `SUMMARY.md` exists. See [[Task Orchestration]] for the full retention mechanics.

## Ledger status and closure

A plan's `.gaia/local/plans/ledger.json` row (or, for a spec-colocated plan, the parent SPEC's `.gaia/local/specs/ledger.json` row) carries a `status` of `ready | merged | abandoned`, allocated at `ready` and age-anchored on `merged_at`. The orchestrator's post-merge close stamps the row `merged` together with the confirmed `pr_number`, and the pre-flight sweep of both `/gaia-spec` and `/gaia-plan` is the backstop for a merge that happened outside an orchestrator: it reconciles the ledger, consolidates folders never consolidated, and age-reaps through the retention helpers described in [[Task Orchestration]]. `.claude/skills/gaia/references/spec/lifecycle.md` owns the steps.

Reaching the wiki is offered-then-gated rather than default-on: the consolidation step stamps a spec-less plan's `SUMMARY.md` with `wiki_promote_default: ask` and `wiki_promote_targets: [decisions]`, so a human is asked before the merge whether the plan's outcome is worth a wiki page. A declined promotion, or an `ask` with no human present, is recorded in `PROGRESS.md` and nothing is deferred or drained later. This is deliberately asymmetric with a SPEC's default-on promotion, since not every plan produces wiki-durable knowledge.

## Pairs with

- [[Task Orchestration]]: the underlying pattern, plan-folder layout, and execution lifecycle.
- [[Quality Gate]]: runs between phases.
- [[PR Merge Workflow]]: final gate before merge.
