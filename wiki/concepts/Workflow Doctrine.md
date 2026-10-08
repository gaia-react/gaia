---
type: concept
status: active
created: 2026-10-01
updated: 2026-10-08
tags: [concept, claude, workflow, doctrine]
---

# Workflow Doctrine

The workflow doctrine is one set of working rules for GAIA sessions, split into two halves by the moment each applies. [`.claude/rules/context-discipline.md`](../../.claude/rules/context-discipline.md) is the always-loaded half: a short, mode-neutral rule about keeping the main thread lean, fanning reads out, choosing models by fit, and keeping research output small. [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md) is the execution half: it is never auto-loaded, and a hook injects it verbatim the moment a session is on a working branch or in a linked worktree. This page holds the reasoning and the depth behind both.

The halves are split because guidance about executing biases a session toward action. In a discussion that bias is the reactivity failure the project CLAUDE.md names under "Before responding": a stimulus becomes a response before the stimulus is characterized. So a discussion session carries only context discipline, and execution doctrine arrives only when a branch exists, which is the signal that the work has moved from deciding to doing.

## Roles

The doctrine names four roles because each failure it guards against has a different owner. Read-only advisors investigate and write plan JSON, so wide reading never lands in the thread that has to decide. The main thread decides, because decisions need the whole picture and the user. Executors edit files and nothing else: a sub-agent that stages or commits works from a partial view, and several executors share one working tree, so one stray state-changing git command silently discards a sibling's edits. A verifier checks executor output against the plan JSON before the gate, so the gate runs once on work already known to match intent, not as a repair loop.

The main thread alone owns git that changes state, and runs the Quality Gate once per commit. Running it per executor multiplies a slow gate by the number of dispatches and checks half-built states nobody will commit. The operative wording lives in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md). When a running command defines its own contract, such as a plan orchestrator's per-phase commits or a debt fix's inline flow, that contract governs where it differs from the doctrine.

One agent is exempt from the executor and advisor limits. `audit-loop-unit`, dispatched by the main thread during the pre-merge audit, is the sanctioned depth-2 orchestrator: it runs state-changing git (commit and push of the fix rounds) and the Quality Gate for the rounds of its unit, because a fix round is a whole cycle of dispatch, fix, verify, gate and commit, and running it on the main thread charges every round's reading to the context that has to survive to the merge. The exemption is bounded from outside the agent: the deterministic verifier and the dispositions check stand behind every round, and a unit window recorded by the bound hook caps how many rounds it may open. The main thread still decides the checkpoint, the markers and the merge.

## Inline floor

Delegation has a fixed cost: a brief to write, a result to read back, and a context the sub-agent does not share. Small work, tightly iterative edit-run-fix work, and anything that needs the user stay on the main thread because the cost exceeds the gain. A platform limit makes this a floor, not a preference: a sub-agent cannot prompt the user, so a task that needs a question answered cannot be pushed down. Nesting is not such a limit: Claude Code lets a sub-agent spawn its own, three levels below the main conversation by default, set by `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`. GAIA still keeps delegation depth-1 by choice, so the main thread dispatches every sub-agent and sees every artifact it decides on. The audit loop is the one place depth-2 earns its cost, and `audit-loop-unit` is the sole exception: its rounds are numerous, mechanical to hand back as a thin report, and bounded by the hook-recorded unit window, so the main thread keeps the decisions while the per-round context stays below it. Nesting needs a Claude Code version that allows it; when a nested dispatch is unavailable the audit falls back to the main thread running its rounds inline.

## Model table

Models are ranked by fit to the task class. Cost is a secondary note, never the selector: choosing by price alone trades quality for a saving the measurements show is small.

| Task class | Model | Why it fits | Cost note |
| --- | --- | --- | --- |
| sweep | Sonnet | Wide reads and mechanical extraction return a small result; reasoning depth adds little. | Cache reads are about 97.5% of debt-run tokens and are priced the same on both top models, so moving a whole run to the cheaper model saves at most about a quarter. The smaller model's cache-read price is derived from the rate table, not measured. |
| scoped implementation | Sonnet | A bounded change with a written plan and a verifier behind it; the plan carries the judgment. | Same cache-read dominance as the sweep row; the saving is bounded by it. |
| synthesis | Opus (Fable as the named alternative) | Wording, positioning, and design decisions where one weak choice propagates into everything after it. | Priced at the top-model rates. Cache reads dominate here too, so the cost difference never outranks fit. |
| lookup, scaffold, mechanical | Haiku | The answer is fixed by a template, a rule id, or a written convention: scaffolding from a pattern, a fix keyed to a lint or accessibility rule id, a rule-based check. Reasoning depth adds nothing the template does not already carry. | Fit selects it and the lower price follows. A pin is a ceiling: an inline skill's pin holds for the rest of the turn it loads in, so a skill that triggers in the middle of general implementation work is not this class. |

Among the doctrine sources (the rule, `.claude/doctrine/execution.md`, and this page), the table is the only text edited when a model ships. A pin site is any other place that names a model for a skill, an agent, or one dispatch. Each follows the table and is re-checked against it in the same change.
<!-- gaia:maintainer-only:start -->
`.gaia/tests/hooks/workflow-doctrine-sources.bats` fails when a file that pins a model matches no entry below.
<!-- gaia:maintainer-only:end -->

### Pin sites

- Frontmatter `model:` in skills and agents: `.claude/skills/*/SKILL.md`, `frontend/.claude/skills/*/SKILL.md`, `.claude/agents/*.md`. A skill pins only for the lookup, scaffold, mechanical row; [[Deliberate Configuration Asymmetries]] records which skills pin and why.
- Dispatch pins in playbooks: `.claude/skills/gaia/references/plan.md` (the planner picker), `.claude/skills/gaia/references/plan/planner.md` (the executor pin), `.claude/skills/gaia/references/spec.md` (the model gate), `.claude/skills/gaia/references/audit.md`, `.claude/skills/gaia/references/fitness.md`, `.claude/skills/gaia/references/wiki.md` and its stage files `.claude/skills/gaia/references/wiki/*.md`, the update-deps wave and override-audit agents in `.claude/skills/update-deps/SKILL.md`, and the bump agents in `.claude/skills/update-gaia/SKILL.md`.
- Executed wiki pages: `wiki/concepts/PR Merge Workflow.md` (the fixer dispatch) and `wiki/decisions/Claude Integration Fitness.md` (the auditor table).
- Descriptive wiki pages that restate a pin: `wiki/concepts/GAIA Plan.md`, `wiki/concepts/GAIA Spec.md`, `wiki/concepts/Task Orchestration.md`, `wiki/concepts/Wiki Sync.md`, `wiki/concepts/Wiki Consolidate.md`, `wiki/decisions/Deliberate Configuration Asymmetries.md`.

## Run folder and checkpoint

Each branch gets one folder under `.gaia/local/runs/<key>/`, with the `branch:` prefix of the usage key dropped. One folder per key keeps two branches from clobbering each other's state, and the key is derived from the branch, so a returning session finds its own folder without being told where it is.

`STATE.md` is small and rewritten in place because append-only state files grew past any context window: a checkpoint that has to be read to be trusted must stay cheap to read. It records what is known, what each dispatch was expected to return, and one next step. Each dispatch writes one JSON artifact with its expected count recorded in `STATE.md`, so a missing or truncated artifact is detectable by counting rather than by guessing. `log.md` is append-only and never read on resume: it is a trace for a human, and loading it would reintroduce the growth the checkpoint exists to avoid. The operative layout is in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md), and the registry entry for the folder is in `.gaia/state-registry.json`.

## Resume

A resumed session reads `STATE.md` and the artifact listing and nothing else. The checkpoint says where the run stands, and the listing says which dispatches finished, so the two together answer "what next" without replaying the history that produced them. Reading more than that spends the context the run folder was built to protect. The steps are in [`.claude/doctrine/execution.md`](../../.claude/doctrine/execution.md).

## Concurrency limits

Every worktree shares one `.gaia/local`, which resolves into the main checkout. That is why run folders are keyed by branch and never shared between keys, and why research binding works through a Write made to the main checkout's absolute path and not through a path relative to the worktree.

The injection hook decides from the session's own tree. Two spellings therefore do not trigger injection: `git -C <path>` aimed at another tree, and `git worktree add` followed by `cd`. Entering a worktree through EnterWorktree does trigger it, because that tool reports the tree the session now works in.

## Initiative linking

A branch's spend is tied to the initiative it serves with `bash .gaia/scripts/usage.sh link branch:<normalized> research:<topic>-<date>`, or with `issue:<n>` when an issue is the anchor. The link is made once per branch. Issue edges the branch name already derives need no link: `debt/<n>` and the `(fix|feat|chore|docs|refactor)/<n>-` forms. The key line the hook injects carries the concrete command for the current key. See [[Usage Ledger]].

## Research attribution

A research Write binds to its initiative only when it is made with the Write tool to the main checkout's absolute `.gaia/local/research/<topic>-<date>/...` path. A worktree-relative path or a symlinked path does not bind. Research done with Edit or Bash binds with `bash .gaia/scripts/usage.sh declare research:<topic>-<date>`. A binding re-keys only `session:` spend, so spend already attributed to a branch or an issue stays where it is. The research ref is the full folder name, date included.

## Injection hook

`.claude/hooks/workflow-doctrine-inject.sh` injects the execution doctrine through `hookSpecificOutput.additionalContext`. It fires at SessionStart for all four sources (`startup`, `resume`, `clear`, `compact`), after EnterWorktree, and after a Bash call that runs `git checkout`, `git switch`, or `gh pr checkout`. For Bash the command only decides whether to look; the decision is the branch checked out afterwards, in the session's own tree. The hook registrations are described in [[Claude Hooks]].

A per-session marker holds the last injected key. `startup` and PostToolUse skip when the key is unchanged, `compact` and `clear` re-inject because the context they follow is gone, and a new key injects. A resumed session always re-injects, because the platform replays injected text but does not guarantee a resumed session still holds it. The hook fails open: any error, a missing or oversized doctrine file, or a CI environment produces no output and exit 0. The key line is omitted, never rewritten, when a branch name falls outside the ledger's ref grammar. Without jq only SessionStart injects and no marker is kept.

What the platform documents, as current behavior: `startup`, `resume`, `clear`, and `compact` are all SessionStart sources, and compaction fires SessionStart. PostToolUse `additionalContext` is documented generally, but the documentation does not state it for Bash or EnterWorktree specifically, so the mid-session triggers are best-effort and the SessionStart triggers are the guaranteed path. Injected text is saved in the transcript and replayed on resume; whether a resumed session keeps its `session_id` is not documented, which is why resume always re-injects.

<!-- gaia:maintainer-only:start -->

## Measurements

Re-measured with `bash .gaia/tests/hooks/workflow-doctrine-timing.sh`.

| Metric | Value | Budget |
| --- | --- | --- |
| p50 SessionStart, default branch | 31.6 ms | 50 ms |
| p50 SessionStart, working branch | 40.2 ms | 50 ms |
| p50 PostToolUse Bash, non-arming | 25.1 ms | 50 ms |
| p50 PostToolUse Bash, arming | 46.9 ms | 50 ms |
| Injected bytes | 3,084 | 4,096 |
| Injected tokens (bytes / 4) | 771 | none |
| Payload with a 128-character branch | 3,314 bytes | 4,096 |
| Rule bytes | 542 | 1,200 |
| Rule tokens (bytes / 4) | 135 | none |
| Per-session hook cost estimate | 843.4 ms | none |

The per-session estimate uses the median session's 32 Bash calls and 0 compactions.
<!-- gaia:maintainer-only:end -->

## See also

- [[Task Orchestration]]: the plan-specific case of this doctrine.
- [[Usage Ledger]]: the keys, links, and attribution the run folder and research rules rely on.
- [[Claude Hooks]]: how the injection hook is registered.
- [[Quality Gate]]: the gate the main thread runs once per commit.
- [[GAIA Plan]]: the command that applies the doctrine to a planned run.
