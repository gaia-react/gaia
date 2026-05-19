# /gaia plan

Plan a complex feature using the task orchestration pattern. Do not implement anything.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `plan`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want me to orchestrate?"** and wait for the response before continuing.

#### 1a. Detect SPEC reference

Check the description for a SPEC reference. The canonical form (emitted by `/gaia spec`) is:

    SPEC-NNN: <intent first line> — see .gaia/local/specs/SPEC-NNN/SPEC.md

Match either pattern:
- A path matching `.gaia/local/specs/SPEC-\d+/SPEC\.md`
- A `SPEC-\d+:` prefix at the start of the description

If matched:

1. Read the referenced SPEC file. Its full content is the source-of-truth feature description; the short string passed via `$ARGUMENTS` is just the dispatch summary.
2. Extract the SPEC id (e.g. `SPEC-005`). Cache the lowercased form (`spec-005`) as `SPEC_SLUG_SEED` for use in step 3.
3. Cache the absolute SPEC path as `SPEC_PATH` for use in the planner prompt (step 4) — the planner will reference it in `README.md`.

If no SPEC reference is detected, `SPEC_SLUG_SEED` and `SPEC_PATH` are unset; step 3 falls back to deriving a slug from the description directly.

### 2. Check model

Check your current model from session context.

- If you are on Opus, skip to step 3.
- If not, call `AskUserQuestion` with:
  - question: `"You're on [model name]. Use Opus for planning?"`
  - header: `"Model"`
  - options:
    - `{ label: "Use Opus (Recommended)", description: "Spawn the planning agent on Opus 4.7 for higher-quality plans." }`
    - `{ label: "Use [model name]", description: "Keep the current model." }`
  - If user picks option 1: spawn the agent with `model: opus`.
  - If user picks option 2: spawn without a model override (inherit current).

### 3. Resolve plan directory

Derive a short kebab-case slug from the feature description (e.g. "auth rework" → `auth-rework`).

**If `SPEC_SLUG_SEED` was set in step 1a, the slug MUST start with it** (e.g. `spec-005-cards-layout`, not `cards-layout`). This makes plan→SPEC discovery a one-line `ls .gaia/local/plans/ | grep ^spec-005-` and groups all plans for a given SPEC together.

Resolve the absolute plan directory, suffixing with `-2`, `-3`, … if one already exists, then create it:

```bash
ROOT="$(git rev-parse --show-toplevel)"
SLUG="<kebab-slug, prefixed with $SPEC_SLUG_SEED if set>"
PLAN_DIR="${ROOT}/.gaia/local/plans/${SLUG}"
n=2
while [[ -e "$PLAN_DIR" ]]; do
  PLAN_DIR="${ROOT}/.gaia/local/plans/${SLUG}-${n}"
  n=$((n+1))
done
mkdir -p "$PLAN_DIR"
```

Cache the resolved absolute `PLAN_DIR`; interpolate it into the planner prompt below and the kickoff prompt in step 5. The collision suffix lets parallel `/gaia plan` invocations (including multiple slices dispatched from one `/gaia spec`) coexist without overwriting each other.

### 4. Spawn planning agent

Launch a `general-purpose` Agent with the model determined above and this prompt. Interpolate every `{PLAN_DIR}` token with the absolute path resolved in step 3. If `SPEC_PATH` was set in step 1a, interpolate every `{SPEC_PATH}` token with that absolute path; if unset, delete the `**Source SPEC**` paragraph below before sending.

---

You are planning a feature using task orchestration. Do not implement anything. Investigate the codebase, then write the plan files directly to disk.

**Plan directory:** `{PLAN_DIR}`

**Source SPEC:** `{SPEC_PATH}` — read this file FIRST. Its `intent`, `UATs`, and `clarifications.answered[]` are authoritative for what to plan; the dispatch summary in `Feature:` below is just a label. Reference the SPEC id in `README.md`'s `## Source SPEC` section.

**Write rules.**

- You may write only under `{PLAN_DIR}/`. Never edit source files, configs, or anything outside this directory.
- Final plan artifacts go directly under `{PLAN_DIR}/` (no subdirectories for deliverables).
- For ephemeral scratch (mid-investigation notes, intermediate research dumps), create a unique subdirectory under `{PLAN_DIR}/.work/` via `mktemp -d "{PLAN_DIR}/.work/<role>.XXXXXX"`. Never write directly to `.work/`, and never touch another subdir there — peer agents may own it. Delete your own subdir before returning.
- If you spawn sub-subagents in parallel, each must create its own `mktemp -d` scratch subdir under `{PLAN_DIR}/.work/`. The parent does a defensive cleanup of `{PLAN_DIR}/.work` after you return; treat that as belt-and-suspenders, not as your cleanup.

**Feature:** {feature description from step 1}

First, read `wiki/concepts/Task Orchestration.md`.

Then write the following files directly to `{PLAN_DIR}/`:

1. **One task doc per parallel workstream** — `{PLAN_DIR}/task-{name}.md`. Each must be fully self-contained for a fresh-context sub-agent and include:
   - Context and motivation
   - Interface contracts (types, function signatures, file exports)
   - Files to touch (with line-range hints where possible)
   - Acceptance criteria (concrete and testable)
   - Dependencies on other tasks in this plan

2. **`{PLAN_DIR}/README.md`** — task graph showing phases, which tasks run in parallel within each phase, and the frozen interface contracts shared across tasks. **If `{SPEC_PATH}` was provided** (i.e. this plan was derived from a SPEC), the README MUST open with a `## Source SPEC` section naming the SPEC id and the absolute path, so plan→SPEC discovery is one read away. Format: `Derived from {SPEC-id} ({SPEC_PATH}).`

3. **`{PLAN_DIR}/ORCHESTRATOR.md`** — instructions for running the plan. Must cover:
   - **RUNNING sentinel.** As the very first step, write a sentinel file at `{PLAN_DIR}/RUNNING`. Content:

     ```
     branch: <output of git branch --show-current>
     slug: <basename of {PLAN_DIR}>
     started: <current UTC time, ISO 8601, e.g. 2026-05-19T14:32:00Z>
     ```

     This file is deleted automatically when the plan directory is removed during final self-cleanup. Its purpose: a concurrently starting orchestrator for the same branch can detect this run is in-flight.

   - **Pre-flight branch policy.** Check the current branch.

     **If HEAD is on `main`/`master`:** Ask the user how to isolate the work via `AskUserQuestion`:

     - question: `"On main. How should this plan's work be isolated?"`
     - header: `"Branch mode"`
     - options (in this exact order):
       1. `{ label: "Create a feature branch in place (Recommended)", description: "Default. Branch is cut from HEAD and the orchestrator works in the current checkout. Simple, predictable, safe." }`
       2. `{ label: "Create a git worktree (Experimental — use with care)", description: "Cuts a linked worktree under .claude/worktrees/. Lets you keep main's checkout untouched, but the worktree lifecycle has known rough edges (post-merge cleanup, isolation-context detection, shared-state symlink hand-off). Only choose if you understand the trade-offs." }`

     Do not silently default; the prompt fires every time HEAD is `main`/`master`. If the user picks "Other" with custom text, treat it as a request for an alternative isolation mode and surface a clarifying question rather than guessing — feature-branch and worktree are the two supported modes.

     **If HEAD is on any other branch:** Scan for a live concurrent orchestrator before proceeding. Run:

     ```bash
     BRANCH="$(git branch --show-current)"
     PLAN_SLUG="$(basename "{PLAN_DIR}")"
     CONCURRENT_LIVE=""
     for running_file in .gaia/local/plans/*/RUNNING; do
       [[ -f "$running_file" ]] || continue
       [[ "$(basename "$(dirname "$running_file")")" == "$PLAN_SLUG" ]] && continue
       file_branch="$(grep "^branch:" "$running_file" | cut -d' ' -f2)"
       [[ "$file_branch" != "$BRANCH" ]] && continue

       # Signal 1: branch must still exist
       git show-ref --verify --quiet "refs/heads/$BRANCH" || continue

       # Signal 2: PR state (graceful fallback if gh unavailable)
       pr_state="$(gh pr list --head "$BRANCH" --json state --jq '.[0].state' 2>/dev/null || true)"
       [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]] && continue

       # Signal 3: age fallback when no PR exists yet (> 4 h with no PR = stale)
       if [[ -z "$pr_state" ]]; then
         started="$(grep "^started:" "$running_file" | cut -d' ' -f2)"
         epoch_started="$(date -d "$started" +%s 2>/dev/null \
           || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null \
           || echo 0)"
         age_secs=$(( $(date +%s) - epoch_started ))
         [[ "$age_secs" -ge 14400 ]] && continue
       fi

       CONCURRENT_LIVE="$running_file"
       break
     done
     ```

     If `CONCURRENT_LIVE` is non-empty, a live concurrent orchestrator is running on this branch. Ask the user via `AskUserQuestion`:

     - question: `"A plan orchestrator is already running on branch '{branch}'. How should this plan proceed?"`
     - header: `"Concurrent plan"`
     - options (in this exact order):
       1. `{ label: "Create a worktree (Recommended)", description: "Cut a linked worktree off main for this plan's work. Full isolation — the two orchestrators edit separate working trees and cannot conflict." }`
       2. `{ label: "Continue on this branch", description: "Proceed on the same branch. Safe only if this plan's file edits do not overlap with the running orchestrator's. You accept the risk of concurrent edit conflicts." }`
       3. `{ label: "Defer — cancel for now", description: "Do not proceed. Come back once the current orchestrator has finished and the branch is clean." }`

     Act on the answer:
     - **"Create a worktree"**: follow the worktree creation and operation procedure in this file's worktree sections (same path as if the user had chosen worktree from main).
     - **"Continue on this branch"**: proceed. No further warning.
     - **"Defer — cancel for now"**: stop immediately. Emit: `"Deferred. Re-run the kickoff once the current orchestrator has finished and you are back on main or on an uncontested branch."` Do not commit, push, or modify any files.
     - **"Other"**: treat as a request for an alternative mode and ask a clarifying question rather than guessing.

     If `CONCURRENT_LIVE` is empty (no live concurrent detected): proceed without prompting.
   - **Phase order** with per-phase quality gates (`pnpm typecheck && pnpm lint`).
   - **Pre-merge `code-review-audit` (non-skippable).** Before any `gh pr merge` call, the orchestrator spawns the `code-review-audit` agent on the current branch. The agent's clean pass writes `.gaia/local/audit/<HEAD-sha>.ok`, which the deny-hook (`.claude/hooks/pr-merge-audit-check.sh`) gates `gh pr merge` on. The orchestrator does NOT wait for the deny-hook to fire and learn from it — that round-trip is friction. Spawn the agent proactively. Contract: `wiki/concepts/PR Merge Workflow.md`. Verbatim agent-spawn template:

         Task(
           subagent_type="code-review-audit",
           prompt="Review all changes in the current branch compared to main. Identify security vulnerabilities, performance issues, code smells, anti-patterns, and refactoring opportunities."
         )

     If the agent reports Critical or unresolved Important issues, the orchestrator surfaces them, stops, and lets the user decide whether to fix and re-audit or abandon. The marker handshake is the gate; do not hand-write the marker. If the audit agent declines to write the marker, the report names what remains unaddressed; resolve those, commit, push, re-spawn — exactly as the contract specifies.
   - **Sub-agent invocation:** the verbatim prompt template for each task sub-agent. Sub-agents do NOT commit, push, or open/update the PR — they only edit files and report. The orchestrator owns all git operations. **The prompt template MUST require sub-agents to end their return with a `## Notes for orchestrator` section** containing any of: `### Findings` (non-obvious things they noticed), `### Deviations from plan` (where the task spec was wrong / they had to work around it), `### Follow-ups` (work the user should consider after merge). Subsections may be empty or omitted; only non-trivial signal belongs here — routine "phase done, tests green" status does NOT.
   - **Orchestrator-owned git flow.** After each phase that produces changes (and only once the quality gate is clean), the orchestrator stages, commits with a meaningful message, and pushes. The orchestrator opens the PR after the first phase's commit lands on the remote (using `gh pr create`) and updates it with subsequent commits. Never commit a broken state.
   - **Phase findings ledger (`{PLAN_DIR}/SUMMARY.md`).** Append-only file the orchestrator maintains across the run, so sub-agent observations survive context compression. After each phase, the orchestrator appends a `## Phase N — <title>` block containing the phase's commit short-SHA and the merged `Notes for orchestrator` content from every sub-agent in that phase. If a phase produced no notes (all sub-agents reported only routine status), append the phase heading with `_No notes._` so the ledger reflects the full run. Sub-agents do not write to this file directly; the orchestrator owns it.
   - **Stop conditions.** On any sub-agent failure or quality-gate failure: STOP and surface to the user. Do not "fix and continue", do not commit, do not push. Before stopping, append the failure context (which phase, which sub-agent, error) to `SUMMARY.md` under a `## Phase N — <title> (HALTED)` block so the user and any follow-up session see the same record.
   - **Final summary.** After all implementation phases pass and the final commit is pushed, before awaiting merge confirmation, **read `{PLAN_DIR}/SUMMARY.md`** and print a brief summary to the user: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, quality-gate status, and the highest-signal findings/deviations/follow-ups drawn from `SUMMARY.md` so nothing is lost to context compression. Keep it tight — a few lines plus the surfaced notes, not a recap of every change.
   - **Final self-cleanup phase (last step before merge).** After all implementation phases pass and the user has reviewed the PR and confirmed it is ready to merge, the orchestrator deletes its own plan folder so scaffolding does not persist locally. Derive a relative path first to avoid the absolute-path rm guard: `ROOT="$(git rev-parse --show-toplevel)"; PLAN_REL="${PLAN_DIR#"$ROOT/"}"; rm -rf "$PLAN_REL"`. This removes `SUMMARY.md` along with everything else — by this point its content has already been surfaced in the Final summary. Then check `git check-ignore .gaia/local/plans/` — if it is gitignored (the GAIA default), the deletion is invisible to git: skip the commit and report "plan folder removed locally; gitignored, no commit needed." If the path is tracked, commit and push the deletion as the final commit on the PR. If the user explicitly asks to keep the plan folder for archival, the orchestrator skips the deletion and reports.
   - **Post-merge worktree cleanup (worktree-mode runs only).** When the orchestrator's pre-flight chose worktree mode (or the run was dispatched into a worktree by upstream tooling), the post-merge phase runs the cleanup procedure below AFTER the user confirms the PR is merged. The procedure detects the squash-merge state and discards the worktree without prompting (the SPEC clarifications.answered confirms pre-consent: the orchestrator told the user "after merge, the worktree will be discarded" before opening the PR; the user merging the PR is the consent).

     1. Confirm merge via `gh pr view <N> --json state`. Parse the JSON; require `.state == "MERGED"`. If not merged, do NOT proceed — surface to user and stop.
     2. **Isolation-context check (see next bullet).** If the orchestrator is running inside an isolated subagent context, emit a continuation prompt and STOP — do NOT call `ExitWorktree`.
     3. Otherwise, call `ExitWorktree({action: "remove", discard_changes: true})` directly. `discard_changes: true` is safe and correct: a squash-merge absorbs every commit on the worktree branch, but those commits are not reachable as ancestors of `main`. Without `discard_changes: true` the runtime conservatively refuses, treating the unreachable commits as unsynced work. The merged-state confirmation in step 1 proves the work is preserved.
     4. Report a one-line success: `worktree discarded; PR #<N> squash-merged as <short-sha>`.

     Never call `ExitWorktree` first and treat its refusal as the trigger for the discard retry — that's the backstop pattern this section replaces. The merged-state confirmation is the primary signal source.
   - **Isolation-context detection (worktree-mode runs only).** The runtime refuses `ExitWorktree` calls from agents dispatched with `isolation: "worktree"` or any `cwd` override (the refusal text is `ExitWorktree cannot be called from a subagent with a cwd override`). Before calling `ExitWorktree`, the orchestrator detects this context. Detection signal (v1):

     - **Primary signal:** the orchestrator was invoked via `Agent(...)` with `isolation: "worktree"`. The orchestrator knows this if its dispatch was a sub-agent task (i.e. the kickoff prompt was passed to a Task / Agent call from a parent session) AND the cwd is a worktree path. If the orchestrator can read the runtime's session metadata to confirm isolation directly, it does so; otherwise it heuristically checks: if `pwd` resolves to a path under `.claude/worktrees/` AND the parent session that launched the orchestrator is unknown, treat as isolated.
     - **Fallback:** if uncertain, attempt `ExitWorktree({action: "remove", discard_changes: true})` and check the runtime response. If the response contains `cannot be called from a subagent`, treat the call as never-issued (it's a refusal, not a destructive action), branch into the continuation-prompt path, and STOP. (This is the only place the orchestrator may use the deny-as-signal pattern; everywhere else, proactive detection is required.)

     When detected, the orchestrator does NOT call `ExitWorktree`. It emits this copy-paste continuation prompt to the user, then stops:

         The worktree at <ABSOLUTE-PATH-TO-WORKTREE> is ready to discard.
         PR #<N> squash-merged as <short-sha>. From a fresh top-level Claude
         Code session rooted at <ABSOLUTE-PATH-TO-MAIN-CHECKOUT>, call:

             ExitWorktree({worktree: "<ABSOLUTE-PATH-TO-WORKTREE>", discard_changes: true})

     No error surfaced. No `ExitWorktree` invocation in this branch. The continuation prompt is self-contained — the user pastes it into a new session and the cleanup completes without further investigation.

4. **`{PLAN_DIR}/KICKOFF.md`** — the orchestrator's kickoff prompt itself, ready to be read and executed verbatim. The file is the prompt — no preamble, no "copy and paste below" instruction, no surrounding commentary, no `---` separators framing the prompt as a quoted block. The opening line addresses the orchestrator directly (e.g. "You are the orchestrator for the {feature} plan…"). Must be fully self-contained with no assumed context: absolute paths to `README.md` and `ORCHESTRATOR.md`, the goal, hard rules, and the execution outline. The kickoff also includes a one-line reference to the pre-merge `code-review-audit` obligation (e.g. "Before any `gh pr merge`, run the `code-review-audit` agent — see ORCHESTRATOR.md's Pre-merge code-review-audit section."). The line ensures a cold-started orchestrator reads the requirement before doing any work, surviving any context compression that drops the ORCHESTRATOR.md content from the first read.

Before returning, delete `{PLAN_DIR}/.work/` if you created it. Use a relative path to avoid the absolute-path rm guard: `ROOT="$(git rev-parse --show-toplevel)"; PLAN_REL="${PLAN_DIR#"$ROOT/"}"; rm -rf "$PLAN_REL/.work"`.

**Return format (required).** Return only a small structured payload — no file contents, no recap of what's inside the files. The parent reads the files itself if it needs to.

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

After the planner returns, run defensive cleanup and confirm the required artifacts exist:

```bash
ROOT="$(git rev-parse --show-toplevel)"
PLAN_REL="${PLAN_DIR#"$ROOT/"}"
[ -d "$PLAN_REL/.work" ] && rm -rf "$PLAN_REL/.work"
test -f "$PLAN_DIR/README.md" \
  && test -f "$PLAN_DIR/ORCHESTRATOR.md" \
  && test -f "$PLAN_DIR/KICKOFF.md" \
  && ls "$PLAN_DIR"/task-*.md >/dev/null 2>&1
```

If any required file is missing, surface the failure to the user with the planner's return payload. Do not retry silently — the user decides whether to re-spawn or investigate. Never proceed to step 5 with an incomplete plan folder.

### 4.6. Telemetry: revision detection

If the slug-collision suffix from step 3 is greater than 1 (i.e. `PLAN_DIR` ends with `-2`, `-3`, …) AND `SPEC_PATH` was set in step 1a, this plan is a revision of a prior plan. Emit a `plan_revised` mentorship event so the over-time pattern detector sees it.

Derive the prior plan directory and item counts, then emit. Failure to emit must NEVER block the user's flow — wrap in `|| true`:

```bash
# Re-derive the suffix from PLAN_DIR (the same suffix used in step 3).
PLAN_BASENAME="$(basename "$PLAN_DIR")"
# PLAN_BASENAME is `${SLUG}-N` for N>=2 collisions; ${SLUG} for the first.
if [[ "$PLAN_BASENAME" =~ -([0-9]+)$ ]]; then
  SUFFIX="${BASH_REMATCH[1]}"
  if [[ "$SUFFIX" -gt 1 && -n "${SPEC_PATH:-}" ]]; then
    BASE_SLUG="${PLAN_BASENAME%-${SUFFIX}}"
    PRIOR_SUFFIX=$((SUFFIX - 1))
    if [[ "$PRIOR_SUFFIX" -eq 1 ]]; then
      PRIOR_DIR="${ROOT}/.gaia/local/plans/${BASE_SLUG}"
    else
      PRIOR_DIR="${ROOT}/.gaia/local/plans/${BASE_SLUG}-${PRIOR_SUFFIX}"
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
    SPEC_ID="$(basename "$SPEC_PATH" .md)"
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
- `revision-class` is hardcoded to `scope_change` in v1.0.0 — the most common case. Future refinement may compute the class from the diff between prior and new task lists.
- The emit fires only when `SPEC_PATH` is set, because `plan_revised` requires `--spec-id`. Plans authored without a SPEC reference do not currently emit revision events; that surface lands when consumer-driven cloud event payloads ship.
- The emit is not gated on mentorship opt-in here; the CLI itself short-circuits for mentorship-disabled state and always emits the cloud projection.

### 5. Report to user

Output a short summary of what's in `$PLAN_DIR/`, then emit the copy-paste prompt the user drops into a fresh Claude Code session to start the orchestrator cold.

The prompt is a single line, exactly:

```
Read <absolute-path-to>/.gaia/local/plans/{slug}/KICKOFF.md and execute it.
```

Use `$PLAN_DIR/KICKOFF.md` (the absolute path resolved in step 3). The path MUST be absolute so the cold Claude session has no working-directory ambiguity. Do not include any other instruction — the orchestrator's behavior lives in `KICKOFF.md`.

**Try to copy the prompt to the system clipboard** with the first available tool. Probe in this order — the first match wins; if none exist, skip silently:

```bash
PROMPT='Read {absolute path to KICKOFF.md} and execute it.'
COPIED=0
if command -v pbcopy >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | pbcopy && COPIED=1
elif command -v wl-copy >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | wl-copy && COPIED=1
elif command -v xclip >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | xclip -selection clipboard && COPIED=1
elif command -v xsel >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | xsel --clipboard --input && COPIED=1
elif command -v clip.exe >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | clip.exe && COPIED=1
elif command -v clip >/dev/null 2>&1; then
  printf '%s' "$PROMPT" | clip && COPIED=1
fi
```

**Always print the prompt as a fenced code block**, regardless of whether the copy succeeded — the user may want to verify or copy manually.

Then print one trailing line, conditional on `$COPIED`:

- Copy succeeded (`COPIED=1`): `Prompt copied to clipboard. Type /clear then paste.`
- No tool found (`COPIED=0`): `Type /clear and paste the prompt above.`
