---
type: concept
title: GAIA Plan
status: active
created: 2026-04-30
updated: 2026-06-24
tags: [concept, claude, skill, orchestration]
---

# GAIA Plan

`/gaia-plan [description]` plans a complex feature using GAIA's [[Task Orchestration]] pattern, without implementing anything. The skill lives at `.claude/skills/gaia/references/plan.md` (dispatched by the `/gaia-plan` command, which reads this reference).

## Steps

1. **Get description.** Use `$ARGUMENTS` if provided; otherwise ask "What do you want me to orchestrate?" and wait.
2. **Pick the planner model.** The planner's model is pinned at spawn, so it runs on Opus even when the session is on Sonnet. If the session is on Opus, the planner inherits it. When the run is non-interactive (e.g. dispatched by `/gaia-spec auto`), the planner defaults to Opus without a prompt. Otherwise ask via `AskUserQuestion` whether to use Opus for planning, with "Use Opus (Recommended)" as the default option and "keep the current model" as the alternative.
3. **Spawn the planner.** Launch a `general-purpose` Agent with the chosen model and a prompt that builds the plan files in `.gaia/local/plans/{slug}/`: per-task docs, `README.md` (task graph + frozen interface contracts), `ORCHESTRATOR.md` (execution playbook), and `KICKOFF.md` (the cold-start prompt). The planner is a leaf sub-agent: it investigates with parallel tool calls and writes the files, and it cannot spawn further sub-agents (see [[Task Orchestration#Topology]]). See [[Task Orchestration]] for the artifact contract.
4. **Hand off.** Print a short summary of the plan, then a fenced one-line resume prompt (`Read /abs/path/to/.gaia/local/plans/{slug}/KICKOFF.md and execute it.`). The skill prints the prompt as a fenced code block, then a single trailing `Type /clear and paste the prompt above.` line.

## Orchestrator contract

`ORCHESTRATOR.md` mandates a brief **final summary** before awaiting merge confirmation: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, and quality-gate status. A few lines, not a recap of every change. The final self-cleanup phase (deleting `.gaia/local/plans/{slug}/`) only runs after the user confirms the PR is ready to merge; see [[Task Orchestration]] for the gitignored-vs-tracked branching.

## Pairs with

- [[Task Orchestration]]: the underlying pattern, plan-folder layout, and execution lifecycle.
- [[Quality Gate]]: runs between phases.
- [[PR Merge Workflow]]: final gate before merge.
