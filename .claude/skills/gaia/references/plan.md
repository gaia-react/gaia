# /gaia-plan

Plan a complex feature using the task orchestration pattern. Do not implement anything.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `plan`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want me to orchestrate?"** and wait for the response before continuing.

#### 1a. Detect SPEC reference

Check the description for a SPEC reference. The canonical form (emitted by `/gaia-spec`) is:

    SPEC-NNN: <intent first line>, see .gaia/local/specs/SPEC-NNN/SPEC.md

Match either pattern:

- A path matching `.gaia/local/specs/SPEC-\d+/SPEC\.md`
- A `SPEC-\d+:` prefix at the start of the description

If matched:

1. Read the referenced SPEC file. Its full content is the source-of-truth feature description; the short string passed via `$ARGUMENTS` is just the dispatch summary.
2. Extract the SPEC id (e.g. `SPEC-005`). Cache the lowercased form (`spec-005`) as `SPEC_SLUG_SEED` for use in step 4's branch-naming policy.
3. Cache the absolute SPEC path as `SPEC_PATH` for use in the planner prompt (step 4), the planner will reference it in `README.md`.

If no SPEC reference is detected, `SPEC_SLUG_SEED` and `SPEC_PATH` are unset; step 3 allocates a `PLAN-NNN` id from the local ledger for the spec-less plan.

Colocated plans no longer use `SPEC_SLUG_SEED` to prefix a `plans/` slug, the plan lives inside the SPEC folder, so plan→SPEC discovery is structural. It is retained for the branch-name marker (step 4's branch policy) and human-facing labels. `SPEC_PATH` additionally seeds `SPEC_DIR` (its parent directory) for plan-directory resolution in step 3.

### 2. Check model

The deep synthesis runs in the planner spawned at step 4, and the planner's model is pinned at spawn time, so it can be Opus even when this orchestration runs on Sonnet. Decide the planner's model:

- If you are on Opus, the planner inherits Opus; skip to step 3.
- If you are running non-interactively (a headless or automation context with no interactive user to prompt), default the planner to Opus: spawn it with `model: opus` at step 4. Skip to step 3.
- Otherwise call `AskUserQuestion` with:
  - question: `"You're on [model name]. Use Opus for planning?"`
  - header: `"Model"`
  - options:
    - `{ label: "Use Opus (Recommended)", description: "Spawn the planning agent on Opus for higher-quality plans." }`
    - `{ label: "Use [model name]", description: "Keep the current model." }`
  - If the user picks option 1: spawn the agent with `model: opus`.
  - If the user picks option 2: spawn without a model override (inherit current).

This decision governs the **planner** only. The plan's **execution** sub-agents are a separate decision: they default to Sonnet, pinned in the `ORCHESTRATOR.md`/`KICKOFF.md` the planner writes (see step 4's Sub-agent invocation bullet). Do not conflate the two.

### 3. Resolve plan directory

**Spec-derived plans colocate inside their SPEC folder**, at `<SPEC_DIR>/plan[-N]` where `SPEC_DIR` is the SPEC's parent directory (`.gaia/local/specs/<SPEC-ID>`); the plan basename is `plan`, not a slug. Plan→SPEC discovery is structural, the plan IS inside `specs/<SPEC-ID>/`, no slug prefix needed. **Spec-less plans live under `plans/PLAN-NNN`, where `PLAN-NNN` is a monotonic id allocated from the local `plans/ledger.json` ledger** (the same treatment SPECs get). The description lives in the ledger `subject`, not the folder name.

Resolve the absolute plan directory, then create it. The spec-derived arm suffixes `-2`, `-3`, … if a colocated plan folder already exists; the spec-less arm allocates a fresh `PLAN-NNN`, so it never collides:

```bash
ROOT="$(git rev-parse --show-toplevel)"
if [[ -n "${SPEC_PATH:-}" ]]; then
  # Spec-derived: colocate the plan inside its SPEC folder.
  SPEC_DIR="$(dirname "$SPEC_PATH")"          # .../.gaia/local/specs/SPEC-NNN
  PLAN_DIR="${SPEC_DIR}/plan"
  n=2
  while ! mkdir "$PLAN_DIR" 2>/dev/null; do
    PLAN_DIR="${SPEC_DIR}/plan-${n}"
    n=$((n+1))
  done
else
  # Spec-less one-off: allocate a monotonic PLAN-NNN from the local ledger.
  # The allocator's union counts existing folders, so it always returns a fresh
  # number; no collision-suffix loop needed.
  DESCRIPTION="<feature description from step 1>"
  PLAN_ID="$(bash .specify/extensions/gaia/lib/plan-allocator.sh next "$ROOT" "$DESCRIPTION")"
  PLAN_DIR="${ROOT}/.gaia/local/plans/${PLAN_ID}"
  mkdir -p "$PLAN_DIR"
fi
```

Cache the resolved absolute `PLAN_DIR`; interpolate it into the planner prompt below and the kickoff prompt in step 5. The collision suffix lets parallel `/gaia-plan` invocations coexist on the spec-derived arm without overwriting each other; the spec-less arm no longer collides, the allocator serializes concurrent callers under a mutex.

### 4. Spawn planning agent

Launch a `general-purpose` Agent with the model determined above and this prompt. Interpolate every `{PLAN_DIR}` token with the absolute path resolved in step 3. If `SPEC_PATH` was set in step 1a, interpolate every `{SPEC_PATH}` token with that absolute path; if unset, delete the `**Source SPEC**` paragraph below before sending.

---

You are planning a feature using task orchestration. Do not implement anything. Investigate the codebase, then write the plan files directly to disk. You are a leaf subagent and cannot spawn further subagents; parallelize investigation with parallel tool calls (batch reads and greps in one step), not sub-agent dispatch.

**Plan directory:** `{PLAN_DIR}`

**Source SPEC:** `{SPEC_PATH}`, read this file FIRST. Its `intent`, `UATs`, and `clarifications.answered[]` are authoritative for what to plan; the dispatch summary in `Feature:` below is just a label. Reference the SPEC id in `README.md`'s `## Source SPEC` section.

**Write rules.**

- You may write only under `{PLAN_DIR}/`. Never edit source files, configs, or anything outside this directory.
- Final plan artifacts go directly under `{PLAN_DIR}/` (no subdirectories for deliverables).
- For ephemeral scratch (mid-investigation notes, intermediate research dumps), create a unique subdirectory under `{PLAN_DIR}/.work/` via `mktemp -d "{PLAN_DIR}/.work/<role>.XXXXXX"`. Never write directly to `.work/` itself. Delete your scratch subdir before returning; the parent also runs a defensive cleanup of `{PLAN_DIR}/.work` after you return, as belt-and-suspenders.

**Feature:** {feature description from step 1}

First, read `wiki/concepts/Task Orchestration.md`.

**Never author a manifest-registration task.** `.gaia/manifest.json` is release-generated and lists only files GAIA ships; adopter feature work never adds to it, and a file's absence from the manifest is not `/update-gaia` drift (a path absent from the manifest is adopter-owned and invisible to the update). See `.claude/rules/manifest.md`.

Then write the following files directly to `{PLAN_DIR}/`:

1.  **One task doc per parallel workstream**: `{PLAN_DIR}/task-{name}.md`. Each must be fully self-contained for a fresh-context sub-agent and include:
    - Context and motivation
    - Interface contracts (types, function signatures, file exports)
    - Files to touch (with line-range hints where possible)
    - Acceptance criteria (concrete and testable)
    - Dependencies on other tasks in this plan

2.  **`{PLAN_DIR}/README.md`**: task graph showing phases, which tasks run in parallel within each phase, and the frozen interface contracts shared across tasks. **Annotate each phase with its execution model** (e.g. `Phase 1 (2 sub-agents, model sonnet)`); Sonnet is the default, so call out any phase you escalate to Opus explicitly and briefly say why. **If `{SPEC_PATH}` was provided** (i.e. this plan was derived from a SPEC), the README MUST open with a `## Source SPEC` section naming the SPEC id and the absolute path, so plan→SPEC discovery is one read away. Format: `Derived from {SPEC-id} ({SPEC_PATH}).`

3.  **`{PLAN_DIR}/ORCHESTRATOR.md`**: instructions for running the plan. Must cover:
    - **RUNNING sentinel.** As the very first step, write a sentinel file at `{PLAN_DIR}/RUNNING`. Content:

      ```
      branch: <output of git branch --show-current>
      slug: <basename of {PLAN_DIR}>
      started: <current UTC time, ISO 8601, e.g. 2026-05-19T14:32:00Z>
      ```

      This file is deleted automatically when the plan directory is archived during final self-cleanup (RUNNING is not one of the two files the archive keeps, `SUMMARY.md` and `cost.md`). Its purpose: it marks this plan as the branch's active run, which the execute-phase token-tally hooks (`.claude/hooks/lib/gaia-active-plan.sh`, `.claude/hooks/token-tally-git-op.sh`) read to key each commit's tally to the right feature.

    - **Pre-flight branch policy.** Check the current branch.

      **If HEAD is on `main`/`master`:** Ask the user how to isolate the work via `AskUserQuestion`:
      - question: `"On main. How should this plan's work be isolated?"`
      - header: `"Branch mode"`
      - options (in this exact order):
        1. `{ label: "Create a feature branch in place (Recommended)", description: "Default. Branch is cut from HEAD and the orchestrator works in the current checkout. Simple, predictable, safe." }`
        2. `{ label: "Create a git worktree", description: "Gives this plan its own separate working copy, cut from main under .claude/worktrees/. You can keep working on your current branch, or run another plan, at the same time without the two colliding." }`

      Do not silently default; the prompt fires every time HEAD is `main`/`master`. If the user picks "Other" with custom text, treat it as a request for an alternative isolation mode and surface a clarifying question rather than guessing, feature-branch and worktree are the two supported modes.

      **Branch naming (FC-5).** Whichever isolation mode runs, including the forced worktree on the not-on-main path, when this plan is spec-derived (`SPEC_PATH` was set in step 1a) the branch name MUST begin with `${SPEC_SLUG_SEED}-` (e.g. `spec-005-cards-layout`), so `spec-reconcile.sh` flips the SPEC's ledger row to `merged` after the PR merges. A colocated plan's folder basename (`plan`) no longer carries that marker, so the branch name is now the only place it survives. For a spec-less plan, name the branch from the plan slug as today.

      **If HEAD is on any other branch:** Do not offer the feature-branch-in-place mode. Because you are already on a branch, this plan's work goes into its own git worktree cut from main, so it does not get tangled with your current branch's work. State that to the user in one line, then proceed straight into **Worktree creation** below (the same path as choosing worktree from main). No `AskUserQuestion` fires here, worktree-off-main is the only isolation mode when starting from a branch.

    - **Worktree creation (worktree-mode runs only).** When the pre-flight selects worktree mode, chosen from `main` or forced on the not-on-main path, create the worktree with the runtime tool, passing the FC-5 branch name as the worktree name:

          EnterWorktree({name: "<branch-name>"})

      The `WorktreeCreate` hook (`.gaia/scripts/create-worktree.sh`) owns creation: it cuts a new branch of that name fresh from the remote default branch (`main`), else local HEAD, lands it under `.claude/worktrees/<branch-name>/`, and switches the session into that worktree. The branch is already cut, so the orchestrator runs no manual `git checkout -b`. Every later step, task sub-agent edits, per-phase commits, `gh pr create`, and the pre-merge `code-review-audit`, runs from inside the worktree.

      **The plan folder stays in the main checkout.** The worktree shares only a fixed set of gitignored state with the main checkout by symlink (`.gaia/cache/`, `.gaia/local/audit/`, `.gaia/local/telemetry/`, `setup-state.json`, `mentorship.json`); the plan folder is not among them, so `{PLAN_DIR}` exists only in the main checkout. Read the task docs and `README.md` from `{PLAN_DIR}` (its main-checkout absolute path) and write `SUMMARY.md` there, while each task edits the worktree's own copy of the tracked files it touches. Dispatch each task sub-agent with both: the worktree's absolute path for the file to edit, and `{PLAN_DIR}` for the docs to read. Run `plan-archive.sh {PLAN_DIR}` only after `ExitWorktree` returns the session to the main checkout, so the helper's repo-root guard resolves the main checkout rather than the worktree.

    - **Phase order** with per-phase quality gates (`pnpm typecheck && pnpm lint`). Name each phase's execution model in the outline (Sonnet by default; see the Sub-agent invocation bullet), so a cold orchestrator sees the model alongside the phase.
    - **Pre-merge `code-review-audit` (non-skippable).** Before any `gh pr merge` call, the orchestrator spawns the `code-review-audit` agent on the current branch. The agent's clean pass writes `.gaia/local/audit/<HEAD-sha>.ok`, which the deny-hook (`.claude/hooks/pr-merge-audit-check.sh`) gates `gh pr merge` on. The orchestrator does NOT wait for the deny-hook to fire and learn from it, that round-trip is friction. Spawn the agent proactively. Contract: `wiki/concepts/PR Merge Workflow.md`. Verbatim agent-spawn template:

          Task(
            subagent_type="code-review-audit",
            prompt="Review all changes in the current branch compared to main. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities."
          )

      If the agent does not write its clean-pass marker, the orchestrator surfaces the report's open findings (the agent's own tiers: Critical, unresolved Important, or unaddressed/escalated Suggestion), stops, and lets the user decide whether to fix and re-audit or abandon. The marker handshake is the gate; do not hand-write the marker. If the audit agent declines to write the marker, the report names what remains unaddressed; resolve those, commit, push, re-spawn, exactly as the contract specifies.

      The audit's LOCAL Task return is terse (pointer + counts + marker line); the full per-finding detail lives in the re-run carry-forward ledger (`.gaia/local/audit/<base-sha>.rerun.json`). To surface the open findings, the orchestrator reads the ledger's `remaining[]` (enumerating Critical, Important, and escalated Suggestions for the user) instead of expecting a full inline report. Fail-open: if the ledger is absent, corrupt, or stale, the audit's return carries the full report (it emits the full report whenever it could not write the ledger), so the orchestrator surfaces the open findings from that report as today.

    - **Sub-agent invocation:** the verbatim prompt template for each task sub-agent. **Each task sub-agent MUST be dispatched as `general-purpose` with `model: "sonnet"` explicitly pinned.** The feature's complexity is resolved upstream, during `/gaia-spec` + its audit and `/gaia-plan` + the decomposition audit, precisely so execution can run on the cheaper model. Pin Sonnet on the dispatch itself so the executors run on Sonnet regardless of the orchestrator's own session model: a cold orchestrator is often on Opus, and an unpinned sub-agent inherits that. **Escape hatch:** the planner MAY pin `model: "opus"` on a specific phase or task it judges to be genuinely deep synthesis (a subtle parser grammar, a cross-cutting type redesign), but must name which phase and why in that phase's `ORCHESTRATOR.md` entry. Sonnet is the floor; Opus is a per-phase, justified exception, never the blanket default. Sub-agents do NOT commit, push, or open/update the PR, they only edit files and report. The orchestrator owns all git operations. **The prompt template MUST require sub-agents to end their return with a `## Notes for orchestrator` section** containing any of: `### Findings` (non-obvious things they noticed), `### Deviations from plan` (where the task spec was wrong / they had to work around it), `### Follow-ups` (work the user should consider after merge). Subsections may be empty or omitted; only non-trivial signal belongs here, routine "phase done, tests green" status does NOT.
    - **Orchestrator-owned git flow.** After each phase that produces changes (and only once the quality gate is clean), the orchestrator stages, commits with a meaningful message, and pushes. The orchestrator opens the PR after the first phase's commit lands on the remote (using `gh pr create`) and updates it with subsequent commits. Never commit a broken state.
    - **Phase findings ledger (`{PLAN_DIR}/SUMMARY.md`).** Append-only file the orchestrator maintains across the run, so sub-agent observations survive context compression. After each phase, the orchestrator appends a `## Phase N, <title>` block containing the phase's commit short-SHA and the merged `Notes for orchestrator` content from every sub-agent in that phase. If a phase produced no notes (all sub-agents reported only routine status), append the phase heading with `_No notes._` so the ledger reflects the full run. Sub-agents do not write to this file directly; the orchestrator owns it.
    - **Stop conditions.** On any sub-agent failure or quality-gate failure: STOP and surface to the user. Do not "fix and continue", do not commit, do not push. Before stopping, append the failure context (which phase, which sub-agent, error) to `SUMMARY.md` under a `## Phase N, <title> (HALTED)` block so the user and any follow-up session see the same record.
    - **Final summary.** After all implementation phases pass and the final commit is pushed, before awaiting merge confirmation, **read `{PLAN_DIR}/SUMMARY.md`** and print a brief summary to the user: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, quality-gate status, and the highest-signal findings/deviations/follow-ups drawn from `SUMMARY.md` so nothing is lost to context compression. Keep it tight, a few lines plus the surfaced notes, not a recap of every change.

      **Token tally (execute-time).** Execute-phase token tallies are recorded automatically: a `PreToolUse` hook on the orchestrator's per-phase git commit/push records this session's execute tally to the durable ledger, keyed to the feature (the SPEC id resolved from the active plan folder, or the plan slug when spec-less). Resumed, halted, and worktree sessions are all captured. The orchestrator does not run a manual execute tally, doing so would double-count the phase.

      After the pre-merge `code-review-audit`'s clean-pass marker is written and before the Final self-cleanup phase archives the plan folder, the orchestrator reports the full-cycle cost by running the roll-up reader and surfacing its spec / plan / execute / total breakdown plus wall-clock elapsed to the user. Substitute the plan's real SPEC id (from the `## Source SPEC` section of `README.md`, or the plan slug if the plan has no SPEC, the spec-less case):

      ```bash
      if [ -x .gaia/scripts/token-rollup.sh ]; then
        bash .gaia/scripts/token-rollup.sh \
          --spec-id "<SPEC-NNN from README's Source SPEC, or the plan slug if none>" || true
      fi
      ```

      A `PostToolUse` hook on `gh pr merge` renders the same roll-up at the merge boundary, so the readout also appears when the merge runs from a fresh top-level session. The reader never blocks and never fabricates a number: the `-x` guard and trailing `|| true` mean a missing or failing helper degrades silently, and an unreadable ledger degrades to a partial or absent figure with a marker.

    - **Final self-cleanup phase (last step before merge).** After all implementation phases pass and the user confirms the PR is ready to merge, the orchestrator **archives** its own plan folder instead of deleting it, preserving `SUMMARY.md` and `cost.md`. Run:

      ```bash
      bash .gaia/scripts/plan-archive.sh {PLAN_DIR}
      ```

      The argument is the plan dir. Pass the cached `{PLAN_DIR}` (absolute) directly, the helper normalizes an absolute-under-repo path to repo-relative. A repo-relative literal (`.gaia/local/specs/<SPEC-ID>/plan[-N]` or `.gaia/local/plans/<slug>[-N]`) is equally valid. Unlike the old literal-`rm` self-cleanup, the argument shape does NOT affect the permission match here: the allow entry `Bash(bash .gaia/scripts/plan-archive.sh:*)` uses a `:*` wildcard that matches any argument.

      This prunes everything except `SUMMARY.md` and `cost.md`, then: for a spec-less plan under `.gaia/local/plans/<slug>/` moves the pruned folder to `.gaia/local/plans/archived/<slug>/`, with a `## Total` appended to `cost.md`; for a spec-colocated plan under `.gaia/local/specs/<SPEC-ID>/plan/` prunes in place (the SPEC folder is the archival unit). When the SPEC folder is later archived, a shared routine consolidates and flattens: it folds the SPEC-root `cost.md`'s `## SPEC` section together with the plan's `## Planning` + `## Execution` into one `## SPEC` + `## Planning` + `## Execution` + `## Total` document at the SPEC root, moves `SUMMARY.md` up beside it, and removes the now-empty `plan/` subfolder, so the archived SPEC folder never nests a `plan/`. The helper always exits 0.

      Then check `git check-ignore .gaia/local/plans/` (and, for a colocated plan, `git check-ignore .gaia/local/specs/`): both are gitignored under the GAIA default, so the prune+move is invisible to git, skip the commit and report "plan folder archived locally; gitignored, no commit needed." If a path is tracked, commit and push the move as the final commit on the PR. If the user explicitly asks to keep the plan folder un-archived, skip and report.

      The `SUMMARY.md`/`cost.md` content was already surfaced in the Final summary, and now additionally persists on disk.

    - **Post-merge worktree cleanup (worktree-mode runs only).** When the orchestrator's pre-flight chose worktree mode (or the run was dispatched into a worktree by upstream tooling), the post-merge phase runs the cleanup procedure below AFTER the user confirms the PR is merged. The procedure detects the squash-merge state and discards the worktree without prompting (the SPEC clarifications.answered confirms pre-consent: the orchestrator told the user "after merge, the worktree will be discarded" before opening the PR; the user merging the PR is the consent).
      1. Confirm merge via `gh pr view <N> --json state`. Parse the JSON; require `.state == "MERGED"`. If not merged, do NOT proceed, surface to user and stop.
      2. **Isolation-context check (see next bullet).** If the orchestrator is running inside an isolated subagent context, emit a continuation prompt and STOP, do NOT call `ExitWorktree`.
      3. Otherwise, call `ExitWorktree({action: "remove", discard_changes: true})` directly. `discard_changes: true` is safe and correct: a squash-merge absorbs every commit on the worktree branch, but those commits are not reachable as ancestors of `main`. Without `discard_changes: true` the runtime conservatively refuses, treating the unreachable commits as unsynced work. The merged-state confirmation in step 1 proves the work is preserved.
      4. Report a one-line success: `worktree discarded; PR #<N> squash-merged as <short-sha>`.

      Never call `ExitWorktree` first and treat its refusal as the trigger for the discard retry, that's the backstop pattern this section replaces. The merged-state confirmation is the primary signal source.

    - **Isolation-context detection (worktree-mode runs only).** The runtime refuses `ExitWorktree` calls from agents dispatched with `isolation: "worktree"` or any `cwd` override (the refusal text is `ExitWorktree cannot be called from a subagent with a cwd override`). Before calling `ExitWorktree`, the orchestrator detects this context. Detection signal (v1):
      - **Primary signal:** the orchestrator was invoked via `Agent(...)` with `isolation: "worktree"`. The orchestrator knows this if its dispatch was a sub-agent task (i.e. the kickoff prompt was passed to a Task / Agent call from a parent session) AND the cwd is a worktree path. If the orchestrator can read the runtime's session metadata to confirm isolation directly, it does so; otherwise it heuristically checks: if `pwd` resolves to a path under `.claude/worktrees/` AND the parent session that launched the orchestrator is unknown, treat as isolated.
      - **Fallback:** if uncertain, attempt `ExitWorktree({action: "remove", discard_changes: true})` and check the runtime response. If the response contains `cannot be called from a subagent`, treat the call as never-issued (it's a refusal, not a destructive action), branch into the continuation-prompt path, and STOP. (This is the only place the orchestrator may use the deny-as-signal pattern; everywhere else, proactive detection is required.)

      When detected, the orchestrator does NOT call `ExitWorktree`. It emits this copy-paste continuation prompt to the user, then stops:

          The worktree at <ABSOLUTE-PATH-TO-WORKTREE> is ready to discard.
          PR #<N> squash-merged as <short-sha>. From a fresh top-level Claude
          Code session rooted at <ABSOLUTE-PATH-TO-MAIN-CHECKOUT>, call:

              ExitWorktree({worktree: "<ABSOLUTE-PATH-TO-WORKTREE>", discard_changes: true})

      No error surfaced. No `ExitWorktree` invocation in this branch. The continuation prompt is self-contained, the user pastes it into a new session and the cleanup completes without further investigation.

4.  **`{PLAN_DIR}/KICKOFF.md`**: the orchestrator's kickoff prompt itself, ready to be read and executed verbatim. The file is the prompt, no preamble, no "copy and paste below" instruction, no surrounding commentary, no `---` separators framing the prompt as a quoted block. The opening line addresses the orchestrator directly (e.g. "You are the orchestrator for the {feature} plan…"). Must be fully self-contained with no assumed context: absolute paths to `README.md` and `ORCHESTRATOR.md`, the goal, hard rules, and the execution outline. The kickoff also includes a one-line reference to the pre-merge `code-review-audit` obligation (e.g. "Before any `gh pr merge`, run the `code-review-audit` agent, see ORCHESTRATOR.md's Pre-merge code-review-audit section.") and a one-line default-execution-model statement (e.g. "Dispatch each task sub-agent as `general-purpose` with `model: \"sonnet\"` unless ORCHESTRATOR.md's phase list escalates that phase to Opus."). Both lines ensure a cold-started orchestrator reads the requirement before doing any work, surviving any context compression that drops the ORCHESTRATOR.md content from the first read.

Before returning, delete `{PLAN_DIR}/.work/` if you created it. Use the literal repo-relative path so the project's `rm -rf .gaia/local/plans/*` permission (spec-less plans) or `rm -rf .gaia/local/specs/*` permission (colocated plans) auto-approves it without a prompt: `rm -rf <repo-relative PLAN_DIR>/.work`, e.g. `rm -rf .gaia/local/plans/<slug>/.work` or `rm -rf .gaia/local/specs/<SPEC-ID>/plan/.work`. Do not reconstruct an absolute path from variables, which misses that match and trips the empty-variable rm guard.

**Return format (required).** Return only a small structured payload, no file contents, no recap of what's inside the files. The parent reads the files itself if it needs to.

    Plan directory: {PLAN_DIR}
    Files written:
      - {PLAN_DIR}/README.md
      - {PLAN_DIR}/ORCHESTRATOR.md
      - {PLAN_DIR}/KICKOFF.md
      - {PLAN_DIR}/task-<name1>.md
      - {PLAN_DIR}/task-<name2>.md
      ...
    Kickoff path: {PLAN_DIR}/KICKOFF.md

---

### 4.5. Verify the planner's output

After the planner returns, confirm the required artifacts exist (and warn on any surviving scratch):

```bash
ROOT="$(git rev-parse --show-toplevel)"
PLAN_REL="${PLAN_DIR#"$ROOT/"}"
# The planner deletes its own .work/ before returning; this is a verify-only
# backstop. If scratch survived (e.g. the planner crashed mid-run), warn instead
# of force-deleting: .gaia/local/plans/ is gitignored so leftover scratch is
# harmless clutter, and a verify-only step needs no rm-permission prompt on
# every run. Remove it by hand if the warning fires.
[ -d "$PLAN_REL/.work" ] && echo "WARNING: planner scratch survived at $PLAN_REL/.work; remove it manually if unneeded."
test -f "$PLAN_DIR/README.md" \
  && test -f "$PLAN_DIR/ORCHESTRATOR.md" \
  && test -f "$PLAN_DIR/KICKOFF.md" \
  && ls "$PLAN_DIR"/task-*.md >/dev/null 2>&1
```

If any required file is missing, surface the failure to the user with the planner's return payload. Do not retry silently, the user decides whether to re-spawn or investigate. Never proceed to step 4.6 with an incomplete plan folder.

### 4.6. Adversarial decomposition audit (recommended)

A lightweight multi-agent audit of the **decomposition itself**: the one artifact neither the upstream SPEC audit (which ran before the plan existed) nor the downstream pre-merge `code-review-audit` (which sees the executed diff) can inspect. It verifies that the task graph is a sound factoring of the work, that the frozen interface contracts resolve against the real repo, and that the SPEC's binding criteria are all covered, BEFORE a cold orchestrator burns execution cycles building against a flawed plan.

This is deliberately not a clone of the SPEC audit. The plan is editable and double-netted (sub-agents report `### Deviations from plan` during execution; `code-review-audit` gates the merge), so re-running the SPEC audit's claim-grounding, testability, and security lenses here would mostly re-verify what is already verified upstream and downstream. The audit stays narrow: three checks that exist only at plan stage, no refutation pass (these findings are checkable and binary, not severity-debatable like SPEC claims). It dispatches the same parallel `general-purpose` Agent primitive step 4 uses, so it works headless and in auto mode.

**The audit is a choice, presented once.** After step 4.5 confirms the artifacts exist, gauge the plan, then ask via `AskUserQuestion` whether to run the audit. Auditing a non-trivial plan is almost always worth it, so the recommended option is the audit, never "skip".

**Gauge the plan (this sets the recommendation).** Read `README.md` and the `task-*.md` files once. A trivial plan (one or two tasks, a single phase, no cross-task interface contract) → recommend **Skip**. Anything with parallel tasks in a phase, multiple phases, or a shared frozen contract → recommend **Run the audit**.

Present (recommended option FIRST, carrying the `(Recommended)` tag):

- question: `"Run the decomposition audit before handing off the plan? It checks the task graph for hidden dependencies, verifies the interface contracts resolve against the repo, and confirms the SPEC's criteria are all covered."`
- header: `"Audit"`
- options:
  - `{ label: "Run the audit (Recommended)", description: "Three parallel auditors verify decomposition soundness, contract grounding, and SPEC coverage against the real repo. A few agents, a couple of minutes." }`
  - `{ label: "Skip the audit", description: "Hand off the plan as written. Best reserved for trivial single-phase plans." }`

`Skip` is never the recommended option for a non-trivial plan. On **Skip**, proceed to step 4.7.

**Auto-mode.** No prompt fires. When `/gaia-plan` runs non-interactively (a headless or automation context with no interactive user), gauge the plan, run the audit if it is non-trivial, and apply its dispositions non-interactively.

**Fallback (never block).** If the parallel `general-purpose` Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block the handoff: note the skip (`decomposition audit unavailable`) and proceed to step 4.7. The orchestrator's per-phase quality gates and the non-skippable pre-merge `code-review-audit` remain the safety net.

#### 4.6a. Dispatch the lens auditors (parallel fan-out)

Spawn **one `general-purpose` Agent per lens, all in parallel** (one message, one Agent tool call per lens). The **SPEC coverage** lens is dispatched only when `SPEC_PATH` was set in step 1a; the other two always run. Each agent reads the plan folder and returns only the findings JSON below, no narrative.

Shared preamble (interpolate `<PLAN_DIR>` = the resolved plan directory, `<repo_root>` = `$PWD`):

> You are an ADVERSARIAL auditor of a GAIA task-orchestration plan in `<PLAN_DIR>`. Repo root is `<repo_root>`; you may read any file under it, including `node_modules`. Read `<PLAN_DIR>/README.md` (the task graph and frozen interface contracts) and every `<PLAN_DIR>/task-*.md` first. Your job is to find DEFECTS that would cause the orchestrator to build a broken or conflicting result, not to praise the plan.
>
> - Verify EVERY checkable claim against the actual repository. Do not take the plan's assertions on faith; when a task names a file, export, type, or signature, open it and confirm it resolves.
> - Cite evidence: the task doc and `file:line` for any ground-truth check.
> - Severity: `blocker` = the plan is factually wrong or will produce broken/conflicting work; `high` = a gap or hidden dependency the orchestrator is forced to guess on; `medium` = should fix; `low` = nit.
> - Give each finding a stable id prefixed with your lens code.
> - Be concrete and falsifiable. A finding the orchestrator can act on by reading one file is a good finding; vague "could be clearer" is not.

The lenses:

- **Decomposition & dependency soundness (id prefix `DP`).** The highest-value lens, with no analog upstream or downstream. Attack the task graph: tasks placed in the same phase as "parallel" that actually share state, edit the same files, or consume each other's outputs; phase order that does not respect a real data or interface dependency; a frozen interface contract that two tasks interpret inconsistently; acceptance criteria that are not independently verifiable. Construct the concrete scenario where every per-task acceptance criterion passes yet the integrated result is broken. Flag as `blocker` any task that registers net-new files into `.gaia/manifest.json`, or that treats a file's absence from the manifest as `/update-gaia` drift: the manifest is release-generated only (see `.claude/rules/manifest.md`).
- **Contract grounding (id prefix `CG`).** Treat every file path, export subpath, type name, and function signature named in a task's interface contract or files-to-touch list as a factual claim, and verify each resolves against the real repo and `node_modules`. A contract that names a non-existent export, a wrong signature, or a hallucinated module is at least `high`, likely `blocker`: the orchestrator will build against it and fail at integration.
- **SPEC coverage (id prefix `COV`, dispatched only when `SPEC_PATH` is set).** Build the matrix SPEC `UATs` + `success_criteria` ↔ task acceptance criteria. Find the holes: a UAT or success criterion no task covers; a task that drifts from or contradicts the SPEC's binding contract; scope the SPEC declared out-of-bounds that a task re-introduces. Read `<SPEC_PATH>` (interpolated) as the source of truth.

Findings schema (each agent returns exactly this object):

    {
      "dimension": "<lens name>",
      "findings": [
        {
          "id": "<lens-prefix>-NNN",
          "severity": "blocker" | "high" | "medium" | "low",
          "title": "<short>",
          "location": "<task doc / README section>",
          "issue": "<one sentence: what is wrong>",
          "evidence": "<file:line or plan quote actually checked>",
          "recommendation": "<one sentence: the fix>"
        }
      ]
    }

#### 4.6b. Apply findings

Collect findings across all lenses. The plan is editable and unsaved-to-handoff, so applying a fix is just rewriting plan files, no ceremony.

- **Localized findings** (a wrong contract, a missing acceptance criterion, an uncovered UAT): fold the fix directly into the affected `task-*.md` or `README.md` yourself.
- **Structural findings** (the phase graph is wrong, tasks need re-factoring across phases): re-spawn the planner (step 4) with the surviving findings appended as a correction directive, rather than hand-patching the graph. This goes through the same `PLAN_DIR` and overwrites the flawed artifacts.

**Interactive:** surface each material (non-`low`) finding to the user before applying (issue, evidence, recommendation; apply / keep / revise); apply `low` findings silently. **Auto-mode:** auto-apply unambiguous fixes; if a repair is ambiguous (more than one defensible fix), leave the plan unchanged and record the finding in a `## Audit notes` section appended to `README.md` so the orchestrator and user see it. If the audit re-spawned the planner, re-run step 4.5 against the regenerated folder before proceeding.

### 4.7. Telemetry: revision detection

If the directory-collision suffix from step 3 is greater than 1 (i.e. `PLAN_DIR` ends with `-2`, `-3`, …) AND `SPEC_PATH` was set in step 1a, this plan is a revision of a prior plan. Emit a `plan_revised` mentorship event so the over-time pattern detector sees it.

Derive the prior plan directory and item counts, then emit. Failure to emit must NEVER block the user's flow, wrap in `|| true`:

```bash
# Re-derive the suffix from PLAN_DIR (the same suffix used in step 3).
PLAN_BASENAME="$(basename "$PLAN_DIR")"
# This block only fires when SPEC_PATH is set, so PLAN_BASENAME is always the
# colocated form: `plan-N` for N>=2 collisions, `plan` for the first.
if [[ "$PLAN_BASENAME" =~ -([0-9]+)$ ]]; then
  SUFFIX="${BASH_REMATCH[1]}"
  if [[ "$SUFFIX" -gt 1 && -n "${SPEC_PATH:-}" ]]; then
    SPEC_DIR="$(dirname "$SPEC_PATH")"
    PRIOR_SUFFIX=$((SUFFIX - 1))
    if [[ "$PRIOR_SUFFIX" -eq 1 ]]; then
      PRIOR_DIR="${SPEC_DIR}/plan"
    else
      PRIOR_DIR="${SPEC_DIR}/plan-${PRIOR_SUFFIX}"
    fi
    NEW_TASKS=$(ls "$PLAN_DIR"/task-*.md 2>/dev/null | wc -l | tr -d ' ')
    PRIOR_TASKS=$(ls "$PRIOR_DIR"/task-*.md 2>/dev/null | wc -l | tr -d ' ')
    DIFF=$((NEW_TASKS - PRIOR_TASKS))
    if [[ "$DIFF" -ge 0 ]]; then
      ITEMS_ADDED=$DIFF
      ITEMS_REMOVED=0
    else
      ITEMS_ADDED=0
      ITEMS_REMOVED=$((-DIFF))
    fi
    SPEC_ID="$(basename "$SPEC_DIR")"   # -> SPEC-NNN (SPEC folder name)
    .gaia/cli/gaia telemetry emit plan_revised \
      --plan-id "$PLAN_BASENAME" \
      --spec-id "$SPEC_ID" \
      --revision-class scope_change \
      --items-added "$ITEMS_ADDED" \
      --items-removed "$ITEMS_REMOVED" \
      --agent-type human || true
  fi
fi
```

Notes:

- `revision-class` is hardcoded to `scope_change` in v1.0.0, the most common case. Future refinement may compute the class from the diff between prior and new task lists.
- The emit fires only when `SPEC_PATH` is set, because `plan_revised` requires `--spec-id`. Plans authored without a SPEC reference do not currently emit revision events; that surface lands when consumer-driven cloud event payloads ship.
- The emit is not gated on mentorship opt-in here; the CLI itself short-circuits for mentorship-disabled state and always emits the cloud projection.

### 4.8. Token tally

The plan folder is written and verified, so every planner/auditor sub-agent this action spawned has
flushed its sidecar to disk. Tally the `/gaia-plan` session's ground-truth token cost before the
handoff. The call sums `message.usage` across the main transcript AND every sub-agent sidecar
(deduped by message id, so it equals what the API billed), appends one record keyed to the feature
identity to the durable ledger resolved to the main checkout (so it survives archival of the plan
folder and a linked worktree), writes the **Planning** section of the plan folder's `cost.md`, and
prints the four billing buckets plus a total and the wall-clock elapsed. The KICKOFF execution phase
later adds an independent **Execution** section to the same `cost.md` (via the git-op hook, on each
commit); the two sections are tracked separately and never overwrite or sum each other. A spec-derived
plan passes its SPEC id via `--spec-id`; a SPEC-less plan passes its `PLAN-NNN` id via `--plan-id`
instead, exactly one of the two flags, never both, matching the ledger's `spec_id`-XOR-`plan_id`
contract:

```bash
PLAN_SLUG="$(basename "$PLAN_DIR")"
if [[ -n "${SPEC_PATH:-}" ]]; then
  TALLY_SPEC_ID="$(basename "$(dirname "$SPEC_PATH")")"   # -> SPEC-NNN
  bash .gaia/scripts/token-tally.sh \
    --action plan \
    --spec-id "$TALLY_SPEC_ID" \
    --plan-slug "$PLAN_SLUG" \
    --out-dir "$PLAN_DIR" || true
else
  # SPEC-less plan: PLAN_SLUG is the PLAN-NNN id allocated in step 3, so it
  # doubles as both the feature identity and the cost.md title slug.
  bash .gaia/scripts/token-tally.sh \
    --action plan \
    --plan-id "$PLAN_SLUG" \
    --plan-slug "$PLAN_SLUG" \
    --out-dir "$PLAN_DIR" || true
fi
```

The helper always exits 0, and the trailing `|| true` is defense-in-depth: this **never blocks the
handoff**, and unreadable input degrades to a partial figure with a marker rather than a fabricated
number. It is a mechanical helper call, not a prompt, so it runs identically in interactive and auto
(`AskUserQuestion`-less) mode. Surface the printed tally in the step-5 report to the user.

### 5. Report to user

Output a short summary of what's in `$PLAN_DIR/` (including the token tally printed in step 4.8), then emit the copy-paste prompt the user drops into a fresh Claude Code session to start the orchestrator cold.

The prompt is a single line, exactly:

```
Read <absolute-path-to-PLAN_DIR>/KICKOFF.md and execute it.
```

For example `.../.gaia/local/specs/SPEC-005/plan/KICKOFF.md` for a spec-derived plan, or `.../.gaia/local/plans/{slug}/KICKOFF.md` for a spec-less plan. Use `$PLAN_DIR/KICKOFF.md` (the absolute path resolved in step 3). The path MUST be absolute so the cold Claude session has no working-directory ambiguity. Do not include any other instruction, the orchestrator's behavior lives in `KICKOFF.md`.

**Print the prompt as a fenced code block** so the user can select and copy it manually.

Then print one trailing line: `Type /clear and paste the prompt above.`
