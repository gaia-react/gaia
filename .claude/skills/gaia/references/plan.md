# /gaia plan

Plan a complex feature using the task orchestration pattern. Do not implement anything.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `plan`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want me to orchestrate?"** and wait for the response before continuing.

#### 1a. Detect SPEC reference

Check the description for a SPEC reference. The canonical form (emitted by `/gaia spec`) is:

    SPEC-NNN: <intent first line> — see .gaia/local/specs/SPEC-NNN.md

Match either pattern:
- A path matching `.gaia/local/specs/SPEC-\d+\.md`
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
- If you spawn sub-subagents in parallel, each must create its own `mktemp -d` scratch subdir under `{PLAN_DIR}/.work/`. The parent does a defensive `rm -rf {PLAN_DIR}/.work` after you return; treat that as belt-and-suspenders, not as your cleanup.

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
   - **Pre-flight branch policy.** Check the current branch. If HEAD is on `main`/`master`, the orchestrator ASKS the user whether to (a) create a feature branch in place or (b) create a git worktree, then acts on the answer. If HEAD is on any other branch, assume it is the work branch and proceed.
   - **Phase order** with per-phase quality gates (`pnpm typecheck && pnpm lint`).
   - **Sub-agent invocation:** the verbatim prompt template for each task sub-agent. Sub-agents do NOT commit, push, or open/update the PR — they only edit files and report. The orchestrator owns all git operations.
   - **Orchestrator-owned git flow.** After each phase that produces changes (and only once the quality gate is clean), the orchestrator stages, commits with a meaningful message, and pushes. The orchestrator opens the PR after the first phase's commit lands on the remote (using `gh pr create`) and updates it with subsequent commits. Never commit a broken state.
   - **Stop conditions.** On any sub-agent failure or quality-gate failure: STOP and surface to the user. Do not "fix and continue", do not commit, do not push.
   - **Final summary.** After all implementation phases pass and the final commit is pushed, before awaiting merge confirmation, print a brief summary to the user: phases completed, sub-agents run, files touched (count), commits pushed (count + short SHAs), PR URL, and quality-gate status. Keep it tight — a few lines, not a recap of every change.
   - **Final self-cleanup phase (last step before merge).** After all implementation phases pass and the user has reviewed the PR and confirmed it is ready to merge, the orchestrator deletes its own plan folder (`rm -rf {PLAN_DIR}/`) so scaffolding does not persist locally. Then check `git check-ignore .gaia/local/plans/` — if it is gitignored (the GAIA default), the deletion is invisible to git: skip the commit and report "plan folder removed locally; gitignored, no commit needed." If the path is tracked, commit and push the deletion as the final commit on the PR. If the user explicitly asks to keep the plan folder for archival, the orchestrator skips the deletion and reports.

4. **`{PLAN_DIR}/KICKOFF.md`** — the orchestrator's kickoff prompt itself, ready to be read and executed verbatim. The file is the prompt — no preamble, no "copy and paste below" instruction, no surrounding commentary, no `---` separators framing the prompt as a quoted block. The opening line addresses the orchestrator directly (e.g. "You are the orchestrator for the {feature} plan…"). Must be fully self-contained with no assumed context: absolute paths to `README.md` and `ORCHESTRATOR.md`, the goal, hard rules, and the execution outline.

Before returning, delete `{PLAN_DIR}/.work/` if you created it.

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
rm -rf "$PLAN_DIR/.work"
test -f "$PLAN_DIR/README.md" \
  && test -f "$PLAN_DIR/ORCHESTRATOR.md" \
  && test -f "$PLAN_DIR/KICKOFF.md" \
  && ls "$PLAN_DIR"/task-*.md >/dev/null 2>&1
```

If any required file is missing, surface the failure to the user with the planner's return payload. Do not retry silently — the user decides whether to re-spawn or investigate. Never proceed to step 5 with an incomplete plan folder.

### 4.6. Telemetry: revision detection (UAT-028)

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
    bin/gaia telemetry emit plan_revised \
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
- The emit is not gated on mentorship opt-in here; the CLI itself short-circuits for mentorship-disabled state and always emits the cloud projection (UAT-009).

### 5. Report to user

Output a short summary of what's in `$PLAN_DIR/`, then emit the copy-paste prompt the user drops into a fresh Claude Code session to start the orchestrator cold.

The prompt is a single line, exactly:

```
Read /Users/.../absolute/path/to/.gaia/local/plans/{slug}/KICKOFF.md and execute it.
```

Use `$PLAN_DIR/KICKOFF.md` (the absolute path resolved in step 3). Do not include any other instruction — the orchestrator's behavior lives in `KICKOFF.md`.

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
