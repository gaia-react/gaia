---
name: gaia
description: GAIA workflow router. Dispatches to the four user-invoked GAIA workflows - plan (task orchestration), handoff (session handoff doc), pickup (resume from handoff), audit (knowledge audit). Trigger on `/gaia <subcommand>` or natural-language asks like "kick off a plan", "write a handoff", "pick up where we left off", "audit the knowledge stores".
---

# GAIA Router

User-invoked GAIA workflows. The first argument selects the sub-command.

## Routing

Parse the first whitespace-separated token of `$ARGUMENTS`:

| First arg | Section to follow |
| --- | --- |
| `plan` | `## /gaia plan` |
| `handoff` | `## /gaia handoff` |
| `pickup` | `## /gaia pickup` |
| `audit` | `## /gaia audit` |
| (anything else, including empty) | print help |

Help message format:

    Usage: /gaia <subcommand> [args]

      plan [description]   Plan a feature using task orchestration
      handoff [notes]      Generate a session handoff document
      pickup               Restore context from the most recent handoff
      audit [--apply]      Audit memory + wiki for duplication and load cost

Strip the first arg before passing the remainder to the selected branch (i.e. inside the branch, `$ARGUMENTS` semantically refers to whatever followed the sub-command).

## /gaia plan

Plan a complex feature using the task orchestration pattern. Do not implement anything.

## Steps

### 1. Get description

If `$ARGUMENTS` (the args after `plan`) is non-empty, use it as the feature description.

Otherwise, ask: **"What do you want me to orchestrate?"** and wait for the response before continuing.

### 2. Check model

Check your current model from session context.

- If you are on Opus, skip to step 3.
- If not, ask: **"You're on [model name]. Use Opus for planning? (Y/n)"** — default yes.
  - Yes (or Enter): spawn the agent with `model: opus`.
  - No: spawn without a model override (inherit current).

### 3. Spawn planning agent

Launch a `general-purpose` Agent with the model determined above and this prompt:

---

You are planning a feature using task orchestration. Do not implement anything.

**Feature:** {feature description from step 1}

First, read `wiki/concepts/Task Orchestration.md`.

Then create the following in `.claude/plans/{slug}/` where `{slug}` is a short kebab-case slug derived from the feature description:

1. **One task doc per parallel workstream** — name each `task-{name}.md`. Each must be fully self-contained for a fresh-context sub-agent and include:
   - Context and motivation
   - Interface contracts (types, function signatures, file exports)
   - Files to touch (with line-range hints where possible)
   - Acceptance criteria (concrete and testable)
   - Dependencies on other tasks in this plan

2. **`README.md`** — task graph showing phases, which tasks run in parallel within each phase, and the frozen interface contracts shared across tasks.

3. **`ORCHESTRATOR.md`** — instructions for running the plan. Must cover:
   - **Pre-flight branch policy.** Check the current branch. If HEAD is on `main`/`master`, the orchestrator ASKS the user whether to (a) create a feature branch in place or (b) create a git worktree, then acts on the answer. If HEAD is on any other branch, assume it is the work branch and proceed.
   - **Phase order** with per-phase quality gates (`pnpm typecheck && pnpm lint`).
   - **Sub-agent invocation:** the verbatim prompt template for each task sub-agent. Sub-agents do NOT commit, push, or open/update the PR — they only edit files and report. The orchestrator owns all git operations.
   - **Orchestrator-owned git flow.** After each phase that produces changes (and only once the quality gate is clean), the orchestrator stages, commits with a meaningful message, and pushes. The orchestrator opens the PR after the first phase's commit lands on the remote (using `gh pr create`) and updates it with subsequent commits. Never commit a broken state.
   - **Stop conditions.** On any sub-agent failure or quality-gate failure: STOP and surface to the user. Do not "fix and continue", do not commit, do not push.
   - **Final self-cleanup phase (last step before merge).** After all implementation phases pass and the user has reviewed the PR and confirmed it is ready to merge, the orchestrator deletes its own plan folder (`rm -rf .claude/plans/{slug}/`, absolute path) so scaffolding does not persist locally. Then check `git check-ignore .claude/plans/{slug}/` — if `.claude/plans/` is gitignored (the GAIA default), the deletion is invisible to git: skip the commit and report "plan folder removed locally; gitignored, no commit needed." If the path is tracked, commit and push the deletion as the final commit on the PR. If the user explicitly asks to keep the plan folder for archival, the orchestrator skips the deletion and reports.

4. **`KICKOFF.md`** — the orchestrator's kickoff prompt itself, ready to be read and executed verbatim. The file is the prompt — no preamble, no "copy and paste below" instruction, no surrounding commentary, no `---` separators framing the prompt as a quoted block. The opening line addresses the orchestrator directly (e.g. "You are the orchestrator for the {feature} plan…"). Must be fully self-contained with no assumed context: absolute paths to `README.md` and `ORCHESTRATOR.md`, the goal, hard rules, and the execution outline.

Report the files created and the absolute path to `KICKOFF.md`.

---

### 4. Report to user

Output a short summary of what's in `.claude/plans/{slug}/`, then emit the copy-paste prompt the user drops into a fresh Claude Code session to start the orchestrator cold. The prompt is a single fenced code block containing exactly:

```
Read /Users/.../absolute/path/to/.claude/plans/{slug}/KICKOFF.md and execute it.
```

Use the absolute path to the `KICKOFF.md` you just created. Do not include any other instruction in the code block — the orchestrator's behavior lives in `KICKOFF.md`.

## /gaia handoff

Write a self-contained handoff doc so the next session can pick up cold without re-reading this conversation.

**When:** end of session, context break, or when state is non-obvious.

## Inputs

- `$ARGUMENTS` (the args after `handoff`) — optional inline notes from the user (decisions, gaps, open questions).
- Conversation transcript — primary source for accomplishments, decisions, gaps.
- Git state — branch, last commit, dirty files.

## Steps

### 1. Gather

Run in parallel:

- `git rev-parse --abbrev-ref HEAD` + `git log -1 --oneline` + `git status --short`
- Extract from conversation: files edited, commands run, decisions ("let's…", "go with…"), gaps ("missing", "TODO"), unresolved questions.
- Derive a kebab-case slug for the filename from the session's main thread (e.g. `watch-voice-cues`, `coach-voice-s04`).

### 2. Write

Path: `.claude/handoff/HANDOFF-{YYYY-MM-DD}-{slug}.md`

Use the template below. **Omit any section with no real content** — don't leave empty headings. Keep entries factual and concrete (file paths, commit hashes, command invocations). Cross-reference files with `@path/to/file:line` so the next session can jump straight in.

```markdown
# Session Handoff

**Date:** {YYYY-MM-DD HH:MM – HH:MM}
**Branch:** `{branch}`
**Context:** {one-sentence summary of the session's work}

---

## Accomplishments

- {what shipped / was built — include commit hashes if committed}

## Decisions

| Decision          | Rationale | Impact                           |
| ----------------- | --------- | -------------------------------- |
| {what was chosen} | {why}     | {effect on the codebase/product} |

## Gaps & Open Questions

### {Gap or question title}

**Status:** FIXED / PARTIAL / UNKNOWN / DEFERRED / INTENTIONAL
**Notes:** {what's known, what's uncertain, what's the likely culprit}
**Next check:** {concrete diagnostic or test to run}
**Reference:** `@path/to/file:line`

## Environment State

- **Branch:** `{branch}` — {pushed/dirty}
- **Background processes:** {e.g. `pnpm dev` still running}
- **Devices / simulators:** {physical device IDs, sim names, build installed}
- **Test user / data:** {relevant fixtures}

## Reference Files
```

@path/one
@path/two

```

## Next Actions

| # | Action | Effort |
|---|--------|--------|
| 1 | {concrete, testable step} | {5–30 min} |

---

**Resume:** `/pickup`
```

### 3. Confirm

Report in one line: saved path + count of accomplishments / decisions / gaps / next-actions. No ASCII boxes.

## Rules

- Do **not** dump the conversation verbatim — synthesize.
- Every "Next Action" must be concrete enough to execute without context.
- Every "Gap" must name a file and a diagnostic, not just "look into X".
- Skip empty sections entirely rather than writing "N/A".
- Never fabricate commit hashes, file paths, or device IDs — if unsure, omit.

## /gaia pickup

Rebuild "where did we leave off" at session start and suggest the next action.

## Steps

### 1. Locate

Find the most recent handoff:

- `ls -t .claude/handoff/HANDOFF-*.md | head -1`
- If none exists, fall back to `wiki/hot.md` (already loaded) and report "No handoff found — resuming from hot cache."

### 2. Read

Read the handoff file in full. Also run in parallel:

- `git rev-parse --abbrev-ref HEAD` + `git status --short` + `git log -1 --oneline`

Compare the handoff's stated branch/commit against current git state. Flag drift (new commits, different branch, dirty files) — the handoff may be stale.

### 3. Report

Give the user a tight status block (≤15 lines):

```
Branch: {current} {(drift from handoff if any)}
Last handoff: {filename} ({date})
Context: {one-line from handoff}

State:
- {1–3 bullets on what's done / in-flight}

Open:
- {1–3 bullets on gaps or next actions}

Suggested next: {highest-priority action from handoff, or "confirm direction"}
```

Do **not** paste the whole handoff back — the user wrote it, they know the shape. Synthesize.

### 4. Archive (after user confirms direction)

Once the user commits to a direction (picks an action, starts editing, or says "go"), move the consumed handoff to `.claude/handoff/archive/` so it doesn't pollute future pickups. Create the dir if missing. Do not archive until work has actually begun.

## Rules

- Hot cache (`wiki/hot.md`) auto-loads — don't re-read it unless the handoff is missing.
- If git state has diverged significantly from the handoff, say so explicitly before suggesting next actions.
- Never archive a handoff until the user has acted on it — premature archive loses context on a context-break mid-pickup.

## /gaia audit

## Execution model — READ FIRST

**Do not execute the playbook yourself in the current conversation.** Dispatch exactly one subagent via the `Agent` tool. The model depends on the mode. Each subagent runs in isolated context.

### Path resolution (portable — no hardcoding)

This command ships in a template and runs in many clones across many machines. Neither this file nor the subagent prompts may hardcode a project root or a user-scoped memory path. The subagent resolves both at the start of its run:

```bash
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
```

Every path below referenced as `$PROJECT_ROOT/...`, `$MEMORY_DIR/...`, or `$AGENT_MEMORY_DIR/...` is resolved by the subagent, not by this file.

### Branch on `$ARGUMENTS`

**If `$ARGUMENTS` does NOT contain `--apply` → research mode**

Spawn one `Agent`:

- `subagent_type`: `"general-purpose"`
- `model`: `"opus"`
- `description`: `"Knowledge audit (research)"`
- `prompt`: the string below (literal, no paraphrasing):

  > `ultrathink.`
  >
  > `You are Stage 1 of a two-stage knowledge audit. Your job is to PRODUCE A REPORT ONLY — do not mutate any files outside .claude/audit/. A separate Sonnet agent will execute the actions later.`
  >
  > `Before doing anything else, resolve these variables and use them for every path in the playbook:`
  >
  > ```bash
  > PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  > MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
  > AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
  > ```
  >
  > `Record the resolved values at the top of the report (both frontmatter and a visible line) so Stage 2 uses the same bindings.`
  >
  > `Read $PROJECT_ROOT/.claude/skills/gaia/SKILL.md and execute the "Research procedure" section (Steps 1–6). Write the report to $PROJECT_ROOT/.claude/audit/KNOWLEDGE-{YYYY-MM-DD-HHMM}.md using the exact "Report template" schema. Every action you propose must be mechanical — include every detail a literal-minded executor needs: absolute paths, line ranges, expected current content (verbatim snippet), replacement content (verbatim), and drift-check signals. No handwaving like "merge these" or "consolidate that".`

**If `$ARGUMENTS` contains `--apply` → apply mode**

Spawn one `Agent`:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Knowledge audit (apply)"`
- `prompt`: the string below (literal):

  > `You are Stage 2 of a two-stage knowledge audit. Stage 1 (Opus) produced a report. Your job is to execute the unchecked actions MECHANICALLY — do not reason about whether an action is correct, do not expand scope, do not merge or split actions.`
  >
  > `Before doing anything else, resolve these variables and use them for every path in the playbook:`
  >
  > ```bash
  > PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  > MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
  > AGENT_MEMORY_DIR="$HOME/.claude/agent-memory"
  > ```
  >
  > `Compare these to the "project_root" / "memory_dir" fields recorded in the report's frontmatter. If they differ, STOP and print a clear error — do not improvise.`
  >
  > `Read $PROJECT_ROOT/.claude/skills/gaia/SKILL.md and execute the "Apply procedure" section (Step 7). For every action: verify the expected-current-content drift signal matches; if it does, apply the change verbatim; if it does not, SKIP and note it in the final summary. Never improvise. Never invent replacements. If anything is ambiguous, skip.`

### After the subagent returns

Relay its final summary verbatim (report path + action counts, or done/skipped/failed counts). Do not re-do the work. Do not inline the report body.

---

## Research procedure

Audit the knowledge stores for duplication, stale entries, and auto-load bloat. **Wiki is the source of truth.** Memory is machine-local only. Auto-loaded files carry a token cost every session — keep them as pointers, push detail behind lazy wikilinks.

The report you produce is a **contract** to a Sonnet-level executor. Assume it can read, edit, and run bash, but will not reason about intent. Every action needs a literal before/after.

## Stores & load behavior

| Store                                          | Path                                            | Auto-loaded?                                                |
| ---------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------- |
| Machine-local project memory                   | `$MEMORY_DIR/`                                  | `MEMORY.md` (first 200 lines), individual entries on demand |
| Machine-local agent memory                     | `$AGENT_MEMORY_DIR/`                            | Per-agent, on demand                                        |
| Project agent memory                           | `$PROJECT_ROOT/.claude/agent-memory/`           | Per-agent, on demand                                        |
| Project CLAUDE.md (root)                       | `$PROJECT_ROOT/CLAUDE.md`                       | Auto at session start                                       |
| Wiki README                                    | `$PROJECT_ROOT/wiki/README.md`                  | On demand only                                              |
| Project rules                                  | `$PROJECT_ROOT/.claude/rules/*.md`              | Auto by `paths:` frontmatter match                          |
| Project commands                               | `$PROJECT_ROOT/.claude/commands/*.md`           | On invocation only                                          |
| Wiki hot cache                                 | `$PROJECT_ROOT/wiki/hot.md`                     | Auto at session start                                       |
| Wiki index                                     | `$PROJECT_ROOT/wiki/index.md`                   | On demand                                                   |
| Wiki domain pages                              | `$PROJECT_ROOT/wiki/<domain>/`                  | On demand                                                   |
| Nested `CLAUDE.md` files (any monorepo layout) | any `$PROJECT_ROOT/**/CLAUDE.md` below the root | Auto when cwd matches                                       |

## Step 0 — Prune old reports

Before writing the new report, self-maintain `$PROJECT_ROOT/.claude/audit/`:

- **Keep the newest 5 reports regardless of age** (floor — protects long gaps between runs).
- Of anything beyond the newest 5, **delete reports older than 30 days**.

```bash
if [ -d "$PROJECT_ROOT/.claude/audit" ]; then
  ls -t "$PROJECT_ROOT"/.claude/audit/KNOWLEDGE-*.md 2>/dev/null | tail -n +6 | while IFS= read -r f; do
    if [ -n "$(find "$f" -mtime +30 -print 2>/dev/null)" ]; then
      rm -- "$f"
    fi
  done
fi
```

Report the count pruned in the summary line at the end of the run (e.g. `pruned 2 stale reports`).

## Step 1 — Inventory

Run in parallel:

```bash
# Machine-local memory (resolved dynamically)
find "$MEMORY_DIR" -type f -name "*.md" 2>/dev/null
find "$AGENT_MEMORY_DIR" -type f -name "*.md" 2>/dev/null

# Project-local
find "$PROJECT_ROOT/.claude/agent-memory" -type f -name "*.md" 2>/dev/null
find "$PROJECT_ROOT/.claude/rules" -type f -name "*.md"

# Wiki
find "$PROJECT_ROOT/wiki" -type f -name "*.md"

# Auto-loaded CLAUDE.md set (covers root, wiki, and any downstream app subdirs)
find "$PROJECT_ROOT" -maxdepth 3 -name CLAUDE.md -not -path '*/node_modules/*'

# Word counts for auto-loaded files
wc -w "$PROJECT_ROOT"/CLAUDE.md "$PROJECT_ROOT"/wiki/hot.md "$PROJECT_ROOT"/.claude/rules/*.md 2>/dev/null
```

Record per file: path, word count, last-modified. Compute totals per store.

## Step 2 — Cross-store duplication

For every memory entry and every rules file, check whether the same fact lives in the wiki. Use `Grep` with 2–3 representative phrases from each entry. Classify each hit:

- **DUPLICATE** — fact already canonical in wiki → mark memory/rules entry for deletion
- **PROMOTE** — durable knowledge only in memory → propose moving to a specific wiki page (name the page)
- **KEEP-LOCAL** — genuinely machine-local (personal pref, machine path, unique dev env) → keep in memory
- **STALE** — references a file/branch/feature no longer present → mark for deletion

Rules-vs-wiki: a `.claude/rules/*.md` file is allowed to duplicate wiki content **only** if it exists to enforce auto-loading for a specific `paths:` glob. Otherwise it should link to the wiki page.

## Step 3 — Intra-wiki duplication

Scan `$PROJECT_ROOT/wiki/` for pages covering the same topic. For each cluster:

- Pick the most-complete page as canonical
- Propose merging the others into it (or converting them to redirects: a one-line page with `→ see [[Canonical]]`)
- Flag pages in `wiki/sources/` that duplicate content already synthesized in a domain page — `sources/` is archival, domain pages are active

## Step 4 — Auto-load budget

Targets (flag anything over):

| File                                                                               | Budget     | Rationale                                  |
| ---------------------------------------------------------------------------------- | ---------- | ------------------------------------------ |
| `wiki/hot.md`                                                                      | ≤200 words | Cache discipline per `wiki/hot.md` comment |
| `CLAUDE.md` (root)                                                                 | ≤400 words | Routing + principles only                  |
| `wiki/README.md`                                                                   | —          | On demand — no auto-load budget needed     |
| Any nested `CLAUDE.md` discovered in Step 1 (monorepo package, subapp, docs, etc.) | ≤400 words | Scoped routing                             |
| Any single `.claude/rules/*.md`                                                    | ≤200 lines | Focused rule                               |

For each over-budget file, propose one of: inline facts → wiki, consolidate duplicated sections, or split into narrower files.

## Step 5 — Link-efficiency audit

In every auto-loaded file (CLAUDE.md hierarchy, `wiki/hot.md`, rules):

- **Describes instead of points** — flag passages that restate content already in a wiki page (e.g. inlining a facts table instead of linking to the canonical wiki page). Propose replacing with wikilink.
- **Broken wikilinks** — `Grep` every `[[Name]]` against `wiki/index.md`. Flag misses.
- **Dead paths** — verify every file path referenced in auto-loaded files still exists.
- **Inlined source excerpts** — flag wiki pages that inline raw text from `wiki/sources/` instead of linking.

## Step 6 — Report

Write `$PROJECT_ROOT/.claude/audit/KNOWLEDGE-{YYYY-MM-DD-HHMM}.md`. Create `$PROJECT_ROOT/.claude/audit/` if missing. Also snapshot `git status --short` into the report's frontmatter so Stage 2 can detect drift.

### Report template (strict schema — Stage 2 parses this)

````markdown
---
generated: {YYYY-MM-DD HH:MM}
generator: audit-knowledge stage-1 opus-ultrathink
project_root: {resolved PROJECT_ROOT}
memory_dir: {resolved MEMORY_DIR}
agent_memory_dir: {resolved AGENT_MEMORY_DIR}
git_head: {commit hash}
git_status_snapshot: |
  {verbatim output of `git status --short` at research time}
---

# Knowledge Audit — {YYYY-MM-DD HH:MM}

Resolved paths (Stage 2 must match these):

- project_root: {resolved PROJECT_ROOT}
- memory_dir: {resolved MEMORY_DIR}
- agent_memory_dir: {resolved AGENT_MEMORY_DIR}

## Summary

- Stores scanned: {N files, M words total}
- Cross-store duplicates: {X}
- Intra-wiki duplicates: {Y}
- Auto-load total: {Z words} (budget: {total budget})
- Over-budget files: {list}
- Stale entries: {count}
- Broken links: {count}

## Actions

Each action is a fenced YAML block prefixed with a checkbox line. Stage 2 flips the checkbox from `[ ]` to `[x]` on success, `[~]` on skip, `[!]` on failure. Every block MUST include `expect` (verbatim snippet of current target content) and where applicable `after` (verbatim replacement). Paths MUST be absolute (already expanded — no `$PROJECT_ROOT` placeholders in action bodies).

### Delete

- [ ] `delete-{nnn}`
  ```yaml
  type: delete
  path: {absolute path}
  reason:
    {one line — cite canonical wiki page + line range where the same fact lives}
  expect_sha256: {sha256 of the file's current content}
  ```
````

### Delete-entry (remove a specific block from a multi-entry file, e.g. a heading section in MEMORY.md)

- [ ] `delete-entry-{nnn}`
  ```yaml
  type: delete-entry
  path: {absolute path}
  expect: |
    {verbatim block to remove, including heading — must match exactly}
  reason: {…}
  ```

### Promote (memory → wiki)

- [ ] `promote-{nnn}`
  ```yaml
  type: promote
  source_path: {absolute path}
  source_expect_sha256: {sha256 of source content}
  target_page: {absolute wiki path}
  target_action: {append_section | insert_after_heading | create_new}
  target_heading: {e.g. "## Bar" — only if insert_after_heading}
  target_expect: |
    {verbatim snippet at insertion point — omit for create_new}
  body: |
    {verbatim content to insert, frontmatter-ready if target_action=create_new}
  index_entry: {one-line addition to wiki/index.md, or null}
  log_entry: {one-line to prepend to wiki/log.md}
  delete_source_after: true
  ```

### Shrink / Convert (replace inline content with a wikilink)

- [ ] `shrink-{nnn}`
  ```yaml
  type: replace
  path: {absolute path}
  before: |
    {verbatim current block — must match byte-for-byte}
  after: |
    {verbatim replacement, typically a wikilink line}
  reason: {…}
  ```

### Merge (intra-wiki consolidation)

- [ ] `merge-{nnn}`
  ```yaml
  type: merge
  canonical: {absolute wiki path}
  canonical_expect_sha256: {sha256}
  sources:
    - path: {absolute wiki path}
      expect_sha256: {sha256}
      append_as: |
        {verbatim content to add to canonical}
      redirect_body: |
        ---
        type: redirect
        ---
        → see [[Canonical Name]]
  index_updates:
    - {line to change in wiki/index.md}
  log_entry: {one-line to prepend to wiki/log.md}
  ```

### Fix-link

- [ ] `fixlink-{nnn}`
  ```yaml
  type: replace
  path: {absolute path}
  before: |
    {verbatim line containing the broken link}
  after: |
    {verbatim corrected line, or empty string to delete the line}
  reason: {broken target, correct target}
  ```

## Ordering

Stage 2 must apply actions in this order: `fix-link` → `shrink` → `delete-entry` → `merge` → `promote` → `delete`. Rationale: shrinks never reference content that later gets merged; deletes come last so earlier pointers don't go stale.

## To apply

Run `/gaia audit --apply` within 24h.

```

End the research run by printing: report path, total actions per category, and the apply command.

## Step 7 — Apply procedure (Stage 2, Sonnet)

You are executing, not reasoning. Follow this loop exactly.

### Pre-flight

1. Find the newest `$PROJECT_ROOT/.claude/audit/KNOWLEDGE-*.md`. If none, or mtime >24h, stop and print `no fresh report — run /gaia audit first`.
2. Parse the report's frontmatter. Verify `project_root`, `memory_dir`, and `agent_memory_dir` match the values you resolved at startup. If any differ, stop and print a clear error — the report was generated on a different machine or in a different clone.
3. Run `git rev-parse HEAD` — if it differs from `git_head` in the report, print a warning but continue. Run `git status --short` — any file that is currently dirty AND appears as a target in the report is marked `SKIP (dirty)` before any action runs.
4. Read the `## Ordering` section. Process actions in that order.

### Per-action loop

For each unchecked action block:

1. Verify drift signal:
   - If the action specifies `expect_sha256`: compute sha256 of the target file. If mismatch → mark `[~]` skipped, record reason `sha drift`, move on.
   - If the action specifies `before:` or `expect:` snippet: read the file and confirm the snippet appears verbatim. If missing → `[~]` skipped, `snippet drift`.
2. Apply the change using the exact operation:
   - `type: delete` → remove the file
   - `type: delete-entry` → read file, locate the `expect` block, remove it, write back
   - `type: promote` → perform the `target_action` (use Edit or Write as appropriate), then prepend `log_entry` to `wiki/log.md`, then append `index_entry` to the right section of `wiki/index.md`, then delete `source_path` if `delete_source_after: true`
   - `type: replace` → Edit with `old_string: before`, `new_string: after`. If `before` is not unique, prepend additional context from the file until unique.
   - `type: merge` → for each source: append `append_as` into canonical at its tail (or an explicit position if the action specifies one), then overwrite the source with `redirect_body`. Then prepend `log_entry` to `wiki/log.md`. Apply `index_updates` to `wiki/index.md`.
3. Flip the checkbox: `[ ]` → `[x]` on success, `[~]` on skip, `[!]` on error. Record the reason inline on the checkbox line.

### Post-flight

Print a final summary to stdout:

```

audit apply: {done}/{total} applied · {skipped} skipped · {failed} failed
diff footprint:
{git status --short}
next: review diff, commit if satisfied

```

## Guardrails

- Never delete a memory entry unless the action's `reason` cites a canonical wiki location. (Stage 1 must supply this; Stage 2 doesn't judge.)
- Never edit `wiki/log.md` anywhere except prepending a new line at the top.
- Never `git add` or `git commit` — leave changes in working tree for the human to review.
- Never improvise: if drift-check fails, skip and report. Do not search for the "right" target.
- Never merge two actions: each block is atomic.
- If an action targets a path that doesn't exist, mark `[!]` with `target missing` and continue.
```
