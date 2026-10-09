# Decomposition audit

The `/gaia-plan` step 4.6 audit, run when the gauge in `plan.md` says the plan is non-trivial. `.claude/skills/gaia/references/spec/lens-dispatch.md` is the lens contract: the shared preamble, the findings file each lens writes, and the pre-clear, classify and re-dispatch steps. This file owns which lenses run and how their findings are applied.

Contents: `## What the audit checks`, `## 4.6a. Dispatch the lens auditors`, `## 4.6b. Apply findings`.

## What the audit checks

A lightweight multi-agent audit of the **decomposition itself**: the one artifact neither the upstream SPEC audit (which ran before the plan existed) nor the downstream pre-merge Code Audit Team audit (which sees the executed diff) can inspect. It verifies that the task graph is a sound factoring of the work, that the frozen interface contracts resolve against the real repo, and that the SPEC's binding criteria are all covered, BEFORE a cold orchestrator burns execution cycles building against a flawed plan.

This is deliberately not a clone of the SPEC audit. The plan is editable and double-netted (sub-agents report `### Deviations from plan` during execution; the Code Audit Team audit gates the merge), so re-running the SPEC audit's claim-grounding, testability, and security lenses here would mostly re-verify what is already verified upstream and downstream. The audit stays narrow: three checks that exist only at plan stage, no refutation pass (these findings are checkable and binary, not severity-debatable like SPEC claims). It dispatches the same parallel `general-purpose` Agent primitive step 4 uses, so it works headless and in auto mode.

## 4.6a. Dispatch the lens auditors

1. Choose the lenses. The **SPEC coverage** lens is dispatched only when `SPEC_PATH` was set in step 1a; the other two always run. A SPEC-less plan's undispatched SPEC coverage lens is recorded not-applicable, never as a no-op.
2. Clear and create the findings directory `<PLAN_DIR>/audit/`, spelled repo-relative as the contract's pre-clear step does: `rm -rf <repo-relative PLAN_DIR>/audit`, then `mkdir -p <repo-relative PLAN_DIR>/audit` (for example `.gaia/local/plans/<PLAN-NNN>/audit`, or `.gaia/local/specs/<SPEC-ID>/plan/audit` for a spec-derived plan).
3. Spawn **one `general-purpose` Agent per lens, all in parallel** (one message, one Agent tool call per lens). Each prompt is the contract's shared preamble filled from its plan column (including its rule that, in a linked worktree, the lens writes its file with `Bash` at the main-checkout path and reads it back), with `<repo_root>` = `$PWD` and `<FINDINGS_DIR>` = `<PLAN_DIR>/audit/`, then the `LENS:` line and the lens's focus text below. Each lens writes `<PLAN_DIR>/audit/<LENS>.json` (`DP.json`, `CG.json`, `COV.json`) and returns only the thin digest.
4. Classify each lens's file after its completion notification with the contract's `audit-noop-detect.sh` call, re-dispatch a no-op lens exactly once against its re-cleared file, and on a second consecutive no-op run it inline, all per the contract's `## Pre-clear, classify, re-dispatch`.

The lenses:

- **Decomposition & dependency soundness (id prefix `DP`).** The highest-value lens, with no analog upstream or downstream. Attack the task graph: tasks placed in the same phase as "parallel" that actually share state, edit the same files, or consume each other's outputs; phase order that does not respect a real data or interface dependency; a frozen interface contract that two tasks interpret inconsistently; acceptance criteria that are not independently verifiable. Construct the concrete scenario where every per-task acceptance criterion passes yet the integrated result is broken. Flag as `blocker` any task that registers net-new files into `.gaia/manifest.json`, or that treats a file's absence from the manifest as `/update-gaia` drift: the manifest is release-generated only.
- **Contract grounding (id prefix `CG`).** Treat every file path, export subpath, type name, and function signature named in a task's interface contract or files-to-touch list as a factual claim, and verify each resolves against the real repo and `node_modules`. A contract that names a non-existent export, a wrong signature, or a hallucinated module is at least `high`, likely `blocker`: the orchestrator will build against it and fail at integration.
- **SPEC coverage (id prefix `COV`, dispatched only when `SPEC_PATH` is set).** Build the matrix SPEC `UATs` + `success_criteria` ↔ task acceptance criteria. Find the holes: a UAT or success criterion no task covers; a task that drifts from or contradicts the SPEC's binding contract; scope the SPEC declared out-of-bounds that a task re-introduces. Read `<SPEC_PATH>` (interpolated) as the source of truth.

## 4.6b. Apply findings

Read the findings from each `<PLAN_DIR>/audit/<LENS>.json` that classified real; this thread applies the fixes, so it reads the finding bodies. The plan is editable and unsaved-to-handoff, so applying a fix is just rewriting plan files, no ceremony.

- **Localized findings** (a wrong contract, a missing acceptance criterion, an uncovered UAT): fold the fix directly into the affected `task-*.md` or `README.md` yourself.
- **Structural findings** (the phase graph is wrong, tasks need re-factoring across phases): re-spawn the planner rather than hand-patching the graph. Re-run `plan.md` step 4's dispatch with its optional `Correction` input set to the path of the surviving findings under `<PLAN_DIR>/audit/`, then re-run step 4.5 against the regenerated folder. This goes through the same `PLAN_DIR` and overwrites the flawed artifacts.

**Interactive:** surface each material (non-`low`) finding to the user before applying (issue, evidence, recommendation; apply / keep / revise); apply `low` findings silently. **Auto-mode:** auto-apply unambiguous fixes; if a repair is ambiguous (more than one defensible fix), leave the plan unchanged and record the finding in a `## Audit notes` section appended to `README.md` so the orchestrator and user see it.

Then return to `plan.md` step 4.7.
