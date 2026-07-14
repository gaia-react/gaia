# /gaia-plan

Plan a complex feature using the task orchestration pattern. Do not implement anything.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `plan`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want me to orchestrate?"** and wait for the response before continuing.

#### 1a. Detect SPEC reference

Check the description for a SPEC reference. Three forms are recognized:

1. **Bare id** (the canonical form `/gaia-spec` now hands off): `$ARGUMENTS`, trimmed, is exactly `SPEC-\d+` and nothing else, e.g. `SPEC-026`.
2. **Path form**: a path matching `.gaia/local/specs/SPEC-\d+/SPEC\.md` appears anywhere in the description.
3. **Prefix form** (the older, verbose handoff shape, still accepted for pasted history): a `SPEC-\d+:` prefix at the start of the description.

If any form matched, extract the `SPEC-\d+` id from wherever it appeared (the bare token, the path segment, or the text before the colon), then resolve it against the actual filesystem, self-healing a zero-padding mismatch (e.g. `SPEC-026` also resolves from the bare `SPEC-26`):

```bash
ROOT="$(git rev-parse --show-toplevel)"
RAW="<the SPEC-\d+ id extracted above, e.g. SPEC-026 or SPEC-26>"
NUM="${RAW#SPEC-}"
PADDED="SPEC-$(printf '%03d' "$((10#$NUM))")"
SPEC_ID=""
for CANDIDATE in "$RAW" "$PADDED"; do
  if [[ -f "${ROOT}/.gaia/local/specs/${CANDIDATE}/SPEC.md" ]]; then
    SPEC_ID="$CANDIDATE"
    break
  fi
done
```

If `SPEC_ID` is still empty (no folder resolves), stop and surface: `"No SPEC found for <RAW>. Check the id and try again."` Do not fall back to a spec-less plan silently, a SPEC reference that resolves to nothing is a typo, not an intentional spec-less request.

Once `SPEC_ID` resolves:

1. Cache `SPEC_DIR="${ROOT}/.gaia/local/specs/${SPEC_ID}"` and the absolute `SPEC_PATH="${SPEC_DIR}/SPEC.md"` for use in the planner prompt (step 4), the planner will reference it in `README.md`.
2. Read `SPEC_PATH`. Its full content is the source-of-truth feature description; any dispatch summary in the original description is just a label.
3. Check for a sibling audit: if `${SPEC_DIR}/AUDIT.md` exists, cache its absolute path as `AUDIT_PATH` for use in step 4, the planner reads it too. If absent, `AUDIT_PATH` is unset.
4. Cache the lowercased SPEC id (`spec-005`) as `SPEC_SLUG_SEED` for use in step 4's branch-naming policy.

If no SPEC reference is detected, `SPEC_SLUG_SEED`, `SPEC_PATH`, and `AUDIT_PATH` are unset; step 3 allocates a `PLAN-NNN` id from the local ledger for the spec-less plan.

Colocated plans no longer use `SPEC_SLUG_SEED` to prefix a `plans/` slug, the plan lives inside the SPEC folder, so plan→SPEC discovery is structural. It is retained for the branch-name marker (step 4's branch policy) and human-facing labels. `SPEC_PATH` additionally seeds `SPEC_DIR` (its parent directory) for plan-directory resolution in step 3.

### 2. Check model

The deep synthesis runs in the planner spawned at step 4, and the planner's model is pinned at spawn time, so it can be a top-tier model even when this orchestration runs on Sonnet. Opus and Fable are both top-tier planning models. Decide the planner's model:

- If you are on Opus or Fable, the planner inherits your current model; skip to step 3.
- If you are running non-interactively (a headless or automation context with no interactive user to prompt), default the planner to Opus: spawn it with `model: opus` at step 4. Skip to step 3.
- Otherwise (you are on Sonnet, Haiku, or another lesser model) call `AskUserQuestion` with:
  - question: `"You're on [model name]. Which model should plan?"`
  - header: `"Model"`
  - options:
    - `{ label: "Use Opus (Recommended)", description: "Spawn the planning agent on Opus for higher-quality plans." }`
    - `{ label: "Use Fable", description: "Spawn the planning agent on Fable, also a top-tier planning model." }`
    - `{ label: "Use [model name]", description: "Keep the current model." }`
  - If the user picks Opus: spawn the agent with `model: opus`.
  - If the user picks Fable: spawn the agent with `model: fable`.
  - If the user picks the current model: spawn without a model override (inherit current).

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

Launch a `general-purpose` Agent with the model determined above and this prompt. Interpolate every `{PLAN_DIR}` token with the absolute path resolved in step 3. If `SPEC_PATH` was set in step 1a, interpolate every `{SPEC_PATH}` token with that absolute path; if unset, delete the `**Source SPEC**` paragraph below before sending. If `AUDIT_PATH` was also set in step 1a, interpolate every `{AUDIT_PATH}` token with that absolute path; if unset, delete the `**Adversarial audit**` paragraph below before sending.

---

You are planning a feature using task orchestration. Do not implement anything. Investigate the codebase, then write the plan files directly to disk. You are a leaf subagent and cannot spawn further subagents; parallelize investigation with parallel tool calls (batch reads and greps in one step), not sub-agent dispatch.

**Plan directory:** `{PLAN_DIR}`

**Source SPEC:** `{SPEC_PATH}`, read this file FIRST. Its `intent`, `UATs`, and `clarifications.answered[]` are authoritative for what to plan; the dispatch summary in `Feature:` below is just a label. Reference the SPEC id in `README.md`'s `## Source SPEC` section.

**Adversarial audit:** `{AUDIT_PATH}`, read this file too. Its `## Plan-time directives` section names implementation constraints the SPEC's contract already satisfies; honor each one in the relevant task doc and cite the directive where you do. Its other sections (refuted findings, coverage) are for-the-record only and need no action.

**Write rules.**

- You may write only under `{PLAN_DIR}/`. Never edit source files, configs, or anything outside this directory.
- Final plan artifacts go directly under `{PLAN_DIR}/` (no subdirectories for deliverables).
- For ephemeral scratch (mid-investigation notes, intermediate research dumps), create a unique subdirectory under `{PLAN_DIR}/.work/` via `mktemp -d "{PLAN_DIR}/.work/<role>.XXXXXX"`. Never write directly to `.work/` itself. Delete your scratch subdir before returning; the parent also runs a defensive cleanup of `{PLAN_DIR}/.work` after you return, as belt-and-suspenders.

**Feature:** {feature description from step 1}

First, read `wiki/concepts/Task Orchestration.md`.

**Never author a manifest-registration task.** `.gaia/manifest.json` is release-generated and lists only files GAIA ships; adopter feature work never adds to it, and a file's absence from the manifest is not `/update-gaia` drift (a path absent from the manifest is adopter-owned and invisible to the update). See `.claude/rules/gaia-folder.md`.

Then write the following files directly to `{PLAN_DIR}/`:

1.  **One task doc per parallel workstream**: `{PLAN_DIR}/task-{name}.md`. Each must be fully self-contained for a fresh-context sub-agent and include:
    - Context and motivation
    - Interface contracts (types, function signatures, file exports)
    - Files to touch (with line-range hints where possible)
    - Acceptance criteria (concrete and testable)
    - Dependencies on other tasks in this plan

2.  **`{PLAN_DIR}/README.md`**: task graph showing phases, which tasks run in parallel within each phase, and the frozen interface contracts shared across tasks. **Annotate each phase with its execution model** (e.g. `Phase 1 (2 sub-agents, model sonnet)`); Sonnet is the default, so call out any phase you escalate to Opus explicitly and briefly say why. **If `{SPEC_PATH}` was provided** (i.e. this plan was derived from a SPEC), the README MUST open with a `## Source SPEC` section naming the SPEC id and the absolute path, so plan→SPEC discovery is one read away. Format: `Derived from {SPEC-id} ({SPEC_PATH}).` **If `{AUDIT_PATH}` was also provided**, append a second line: `Adversarial audit: {AUDIT_PATH}.`

3.  **`{PLAN_DIR}/ORCHESTRATOR.md`**: instructions for running the plan. Must cover:
    - **Resume detection (cold-start, before the sentinel write).** Before writing this run's RUNNING sentinel, and before the pre-flight branch policy below, check for a pre-existing `{PLAN_DIR}/RUNNING`.
      - **No prior sentinel.** This is a fresh first run: skip resume entirely, proceed to the pre-flight branch policy, and let it write this run's own sentinel afterward as usual. The detection read MUST precede the sentinel write, or every fresh run would self-detect as a resume.
      - **Merged-PR guard.** If a sentinel exists, check whether its plan's PR is already merged before reconnecting to anything. The sentinel carries no PR number, so recover it from the sentinel's `branch:` line:

        ```bash
        pr_state="$(gh pr list --head "<sentinel-branch>" --state all --json number,state \
          --jq '.[0].state' 2>/dev/null)"
        ```

        If `pr_state` is `MERGED`, do not drive a resume of merged work, `plan-archive.sh`'s fail-closed representation gate can leave a stale RUNNING/PROGRESS on an already-merged plan, surface it and stop. If no PR is found (empty result) or the state is `OPEN`, proceed with resume; the guard degrades to a no-op when there is nothing merged to protect against.
      - **Reconnect by isolation mode.** Read `branch:` and `mode:` from the sentinel. If `mode:` is absent (a legacy sentinel written before this line existed), derive it from `git worktree list`: a worktree whose checked-out branch equals the sentinel branch means worktree mode, otherwise feature-branch mode. Reconnect using the matching operation: `git checkout <branch>` for feature-branch mode, or re-enter the existing worktree for worktree mode (do NOT `git checkout` the worktree-held branch and do NOT create a new worktree). Do NOT re-fire the on-main branch-mode `AskUserQuestion` and do NOT cut a new branch. **Failed reconnect:** if the sentinel branch is genuinely missing or the working tree is dirty, surface the condition and STOP, never silently start a new branch.
      - **Compute the resume point.** Run the helper from the reconnected working context:

        ```bash
        bash .gaia/scripts/plan-resume-point.sh --plan-dir {PLAN_DIR} --phases <M>
        ```

        where `<M>` is the plan's total phase count (from README's phase list). In worktree mode, run this with cwd inside the worktree so its ancestor check evaluates the worktree branch's HEAD; `--plan-dir` stays the main-checkout `{PLAN_DIR}` regardless, it locates the ledger only (`{PLAN_DIR}/PROGRESS.md`, falling back to a legacy live `SUMMARY.md` if `PROGRESS.md` is absent), never the git context. Read the resume point `K` from line 1 of stdout; read the `COMPLETE <n> <sha>` lines for the gate announcement below.
      - **Confirmation gate (only when `K > 1`).** Present via `AskUserQuestion`, announcing each verified-complete phase and its short-SHA taken from the helper's `COMPLETE` lines (the one source of truth, do not re-parse `PROGRESS.md`):
        - `Resume at Phase K (Recommended)`: enter the phase loop at Phase K.
        - `Restart from Phase 1`: run every phase from Phase 1.
        - `Abandon`: stop cleanly without re-running, committing, merging, or deleting anything; the sentinel, `PROGRESS.md`, branch, and prior commits stay intact.

        When `K` equals `M+1` (every phase a verified-complete ancestor), resume proceeds straight to the pre-merge `code-audit-frontend` with no phase re-run.
      - **Resumed-run git flow.** A resumed run reuses the already-open PR, it does NOT re-issue `gh pr create`; it updates the existing PR with subsequent commits exactly like an uninterrupted run. Its per-phase commits still tally to the same feature because the branch-keyed token-tally resolver (`.claude/hooks/lib/gaia-active-plan.sh`) matches after reconnect; the pre-merge marker handshake and `plan-archive.sh` cleanup behave unchanged. No code change here, the token-tally hooks are already resume-aware.

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

      The `WorktreeCreate` hook (`.gaia/scripts/create-worktree.sh`) owns creation: it cuts a new branch of that name fresh from the remote default branch (`main`), else local HEAD, lands it under `.claude/worktrees/<branch-name>/`, and switches the session into that worktree. The branch is already cut, so the orchestrator runs no manual `git checkout -b`. Every later step, task sub-agent edits, per-phase commits, `gh pr create`, and the pre-merge `code-audit-frontend`, runs from inside the worktree.

      **The plan folder stays in the main checkout.** The worktree shares only a fixed set of gitignored state with the main checkout by symlink (`.gaia/local/cache/shared/`, `.gaia/local/audit/`, `.gaia/local/telemetry/`, `setup-state.json`, `mentorship.json`); the plan folder is not among them, so `{PLAN_DIR}` exists only in the main checkout. Read the task docs and `README.md` from `{PLAN_DIR}` (its main-checkout absolute path) and write `PROGRESS.md` there, while each task edits the worktree's own copy of the tracked files it touches. Dispatch each task sub-agent with both: the worktree's absolute path for the file to edit, and `{PLAN_DIR}` for the docs to read. Run `plan-archive.sh {PLAN_DIR}` only after `ExitWorktree` returns the session to the main checkout, so the helper's repo-root guard resolves the main checkout rather than the worktree.

    - **RUNNING sentinel.** Immediately after the pre-flight branch policy above (the feature branch is cut, or the worktree is entered), write a sentinel file at `{PLAN_DIR}/RUNNING`. Content:

      ```
      branch: <the isolation branch: git branch --show-current now that pre-flight cut the branch / entered the worktree>
      slug: <basename of {PLAN_DIR}>
      started: <current UTC time, ISO 8601, e.g. 2026-05-19T14:32:00Z>
      mode: <feature-branch|worktree, the isolation mode chosen at pre-flight>
      ```

      This file is deleted automatically when the plan directory is deleted during final self-cleanup. Its purpose: it marks this plan as the branch's active run, which the execute-phase token-tally hooks (`.claude/hooks/lib/gaia-active-plan.sh`, `.claude/hooks/token-tally-git-op.sh`) read to key each commit's tally to the right feature. The write happens here, after the branch policy, rather than as the very first step: the token-tally resolver (`.claude/hooks/lib/gaia-active-plan.sh:58-59`) matches a sentinel by `^branch:` against the current branch, so a sentinel recording `main` while phase commits land on the feature branch would never match, and a later cold resume would target the wrong branch. `mode:` records the isolation mode so a later resume picks the right reconnect operation without re-prompting; the resolver reads only `branch:`/`started:`, so the extra `mode:` line does not disturb it. Resume detection above still runs before pre-flight; only the write of this run's own sentinel moves here. When a spec-less plan folder is KEPT (reduced, not deleted) under the symmetric retention the Final self-cleanup phase describes below, `plan-archive.sh` clears this `RUNNING` sentinel as part of the reduction, so the branch-keyed resolver and the token-tally hooks never mistake a reaped-but-kept folder for a still-live run.

    - **Phase order** with per-phase quality gates (`pnpm typecheck && pnpm lint`). Name each phase's execution model in the outline (Sonnet by default; see the Sub-agent invocation bullet), so a cold orchestrator sees the model alongside the phase.
    - **Pre-merge `code-audit-frontend` (non-skippable).** Before any `gh pr merge` call, the orchestrator spawns the `code-audit-frontend` agent on the current branch. The agent's clean pass writes `.gaia/local/audit/<tree-sha>.ok`, keyed to HEAD's tree, which the deny-hook (`.claude/hooks/pr-merge-audit-check.sh`) gates `gh pr merge` on. The orchestrator does NOT wait for the deny-hook to fire and learn from it, that round-trip is friction. Spawn the agent proactively. Contract: `wiki/concepts/PR Merge Workflow.md`. Verbatim agent-spawn template:

          Task(
            subagent_type="code-audit-frontend",
            prompt="Review all changes in the current branch compared to main. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities."
          )

      If the agent does not write its clean-pass marker, the orchestrator surfaces the report's open findings (the agent's own tiers: Critical, unresolved Important, or unaddressed/escalated Suggestion), stops, and lets the user decide whether to fix and re-audit or abandon. The marker handshake is the gate; do not hand-write the marker. If the audit agent declines to write the marker, the report names what remains unaddressed; resolve those, commit, push, re-spawn, exactly as the contract specifies.

      The audit's LOCAL Task return is terse (pointer + counts + marker line); the full per-finding detail lives in the re-run carry-forward ledger (`.gaia/local/audit/<base-sha>.rerun.json`). To surface the open findings, the orchestrator reads the ledger's `remaining[]` (enumerating Critical, Important, and escalated Suggestions for the user) instead of expecting a full inline report. Fail-open: if the ledger is absent, corrupt, or stale, the audit's return carries the full report (it emits the full report whenever it could not write the ledger), so the orchestrator surfaces the open findings from that report as today.

    - **Sub-agent invocation:** the verbatim prompt template for each task sub-agent. **Each task sub-agent MUST be dispatched as `general-purpose` with `model: "sonnet"` explicitly pinned.** The feature's complexity is resolved upstream, during `/gaia-spec` + its audit and `/gaia-plan` + the decomposition audit, precisely so execution can run on the cheaper model. Pin Sonnet on the dispatch itself so the executors run on Sonnet regardless of the orchestrator's own session model: a cold orchestrator is often on Opus, and an unpinned sub-agent inherits that. **Escape hatch:** the planner MAY pin `model: "opus"` on a specific phase or task it judges to be genuinely deep synthesis (a subtle parser grammar, a cross-cutting type redesign), but must name which phase and why in that phase's `ORCHESTRATOR.md` entry. Sonnet is the floor; Opus is a per-phase, justified exception, never the blanket default. Sub-agents do NOT commit, push, or open/update the PR, they only edit files and report. The orchestrator owns all git operations. **The prompt template MUST require sub-agents to end their return with a `## Notes for orchestrator` section** containing any of: `### Findings` (non-obvious things they noticed), `### Deviations from plan` (where the task spec was wrong / they had to work around it), `### Follow-ups` (work the user should consider after merge). Subsections may be empty or omitted; only non-trivial signal belongs here, routine "phase done, tests green" status does NOT.
    - **Orchestrator-owned git flow.** After each phase that produces changes (and only once the quality gate is clean), the orchestrator stages, commits with a meaningful message, and pushes. The orchestrator opens the PR after the first phase's commit lands on the remote (using `gh pr create`) and updates it with subsequent commits. Never commit a broken state.
    - **Phase findings ledger (`{PLAN_DIR}/PROGRESS.md`).** Append-only file the orchestrator maintains across the run, so sub-agent observations survive context compression. After each phase, the orchestrator appends a `## Phase N, <title>` block whose first content line is `Commit: <short-sha>`, the machine-readable anchor `.gaia/scripts/plan-resume-point.sh` reads, followed by the merged `Notes for orchestrator` content from every sub-agent in that phase, or `_No notes._` if the phase produced no notes. **`plan.md` is the single source of truth for this block format**; any other doc or reference page that describes the ledger points here rather than restating the literal `Commit:` line. Example:

      ```
      ## Phase 2, Helper implementation
      Commit: a1b2c3d

      ### Findings
      …
      ```

      A HALTED block carries no `Commit:` anchor: `## Phase N, <title> (HALTED)` (see Stop conditions below), a halt did not commit. Sub-agents do not write to this file directly; the orchestrator owns it.
    - **Stop conditions.** On any sub-agent failure or quality-gate failure: STOP and surface to the user. Do not "fix and continue", do not commit, do not push. Before stopping, append the failure context (which phase, which sub-agent, error) to `PROGRESS.md` under a `## Phase N, <title> (HALTED)` block so the user and any follow-up session see the same record.
    - **Final summary.** After all implementation phases pass and the final commit is pushed, before awaiting merge confirmation, **read `{PLAN_DIR}/PROGRESS.md`** and print a brief summary to the user: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, quality-gate status, and the highest-signal findings/deviations/follow-ups drawn from `PROGRESS.md` so nothing is lost to context compression. Keep it tight, a few lines plus the surfaced notes, not a recap of every change.

      **Token tally (execute-time).** Execute-phase token tallies are recorded automatically: a `PreToolUse` hook on the orchestrator's per-phase git commit/push records this session's execute tally to the durable ledger, keyed to the feature (the SPEC id resolved from the active plan folder, or the plan slug when spec-less). Resumed, halted, and worktree sessions are all captured. The orchestrator does not run a manual execute tally, doing so would double-count the phase.

      After the pre-merge `code-audit-frontend`'s clean-pass marker is written and before the Final self-cleanup phase archives the plan folder, the orchestrator reports the full-cycle cost by running the roll-up reader and reporting exactly one cost line built from its output, not the reader's multi-line block. Substitute the plan's real SPEC id (from the `## Source SPEC` section of `README.md`, or the plan slug if the plan has no SPEC, the spec-less case):

      ```bash
      if [ -x .gaia/scripts/token-rollup.sh ]; then
        bash .gaia/scripts/token-rollup.sh \
          --spec-id "<SPEC-NNN from README's Source SPEC, or the plan slug if none>" || true
      fi
      ```

      Report the cost as exactly one line: `Cost: ~<total> tokens, $<dollars>, <elapsed> (<stage> $X.XX + <stage> $X.XX)`, where `<total>` is the reader's grand `Total` token count abbreviated to millions with one decimal and a `~` prefix (e.g. `~10.6M`), `<dollars>` is its `Est. cost (USD)` total as `$X.XX`, `<elapsed>` is the grand `Total` elapsed in `<N>h<M>m<S>s`, and the trailing breakdown lists each stage the reader priced (`spec`, `plan`, `execute`) with its own `$X.XX`. Never fabricate: if a dollar figure is unavailable write `cost unavailable` in its place; if elapsed is unavailable drop that term; carry through any `(partial: lower bound)` marker the reader emits. This line reads identically to the `/gaia-spec` and `/gaia-plan` cost lines; keep the three in sync.

      A `PostToolUse` hook on `gh pr merge` renders the same roll-up at the merge boundary, so the readout also appears when the merge runs from a fresh top-level session. The reader never blocks and never fabricates a number: the `-x` guard and trailing `|| true` mean a missing or failing helper degrades silently, and an unreadable ledger degrades to a partial or absent figure with a marker.

    - **Consolidation at confirmed-merge (before any plan-folder or `PROGRESS.md` deletion).** After all implementation phases pass and the user confirms the PR is ready to merge, before `plan-archive.sh` touches the plan folder, the orchestrator (warm, on its own session, this is genuine synthesis, not a task sub-agent's job) produces the consolidated `SUMMARY.md` by layered override-resolution: read `SPEC.md`, then `AUDIT.md`, then `PROGRESS.md`, in that precedence, top layer wins on conflict; a spec-less plan has no `SPEC.md`/`AUDIT.md`, so `PROGRESS.md` is its only layer. Ground the result in the merged code and passing tests, write it present-tense as final-state prose, and surface any material narrowing between the stated intent and the shipped scope under an optional `## Divergence` section. This step is deliberately an agent synthesis, not a deterministic template: a mechanical concatenation of the three layers cannot resolve conflicts between them or judge what "materially narrower" means, which is why the design rejects a template. Write the pinned shape (frontmatter `wiki_promote_default` + `wiki_promote_targets`; non-empty H1; non-empty body; optional `## Divergence`, see `README.md`'s frozen contract). A spec-colocated plan's `plan/PROGRESS.md` feeds the SPEC-level `SUMMARY.md` (written beside `SPEC.md`, one directory up from the plan subfolder, once it has fed the consolidation); a spec-less plan's `PROGRESS.md` produces `PLAN-NNN/SUMMARY.md` in place.

      Then verify-gate before removing anything:

      ```bash
      bash .gaia/scripts/summary-verify.sh <SUMMARY.md path>
      ```

      On exit 0, `rm` the folder's `SPEC.md` and `AUDIT.md` (a spec-colocated plan only, their content is now superseded by the verified `SUMMARY.md`; a spec-less plan has none to remove). On non-zero, KEEP `SPEC.md`/`AUDIT.md` and the partial `SUMMARY.md` in place and skip the removal, fail-closed: a malformed consolidation never destroys the only record. `plan-archive.sh`'s own gates (below) re-check for a present, well-formed `SUMMARY.md`, so a skipped removal here also leaves the plan folder itself untouched on the next step.

    - **Final self-cleanup phase (last step before merge).** Now that the consolidation step above has produced (or fail-closed, left in place) the folder's `SUMMARY.md`, the orchestrator disposes of its own plan folder. Run:

      ```bash
      bash .gaia/scripts/plan-archive.sh {PLAN_DIR}
      ```

      The argument is the plan dir. Pass the cached `{PLAN_DIR}` (absolute) directly, the helper normalizes an absolute-under-repo path to repo-relative. A repo-relative literal (`.gaia/local/specs/<SPEC-ID>/plan[-N]` or `.gaia/local/plans/PLAN-NNN`) is equally valid. The argument shape does NOT affect the permission match here: the allow entry `Bash(bash .gaia/scripts/plan-archive.sh:*)` uses a `:*` wildcard that matches any argument.

      For a spec-less plan under `.gaia/local/plans/PLAN-NNN/`, the folder is now REDUCED rather than deleted outright: everything except the consolidated `SUMMARY.md` and its `cost.json` sidecar is removed, including `PROGRESS.md` and the `RUNNING` sentinel, and the row is stamped `merged` + `merged_at`. The reduced folder is kept for later age-reap by the SessionStart janitor, once past `GAIA_SPEC_RETENTION_DAYS`, cost-represented, and promote-drained, with early-reap-at-close for a folder that already clears cost-representation and drain. For a spec-colocated plan under `.gaia/local/specs/<SPEC-ID>/plan[-N]/`, only that subfolder is deleted, now that it has fed the spec-level consolidation above; the parent SPEC folder is KEPT, now holding the reconciled `SUMMARY.md` (`SPEC.md`/`AUDIT.md` were already removed by the consolidation step above, once verified) plus the SPEC's own `cost.json` sidecar, reaped later by the same janitor sweep under the same three gates (age, cost-represented, promote-drained), again with early-reap-at-close. Either arm fail-closes: if the consolidation step above never produced a verified `SUMMARY.md`, `plan-archive.sh` leaves the whole folder untouched rather than reducing or deleting it. The helper always exits 0.

      Then check `git check-ignore .gaia/local/plans/` (and, for a colocated plan, `git check-ignore .gaia/local/specs/`): both are gitignored under the GAIA default, so the disposition is invisible to git, skip the commit and report "plan folder reduced/deleted locally; gitignored, no commit needed." If a path is tracked, commit and push the change as the final commit on the PR. If the user explicitly asks to keep the plan folder, skip and report.

      The `PROGRESS.md`/`cost.json` content was already surfaced in the Final summary before the folder is removed.

    - **Post-merge auto-reconcile (both isolation modes).** After the PR merges, before any worktree-discard handoff or isolation-context stop (see the next bullet), the orchestrator reconciles the plan/SPEC ledger. This is its OWN standalone step with its OWN `MERGED` confirmation, separate from the worktree-only cleanup below, and it applies to BOTH feature-branch and worktree isolation modes; a feature-branch run never reaches the worktree-only cleanup, so nesting the reconcile there would silently drop it for the default (Recommended) mode.
      1. Confirm merge via `gh pr view <N> --json state`. Parse the JSON; require `.state == "MERGED"`. If not merged, do NOT proceed, surface to user and stop.
      2. **Resolve the main-checkout root; never pass `$PWD`.** In worktree isolation the orchestrator's cwd is the worktree, whose `.gaia/local/specs/` and `.gaia/local/plans/` ledgers are not among the symlink-shared paths, so `"$PWD"` resolves a nonexistent ledger and the reconcile silently no-ops. Resolve the main root the same way `token-tally.sh` does for its ledger:

         ```bash
         common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
         case "$common_dir" in /*) abs="$common_dir" ;; *) abs="$PWD/$common_dir" ;; esac
         main_root="$(cd "$(dirname "$abs")" 2>/dev/null && pwd)"
         ```

         In a feature-branch run `main_root` equals `$PWD`, so the same code is correct in both modes.
      3. A spec-colocated plan on a `spec-NNN-*` branch runs `bash .specify/extensions/gaia/lib/spec-reconcile.sh "$main_root" || true` (flips the SPEC's `specs/ledger.json` row `ready` → `merged`, the unified vocabulary); a spec-less `PLAN-NNN` plan runs `bash .specify/extensions/gaia/lib/plan-reconcile.sh "$main_root" "$PLAN_ID" || true` (flips the `plans/ledger.json` row → `merged`, stamping `merged_at`). Both are best-effort and never block.
      4. Backstops remain: `spec-reconcile.sh` still runs in the `/gaia-spec` pre-flight sweep (spec arm); `plan-archive.sh`'s pre-gate stamp remains the plan-arm backstop (now stamping `merged` + `merged_at`), so the ledger still converges if the orchestrator is interrupted mid-cleanup. `plan-close` (the spec-less mirror of `spec-close`) is the plan-side manual close path for when this automated step did not run.

      Sequenced BEFORE the worktree-discard handoff / isolation-context stop below, so an isolated worktree run reconciles before it stops to emit its continuation prompt.

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
          PR #<N> squash-merged as <short-sha>. From a shell at
          <ABSOLUTE-PATH-TO-MAIN-CHECKOUT>, run:

              git worktree remove --force <ABSOLUTE-PATH-TO-WORKTREE>
              git branch -D <branch-name>   # only if the merge did not already delete it

      Do not emit an `ExitWorktree({...})` call in this continuation prompt. `ExitWorktree` only operates on a worktree created by `EnterWorktree` in the current session: from a fresh session it is a no-op on a prior-session worktree, and its schema requires `action` and rejects a `worktree` parameter. A plain `git worktree remove --force` is the correct session-independent cleanup. No error surfaces, no `ExitWorktree` invocation happens in this branch, and the user pastes the shell commands into any terminal to complete the cleanup without further investigation.

4.  **`{PLAN_DIR}/KICKOFF.md`**: the orchestrator's kickoff prompt itself, ready to be read and executed verbatim. The file is the prompt, no preamble, no "copy and paste below" instruction, no surrounding commentary, no `---` separators framing the prompt as a quoted block. The opening line addresses the orchestrator directly (e.g. "You are the orchestrator for the {feature} plan…"). Must be fully self-contained with no assumed context: absolute paths to `README.md` and `ORCHESTRATOR.md`, the goal, hard rules, and the execution outline. The kickoff also includes a one-line reference to the pre-merge `code-audit-frontend` obligation (e.g. "Before any `gh pr merge`, run the `code-audit-frontend` agent, see ORCHESTRATOR.md's Pre-merge code-audit-frontend section."), a one-line default-execution-model statement (e.g. "Dispatch each task sub-agent as `general-purpose` with `model: \"sonnet\"` unless ORCHESTRATOR.md's phase list escalates that phase to Opus."), and a one-line cold-start resume statement (e.g. "On cold start, before pre-flight, check `{PLAN_DIR}/RUNNING` for a prior run and follow ORCHESTRATOR.md's Resume detection section (reconnect + resume gate) before writing the sentinel."). All three lines ensure a cold-started orchestrator reads the requirement before doing any work, surviving any context compression that drops the ORCHESTRATOR.md content from the first read.

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

A lightweight multi-agent audit of the **decomposition itself**: the one artifact neither the upstream SPEC audit (which ran before the plan existed) nor the downstream pre-merge `code-audit-frontend` (which sees the executed diff) can inspect. It verifies that the task graph is a sound factoring of the work, that the frozen interface contracts resolve against the real repo, and that the SPEC's binding criteria are all covered, BEFORE a cold orchestrator burns execution cycles building against a flawed plan.

This is deliberately not a clone of the SPEC audit. The plan is editable and double-netted (sub-agents report `### Deviations from plan` during execution; `code-audit-frontend` gates the merge), so re-running the SPEC audit's claim-grounding, testability, and security lenses here would mostly re-verify what is already verified upstream and downstream. The audit stays narrow: three checks that exist only at plan stage, no refutation pass (these findings are checkable and binary, not severity-debatable like SPEC claims). It dispatches the same parallel `general-purpose` Agent primitive step 4 uses, so it works headless and in auto mode.

**The audit is a choice, presented once.** After step 4.5 confirms the artifacts exist, gauge the plan, then ask via `AskUserQuestion` whether to run the audit. Auditing a non-trivial plan is almost always worth it, so the recommended option is the audit, never "skip".

**Gauge the plan (this sets the recommendation).** Read `README.md` and the `task-*.md` files once. A trivial plan (one or two tasks, a single phase, no cross-task interface contract) → recommend **Skip**. Anything with parallel tasks in a phase, multiple phases, or a shared frozen contract → recommend **Run the audit**.

Present (recommended option FIRST, carrying the `(Recommended)` tag):

- question: `"Run the decomposition audit before handing off the plan? It checks the task graph for hidden dependencies, verifies the interface contracts resolve against the repo, and confirms the SPEC's criteria are all covered."`
- header: `"Audit"`
- options:
  - `{ label: "Run the audit (Recommended)", description: "Three parallel auditors verify decomposition soundness, contract grounding, and SPEC coverage against the real repo. A few agents, a couple of minutes." }`
  - `{ label: "Skip the audit", description: "Hand off the plan as written. Best reserved for trivial single-phase plans." }`

`Skip` is never the recommended option for a non-trivial plan. On **Skip**, proceed to step 4.7. Skip does not run the audit, so no audit-window breadcrumb is written; its absence is the correct signal to the step-4.8 tally that no decomposition audit ran.

**Auto-mode.** No prompt fires. When `/gaia-plan` runs non-interactively (a headless or automation context with no interactive user), gauge the plan, run the audit if it is non-trivial, and apply its dispositions non-interactively.

**Fallback (never block).** If the parallel `general-purpose` Agent fan-out is unavailable (a restricted context that cannot spawn subagents), do NOT block the handoff: note the skip (`decomposition audit unavailable`) and proceed to step 4.7. The orchestrator's per-phase quality gates and the non-skippable pre-merge `code-audit-frontend` remain the safety net. Like Skip, this path writes no audit-window breadcrumb.

#### 4.6a. Dispatch the lens auditors (parallel fan-out)

Capture the audit window start for the cost-ledger breadcrumb: `AUDIT_WINDOW_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"`.

Spawn **one `general-purpose` Agent per lens, all in parallel** (one message, one Agent tool call per lens). The **SPEC coverage** lens is dispatched only when `SPEC_PATH` was set in step 1a; the other two always run. A SPEC-less plan's undispatched SPEC coverage lens is recorded not-applicable, never as a no-op. Each agent reads the plan folder and returns only the findings JSON below, no narrative.

Shared preamble (interpolate `<PLAN_DIR>` = the resolved plan directory, `<repo_root>` = `$PWD`):

> You are an ADVERSARIAL auditor of a GAIA task-orchestration plan in `<PLAN_DIR>`. Repo root is `<repo_root>`; you may read any file under it, including `node_modules`. Read `<PLAN_DIR>/README.md` (the task graph and frozen interface contracts) and every `<PLAN_DIR>/task-*.md` first. Your job is to find DEFECTS that would cause the orchestrator to build a broken or conflicting result, not to praise the plan.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit, and you emit your structured result before any prose. Your first Read here is `<PLAN_DIR>/README.md`.
>
> - Verify EVERY checkable claim against the actual repository. Do not take the plan's assertions on faith; when a task names a file, export, type, or signature, open it and confirm it resolves.
> - Cite evidence: the task doc and `file:line` for any ground-truth check.
> - Severity: `blocker` = the plan is factually wrong or will produce broken/conflicting work; `high` = a gap or hidden dependency the orchestrator is forced to guess on; `medium` = should fix; `low` = nit.
> - Give each finding a stable id prefixed with your lens code.
> - Be concrete and falsifiable. A finding the orchestrator can act on by reading one file is a good finding; vague "could be clearer" is not.

The lenses:

- **Decomposition & dependency soundness (id prefix `DP`).** The highest-value lens, with no analog upstream or downstream. Attack the task graph: tasks placed in the same phase as "parallel" that actually share state, edit the same files, or consume each other's outputs; phase order that does not respect a real data or interface dependency; a frozen interface contract that two tasks interpret inconsistently; acceptance criteria that are not independently verifiable. Construct the concrete scenario where every per-task acceptance criterion passes yet the integrated result is broken. Flag as `blocker` any task that registers net-new files into `.gaia/manifest.json`, or that treats a file's absence from the manifest as `/update-gaia` drift: the manifest is release-generated only (see `.claude/rules/gaia-folder.md`).
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

**No-op detection, retry, and inline fallback (per lens).** After the fan-out returns, write each dispatched lens's returned findings JSON to a temp file and classify it with `bash .gaia/scripts/audit-noop-detect.sh --shape plan-findings --path <tempfile>` (exit 0 = real, exit 1 = no-op; the return is already thin, so nothing extra enters main's reasoning context). This is the return-conformance arm: 4.6a has no findings file to pre-clear, only the captured return. A lens the gate above never dispatched (SPEC coverage on a SPEC-less plan) is not-applicable, never classified as a no-op.

On a no-op, re-dispatch that lens **exactly one** time, prepending this hardened retry prefix to its original prompt (`<target>` = the plan folder's `README.md` and `task-*.md`):

    RETRY (hardened, one attempt only): Your very first action MUST be a Read of <target>. Emit no prose before that Read. Produce your structured output (the findings or verdict file this prompt names, or your returned digest if it names none) before any returned prose. Then perform the original task below exactly as written.

A second consecutive no-op does not re-dispatch a third time; instead run that lens inline (the **inline fallback**): perform the lens's review yourself, producing the same findings JSON shape, and fold those findings into the 4.6b collection below so they re-enter the normal apply path exactly like a dispatched lens's findings. Record the degraded lens and its disposition (`retried_recovered` or `inline_fallback`) in the `## Audit notes` section (4.6b below).

#### 4.6b. Apply findings

Collect findings across all lenses. The plan is editable and unsaved-to-handoff, so applying a fix is just rewriting plan files, no ceremony.

- **Localized findings** (a wrong contract, a missing acceptance criterion, an uncovered UAT): fold the fix directly into the affected `task-*.md` or `README.md` yourself.
- **Structural findings** (the phase graph is wrong, tasks need re-factoring across phases): re-spawn the planner (step 4) with the surviving findings appended as a correction directive, rather than hand-patching the graph. This goes through the same `PLAN_DIR` and overwrites the flawed artifacts.

**Interactive:** surface each material (non-`low`) finding to the user before applying (issue, evidence, recommendation; apply / keep / revise); apply `low` findings silently. **Auto-mode:** auto-apply unambiguous fixes; if a repair is ambiguous (more than one defensible fix), leave the plan unchanged and record the finding in a `## Audit notes` section appended to `README.md` so the orchestrator and user see it. If the audit re-spawned the planner, re-run step 4.5 against the regenerated folder before proceeding.

**Degraded-coverage record (both modes).** Independent of the ambiguous-repair recording above, if any lens from 4.6a was retried or ran as an inline fallback, append one line per degraded lens to the same `## Audit notes` section in `README.md` (creating the section if it does not already exist), naming the lens and its disposition (`retried_recovered` or `inline_fallback`), so a reader can tell a clean lens from a degraded one. Write this line in interactive mode as well as auto-mode; it is not gated behind the auto-only ambiguous-repair branch above.

**Close the audit window (cost-ledger breadcrumb).** The audit unit is now complete (findings applied, and any structural re-spawn resolved). Capture the end and write the FC-1 breadcrumb by sourcing the FC-5 lib and calling its single breadcrumb writer, to the feature-namespaced path. A spec-derived plan is namespaced by the SPEC id, not the plan-dir basename, so two SPECs planned concurrently never collide on one shared breadcrumb. Do not inline `jq -n` here, the write goes through `gaia_audit_window_write` so the same code path a unit test exercises is the one production runs:

```bash
AUDIT_WINDOW_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
. .gaia/scripts/audit-window-lib.sh 2>/dev/null || true
audit_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$audit_common_dir" in /*) audit_abs="$audit_common_dir" ;; *) audit_abs="$PWD/$audit_common_dir" ;; esac
AUDIT_CACHE_DIR="$(cd "$(dirname "$audit_abs")" 2>/dev/null && pwd)/.gaia/local/cache"
if [[ -n "${SPEC_PATH:-}" ]]; then
  AUDIT_SPEC_ID="$(basename "$(dirname "$SPEC_PATH")")"
  AUDIT_WINDOW_PATH="$AUDIT_CACHE_DIR/audit-window-${AUDIT_SPEC_ID}-plan.json"
  AUDIT_LENSES='["DP","CG","COV"]'
else
  AUDIT_WINDOW_PATH="$AUDIT_CACHE_DIR/audit-window-$(basename "$PLAN_DIR").json"
  AUDIT_LENSES='["DP","CG"]'
fi
gaia_audit_window_write \
  "$AUDIT_WINDOW_PATH" \
  "${CLAUDE_CODE_SESSION_ID}" \
  "$AUDIT_WINDOW_START" "$AUDIT_WINDOW_END" \
  "$AUDIT_LENSES" "" || true
```

Note the explicit empty 6th argument: plan audits have no intensity tier, so the writer omits the `intensity` key. Never key the spec-derived path on `$(basename "$PLAN_DIR")`, that basename is the literal `plan`/`plan-2` and is identical across every SPEC, so two SPECs planned concurrently would collide on one shared breadcrumb and mutually degrade. This call is best-effort (`|| true`) and never blocks the handoff.

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
folder and a linked worktree), writes the plan folder's `cost.json` sidecar (the `plan` record), and
prints the four billing buckets plus a total and the elapsed time. The KICKOFF execution phase
later adds an independent `execute` record to the same `cost.json` (via the git-op hook, on each
commit); the two records are tracked separately and never overwrite or sum each other. A spec-derived
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
  # doubles as both the feature identity and the cost.json record's plan_slug field.
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
(`AskUserQuestion`-less) mode. The step-5 report surfaces the cost from this tally, using the pinned one-line format defined there. This same
call reads and deletes the step-4.6 audit-window breadcrumb (the feature-namespaced
`audit-window-<spec_id>-plan.json` or `audit-window-<plan-id>.json`) if present, nesting an
`audit.adversarial` annotation into this `plan` record when the window resolves.

### 5. Report to user

Output a short summary of what's in `$PLAN_DIR/`, then report the cost as exactly one line (do not restate the four-bucket tally block), then emit the copy-paste prompt the user drops into a fresh Claude Code session to start the orchestrator cold.

Cost line: `Cost: ~<total> tokens, $<dollars>, <elapsed>`, where `<total>` is the token count abbreviated to millions with one decimal and a `~` prefix (e.g. `~2.4M`), `<dollars>` is `$X.XX`, and `<elapsed>` is the `<N>h<M>m<S>s` figure. Source the figures by whether the plan derives from a SPEC:

- **Spec-derived** (`SPEC_PATH` set): the step-4.8 tally has already written the `plan` ledger row, so read the running spec+plan cycle from the roll-up reader, substituting the plan's `SPEC-NNN` id (the one derived in step 4.8):

  ```bash
  if [ -x .gaia/scripts/token-rollup.sh ]; then
    bash .gaia/scripts/token-rollup.sh --spec-id "<SPEC-NNN>" || true
  fi
  ```

  Take `<total>`, `<dollars>`, and `<elapsed>` from the reader's grand `Total` and `Est. cost (USD)` total lines, and append a stage breakdown `(spec $X.XX + plan $X.XX)` from its per-stage dollar rows.
- **Spec-less** (`--plan-id` path): take total and elapsed from the step-4.8 printed tally and read `<dollars>` from the `dollars` field of the `plan` record in `$PLAN_DIR/cost.json`; emit the line with no breakdown.

Never fabricate: if a dollar figure is null or unpriced write `cost unavailable` in its place; if elapsed is unavailable drop that term; if any figure is a partial lower bound append ` (partial: lower bound)`. This line reads identically to the `/gaia-spec` cost line (spec reference, step 9) and the orchestrator's full-cycle line; keep the three in sync.

The prompt is a single line, exactly:

```
Read <absolute-path-to-PLAN_DIR>/KICKOFF.md and execute it.
```

For example `.../.gaia/local/specs/SPEC-NNN/plan/KICKOFF.md` for a spec-derived plan, or `.../.gaia/local/plans/{slug}/KICKOFF.md` for a spec-less plan. Use `$PLAN_DIR/KICKOFF.md` (the absolute path resolved in step 3). The path MUST be absolute so the cold Claude session has no working-directory ambiguity. Do not include any other instruction, the orchestrator's behavior lives in `KICKOFF.md`.

**Print the prompt as a fenced code block** so the user can select and copy it manually.

Then print one trailing line: `Type /clear and paste the prompt above.`
