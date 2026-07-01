---
type: concept
status: active
created: 2026-04-21
updated: 2026-06-24
tags: [concept, claude, workflow]
---

# Task Orchestration

Invoked via `/gaia-plan [description]`; see [[GAIA Plan]] for the skill surface. For implementation work involving multiple files or subsystems, Claude generates a plan + orchestrator structure under `.gaia/local/plans/{slug}/` so each piece of work runs in a fresh-context sub-agent and the orchestrator drives the whole thing end-to-end.

## Plan artifacts

1. **Per-task docs** in `.gaia/local/plans/{slug}/`: self-contained for fresh-context sub-agents (context, dependencies, interface contracts, files to touch, acceptance criteria).
2. **`README.md`** with the task graph (phases + parallelism) and frozen interface contracts.
3. **`ORCHESTRATOR.md`**: full execution playbook: pre-flight branch policy, phase order with per-phase quality gates (`pnpm typecheck && pnpm lint`), sub-agent prompt template, orchestrator-owned git flow (commits, pushes, PR), stop conditions, the phase findings ledger contract, the mandatory final summary, and a final self-cleanup phase.
4. **`KICKOFF.md`**: a self-contained prompt the orchestrator reads to start cold. The `/gaia-plan` skill prints the single-line resume prompt (`Read <abs-path>/.gaia/local/plans/{slug}/KICKOFF.md and execute it.`) as a fenced code block for the user to copy manually, followed by a `Type /clear and paste the prompt above.` instruction.

`SUMMARY.md` is a runtime artifact (not authored at plan-write time): the orchestrator creates and appends to it as phases complete (see lifecycle step 2 below). It is removed with the rest of the plan folder during final self-cleanup.

## Execution lifecycle

When the user pastes the resume prompt, the orchestrator runs through:

1. **Pre-flight.** Clean working tree check. Branch policy: if HEAD is on `main`/`master`, the orchestrator asks the user whether to create a feature branch or a git worktree. Otherwise, it assumes the current branch is the work branch.
2. **Phase loop.** For each phase: dispatch sub-agents in parallel (sub-agents only edit files; they do NOT commit or push), wait for all to report, run the per-phase quality gate (`pnpm typecheck && pnpm lint`), then the orchestrator stages, commits with a meaningful message, and pushes. The PR is opened (via `gh pr create`) once the first phase's commit lands on the remote, and updated with subsequent commits. After committing, the orchestrator appends a `## Phase N - <title>` block to `SUMMARY.md` containing the phase commit SHA and the merged `Notes for orchestrator` content from every sub-agent in the phase (findings, deviations from plan, follow-ups). Sub-agents emit those notes as a structured section at the end of their return; the orchestrator merges and writes; sub-agents do not write to `SUMMARY.md` directly. This append-only ledger is the durable record that survives context compression across long runs.
3. **Stop conditions.** Any sub-agent failure or quality-gate failure halts the run; the orchestrator surfaces the error to the user, appends a `## Phase N - <title> (HALTED)` block to `SUMMARY.md` with the failure context, and does NOT commit, push, or "fix and continue."
4. **Final summary.** After the last commit lands and before awaiting merge confirmation, the orchestrator reads `SUMMARY.md` and prints a brief summary: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, quality-gate status, and the highest-signal findings/deviations/follow-ups drawn from the ledger so nothing is lost to compression. A few lines plus the surfaced notes, not a recap of every change.
5. **Final self-cleanup.** After all implementation phases pass and the user confirms the PR is ready to merge, the orchestrator deletes its own plan folder (`rm -rf .gaia/local/plans/{slug}/`) so scaffolding does not persist locally. If `.gaia/local/plans/` is gitignored (the GAIA default, checked via `git check-ignore`), the deletion is invisible to git and no commit is needed. If the path is tracked, the orchestrator commits and pushes the deletion as the **final commit on the PR**. If the user explicitly asks to keep the folder for archival, the orchestrator skips the deletion and reports.

## Topology

GAIA orchestration is a depth-1 star: the main thread is the only agent that spawns, and every worker it dispatches is a leaf. Claude Code sub-agents cannot spawn further sub-agents and cannot prompt the user, so a worker never owns a team and never runs an interactive gate.

- **`/gaia-plan`** runs its thin orchestration on the invoking thread and spawns one planner leaf for the deep synthesis. The planner investigates with parallel tool calls and writes the plan files; it does not spawn sub-agents.
- **The execution orchestrator** (a fresh session started from `KICKOFF.md`) is itself a main thread, so it dispatches the per-phase implementation sub-agents as leaves and runs the pre-merge `code-review-audit`.
- **`/gaia-spec`** ends by printing a `/gaia-plan` handoff prompt and stops; it spawns nothing downstream. The human runs `/gaia-plan` in a fresh session, where the planner is the single spawned leaf.

Models pin at spawn, so the main thread, even on Sonnet, puts the synthesis on Opus by spawning the planner with `model: opus`. Interactive steps stay on the main thread because only it can prompt.

## Why

- Keeps each sub-agent's context focused.
- Avoids massive multi-file edits in one pass.
- User can review the plan before committing compute.
- Individual tasks are resumable / re-runnable.
- The orchestrator owning git means commit history reflects phase boundaries cleanly, and broken state never reaches the remote.

See [[GAIA Plan]], [[Quality Gate]], [[PR Merge Workflow]].
