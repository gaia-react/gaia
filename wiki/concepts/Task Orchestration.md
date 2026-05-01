---
type: concept
status: active
created: 2026-04-21
updated: 2026-05-01
tags: [concept, claude, workflow]
---

# Task Orchestration

Invoked via `/gaia plan [description]` — see [[GAIA Plan]] for the skill surface. For implementation work involving multiple files or subsystems, Claude generates a plan + orchestrator structure under `.claude/plans/{slug}/` so each piece of work runs in a fresh-context sub-agent and the orchestrator drives the whole thing end-to-end.

## Plan artifacts

1. **Per-task docs** in `.claude/plans/{slug}/` — self-contained for fresh-context sub-agents (context, dependencies, interface contracts, files to touch, acceptance criteria).
2. **`README.md`** with the task graph (phases + parallelism) and frozen interface contracts.
3. **`ORCHESTRATOR.md`** — full execution playbook: pre-flight branch policy, phase order with per-phase quality gates (`pnpm typecheck && pnpm lint`), sub-agent prompt template, orchestrator-owned git flow (commits, pushes, PR), stop conditions, the mandatory final summary, and a final self-cleanup phase.
4. **`KICKOFF.md`** — a self-contained prompt the orchestrator reads to start cold. The `/gaia plan` skill copies the matching `Read … KICKOFF.md and execute it.` resume prompt to the system clipboard (probing `pbcopy` / `wl-copy` / `xclip` / `xsel` / `clip.exe` / `clip`) and prints it as a fenced block either way.

## Execution lifecycle

When the user pastes the resume prompt, the orchestrator runs through:

1. **Pre-flight.** Clean working tree check. Branch policy: if HEAD is on `main`/`master`, the orchestrator asks the user whether to create a feature branch or a git worktree. Otherwise, it assumes the current branch is the work branch.
2. **Phase loop.** For each phase: dispatch sub-agents in parallel (sub-agents only edit files — they do NOT commit or push), wait for all to report, run the per-phase quality gate (`pnpm typecheck && pnpm lint`), then the orchestrator stages, commits with a meaningful message, and pushes. The PR is opened (via `gh pr create`) once the first phase's commit lands on the remote, and updated with subsequent commits.
3. **Stop conditions.** Any sub-agent failure or quality-gate failure halts the run — the orchestrator surfaces the error to the user and does NOT commit, push, or "fix and continue."
4. **Final summary.** After the last commit lands and before awaiting merge confirmation, the orchestrator prints a brief summary: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, and quality-gate status. A few lines, not a recap of every change.
5. **Final self-cleanup.** After all implementation phases pass and the user confirms the PR is ready to merge, the orchestrator deletes its own plan folder (`rm -rf .claude/plans/{slug}/`) so scaffolding does not persist locally. If `.claude/plans/` is gitignored (the GAIA default — checked via `git check-ignore`), the deletion is invisible to git and no commit is needed. If the path is tracked, the orchestrator commits and pushes the deletion as the **final commit on the PR**. If the user explicitly asks to keep the folder for archival, the orchestrator skips the deletion and reports.

## Why

- Keeps each sub-agent's context focused.
- Avoids massive multi-file edits in one pass.
- User can review the plan before committing compute.
- Individual tasks are resumable / re-runnable.
- The orchestrator owning git means commit history reflects phase boundaries cleanly, and broken state never reaches the remote.

See [[GAIA Plan]], [[Quality Gate]], [[PR Merge Workflow]].
