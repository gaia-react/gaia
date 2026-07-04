---
type: concept
title: GAIA Plan
status: active
created: 2026-04-30
updated: 2026-07-04
tags: [concept, claude, skill, orchestration]
---

# GAIA Plan

`/gaia-plan [description]` plans a complex feature using GAIA's [[Task Orchestration]] pattern, without implementing anything. The skill lives at `.claude/skills/gaia/references/plan.md` (dispatched by the `/gaia-plan` command, which reads this reference).

## Steps

1. **Get description.** Use `$ARGUMENTS` if provided; otherwise ask "What do you want me to orchestrate?" and wait.
2. **Pick the planner model.** The planner's model is pinned at spawn, so it runs on Opus even when the session is on Sonnet. If the session is on Opus, the planner inherits it. When the run is non-interactive (a headless or automation context with no interactive user to prompt), the planner defaults to Opus without a prompt. Otherwise ask via `AskUserQuestion` whether to use Opus for planning, with "Use Opus (Recommended)" as the default option and "keep the current model" as the alternative.
3. **Spawn the planner.** Launch a `general-purpose` Agent with the chosen model and a prompt that builds the plan files: per-task docs, `README.md` (task graph + frozen interface contracts), `ORCHESTRATOR.md` (execution playbook), and `KICKOFF.md` (the cold-start prompt). A spec-less plan writes these to `.gaia/local/plans/PLAN-NNN/` (allocated from `.gaia/local/plans/ledger.json`); a plan derived from a SPEC colocates them inside the SPEC's own folder at `.gaia/local/specs/<SPEC-ID>/plan/` (`plan-2`, `plan-3`, … for a revision). The planner is a leaf sub-agent: it investigates with parallel tool calls and writes the files, and it cannot spawn further sub-agents (see [[Task Orchestration#Topology]]). See [[Task Orchestration]] for the artifact contract.
4. **Decomposition audit (recommended).** After the planner returns and its artifacts pass the existence check, an `AskUserQuestion` offers a lightweight adversarial audit of the decomposition itself (recommended for a non-trivial plan, skipped for a trivial single-phase one; never blocks the handoff). Three parallel `general-purpose` auditors run: decomposition and dependency soundness (same-phase tasks that actually share state or order, phase order that ignores a real dependency, a shared contract two tasks read inconsistently), contract grounding (every file, export, type, and signature named in a task contract resolves against the real repo and `node_modules`), and SPEC coverage (the success-criteria-and-UAT-to-task matrix, dispatched only when the plan derives from a SPEC; see [[GAIA Spec]]). It targets the one artifact neither the upstream SPEC-audit nor the downstream pre-merge `code-review-audit` can inspect, and stays deliberately narrow: no refutation pass, since its findings are checkable rather than severity-debatable. Localized findings fold into the task docs; a structural finding re-spawns the planner with the findings as a correction directive. Interactive surfaces each material finding before applying; auto-mode applies the unambiguous ones.
5. **Hand off.** Print a short summary of the plan, then a fenced one-line resume prompt (`Read /abs/path/to/<plan-dir>/KICKOFF.md and execute it.`, where `<plan-dir>` is `.gaia/local/plans/PLAN-NNN/` or the colocated `.gaia/local/specs/<SPEC-ID>/plan/`). The skill prints the prompt as a fenced code block, then a single trailing `Type /clear and paste the prompt above.` line.

## Orchestrator contract

`ORCHESTRATOR.md` pins each task sub-agent to `model: sonnet` by default, decoupling execution from the orchestrator's own session model, since the spec and plan audits resolve the complexity upstream so execution runs on the cheaper model. The planner escalates a specific phase to Opus only when it names a genuinely deep-synthesis reason. `ORCHESTRATOR.md` also mandates a brief **final summary** before awaiting merge confirmation: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, and quality-gate status. A few lines, not a recap of every change. The final archival phase (pruning the plan folder to `SUMMARY.md` + `cost.md`, and moving a spec-less plan's folder to `.gaia/local/plans/archived/PLAN-NNN/`) only runs after the user confirms the PR is ready to merge; see [[Task Orchestration]] for the gitignored-vs-tracked branching and the archival mechanics.

## Pairs with

- [[Task Orchestration]]: the underlying pattern, plan-folder layout, and execution lifecycle.
- [[Quality Gate]]: runs between phases.
- [[PR Merge Workflow]]: final gate before merge.
