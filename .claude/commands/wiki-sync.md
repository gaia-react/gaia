---
name: wiki-sync
description: Evaluate commits since last sync and update the wiki where warranted. Two-pass: subjects first, deep-read only the worthy ones. Updates wiki/.state.json on completion.
---

## Execution model — READ FIRST

**Do not execute the playbook yourself in the current conversation.** Dispatch a Haiku subagent via the `Agent` tool. The work is mechanical (rule-based WORTHY/SKIP classification, file edits, structured commits) — Haiku is sufficient, and a fresh context avoids dragging git diffs and log content into the parent. This protects the user even if they're on Opus or forgot to `/clear` before invoking.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"haiku"`
- `description`: `"Wiki sync"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are running the GAIA /wiki-sync workflow in a fresh context. Read .claude/commands/wiki-sync.md from the project root and execute the "Playbook" section (Steps 1–9) verbatim. Your working directory is the project root. Print only the final summary block from Step 8 followed by the CONSOLIDATE_TRIGGERED line from Step 9 — no preamble, no recap, no narration of intermediate steps.`

When the subagent returns, relay its final summary verbatim. Do not redo the work in the parent.

**Post-sync chain.** Step 9 emits `CONSOLIDATE_TRIGGERED: <true|false>` as the summary's last line on normal sync paths (including drift=0). The line is **absent** on the re-anchor path (Step 1 rebase recovery) and on partial-sync interruptions (Step 7 failure mode) — both leave the wiki in a known-incomplete state. Branch on its presence:

- **Line absent** — skip both `/wiki-consolidate` and `/wiki-lint`. The maintainer needs to address the exceptional state first.
- **`CONSOLIDATE_TRIGGERED: true`** — invoke `/wiki-consolidate`, then `/wiki-lint`.
- **`CONSOLIDATE_TRIGGERED: false`** — skip consolidate, invoke `/wiki-lint` directly.

Lint runs last because consolidate may move, rename, or archive pages, and lint's orphan/dead-link/drift checks need the true post-state. `/wiki-consolidate` and `/wiki-lint` each dispatch their own subagents — never run their playbooks yourself in this conversation.

---

## Playbook

Evaluate every commit between `wiki/.state.json` `last_evaluated_sha` and HEAD. For each, decide whether the wiki needs an update. Edit pages, log decisions, advance state, commit.

`wiki/.state.json` is written by two commands: this command writes the sync-related fields (`last_evaluated_sha`, `last_evaluated_at`); `/wiki-consolidate` writes the consolidate-related field (`last_consolidated_sha`). Each must preserve fields owned by the other when writing. The hooks (`wiki-drift-check`, `wiki-commit-nudge`, `wiki-session-stop`) are read-only consumers.

## Step 1: Read state and compute drift

Run `gaia wiki state --json` and parse the result. Use `head_short`, `state_sha`, `commits_ahead`, and `reachable` directly.

- If the command exits non-zero with a `state_missing` (or equivalent) reason, this is a fresh project (no prior sync). Treat the first commit as the baseline. Run `gaia wiki state-init "$(git rev-list --max-parents=0 HEAD | tail -1)"` to create `wiki/.state.json` with `{version, last_evaluated_sha, last_evaluated_at}`, then commit as `wiki: initialize state at {short_sha}`. Stop — no commits to evaluate yet.
- If `commits_ahead === 0`: skip the evaluation pass (no commits to evaluate) but DO NOT exit yet — fall through to Step 9 (consolidate gate). The gate may still trigger consolidate based on accumulated page-adds since last consolidate run, even when this sync is a no-op. The Step 8 report still prints; just substitute `Wiki already in sync at {short_sha}.` for the regular summary block, then run Step 9.
- If `reachable === false`: the recorded SHA is not in HEAD's history (rebase scenario). Re-anchor — run `gaia wiki state-bump last_evaluated_sha "$(git rev-parse HEAD)"`, then `gaia wiki log-prepend --sha "$(git rev-parse --short HEAD)" --decision RE_ANCHOR --reason "re-anchored after history rewrite"`, commit, exit. Skip Step 9 — re-anchor wipes drift baseline; running consolidate against an unreachable past makes no sense.
- Otherwise proceed with the evaluation pass.

## Step 2: Drift cap check

If drift > 30 commits, ASK the user via `AskUserQuestion`:

- Question: `Wiki is {N} commits behind HEAD. Syncing all may cost ~${estimated} in tokens. Proceed?`
- Options:
  - `Sync all {N} commits` (description: full evaluation)
  - `Sync recent N commits only` (description: evaluate the last 20 commits, re-anchor state)
  - `Cancel` (description: do nothing)

Only proceed automatically when drift ≤ 30.

## Step 3: First-pass — classify commits

Run:

```bash
gaia wiki commit-classify --since $(jq -r .last_evaluated_sha wiki/.state.json) --json
```

The CLI emits a deterministic `suggestion` field per commit (`WORTHY` or `SKIP`) along with `subject`, `body`, file stats, and `suggestion_reason`. Treat the `WORTHY` subset as candidates for deep-read. Trust the CLI's classification — do not re-derive WORTHY/SKIP rules in prose. Log the `suggestion_reason` verbatim alongside the decision in Step 5.

## Step 4: Second-pass — read diffs for WORTHY commits only

For each WORTHY commit:

```bash
git show <sha>
```

Read the diff. Decide what wiki page(s) need updating:

- New service in `app/services/`: edit or create `wiki/services/<name>.md`
- New hook in `app/hooks/`: edit or create `wiki/hooks/<name>.md`
- New route group: edit `wiki/flows/Routes.md`
- Dependency change: edit `wiki/dependencies/<name>.md` (create if needed)
- Architectural pattern: edit relevant `wiki/concepts/<topic>.md`
- ADR-worthy: create new `wiki/decisions/<title>.md` with frontmatter:
  ```
  ---
  type: decision
  status: active
  priority: 1
  date: <commit date, YYYY-MM-DD>
  created: <commit date, YYYY-MM-DD>
  updated: <today, YYYY-MM-DD>
  tags: [decision, ...]
  ---
  ```

Match the existing wiki voice: declarative, no preamble, concrete examples where useful. Don't paraphrase the commit message — extract the load-bearing facts and integrate them into the page's narrative.

If a commit's diff turns out NOT to be wiki-worthy on closer inspection (e.g. subject suggested feature but it was a refactor), demote to SKIP and proceed.

## Step 5: Append to wiki/log.md

For each commit (worthy or skipped), run:

```bash
gaia wiki log-prepend --sha <short_sha> --decision <WORTHY|SKIP> --reason "<one-line reason>"
```

The CLI inserts a single canonical line `- <YYYY-MM-DD> <sha> <decision> — <reason>` at the top of `wiki/log.md` (after frontmatter), atomically, newest entries on top. Examples:

- WORTHY: `gaia wiki log-prepend --sha abc1234 --decision WORTHY --reason "added /services/Gemini integration → wiki/services/Gemini.md"`
- SKIP: `gaia wiki log-prepend --sha def5678 --decision SKIP --reason "typo-only commit"`
- Serena-policy SKIP: `gaia wiki log-prepend --sha 9a0b1c2 --decision SKIP --reason "Serena handles inventory — added Button variant in app/components/Button"`

## Step 6: Advance state file

Run:

```bash
NEW_HEAD=$(git rev-parse HEAD)
NEW_HEAD_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
gaia wiki state-bump last_evaluated_sha "$NEW_HEAD"
gaia wiki state-bump last_evaluated_at "$NEW_HEAD_AT"
```

`state-bump` writes atomically — preserving sibling fields (`last_consolidated_sha` owned by `/wiki-consolidate`) and key order.

If `last_consolidated_sha` is absent on the existing state (first sync ever): bootstrap it with `gaia wiki state-bump last_consolidated_sha "$NEW_HEAD"`. This gives the consolidate gate a baseline so subsequent runs accumulate from a known point.

## Step 7 — Land

Run: `gaia wiki sync land --branch-aware`

Exit codes:
- 0 — landed (CLI summary line shows how)
- 1 — refused (CLI stderr explains why; surface to user verbatim)
- 2 — unexpected (surface to user; do NOT retry)

Do NOT inline branch logic, manual `gh pr` calls, or any push narrative. The CLI is authoritative.

## Step 8: Report

Print a brief summary:

```
Wiki sync complete.

  Range:    {state_sha}..{head_sha}
  Total:    {N} commits
  Worthy:   {N_worthy}
  Skipped:  {N_skipped}
  Pages edited: {list}
  ADRs created: {list, if any}
  State advanced to {head_sha}.
```

(On the no-op path from Step 1's drift=0 branch: print `Wiki already in sync at {short_sha}.` instead of the block above.)

After the summary block, append the Step 9 result line `CONSOLIDATE_TRIGGERED: <true|false>` on its own line (no leading whitespace). The wrapper reads this to decide whether to invoke `/wiki-consolidate`.

## Step 9: Consolidate gate

Cheap precheck. Decides whether `/wiki-consolidate` should fire next based on per-domain new-page accumulation since the last consolidate run.

### 9a. Read state

```bash
CONSOLIDATED_SHA=$(jq -r '.last_consolidated_sha // empty' wiki/.state.json)
HEAD_SHA=$(git rev-parse HEAD)
```

If `CONSOLIDATED_SHA` is empty (the bootstrap case from Step 6 wasn't reached because Step 6 was skipped on the drift=0 path AND no prior sync ever wrote the field): emit `CONSOLIDATE_TRIGGERED: false` and exit. Step 6 will bootstrap the field on the next non-zero-drift sync. Do not bootstrap from inside Step 9 — keep this step read-only on the state file.

### 9b. Count added pages per domain

```bash
git diff --name-only --diff-filter=A "$CONSOLIDATED_SHA"..HEAD -- \
  wiki/decisions/ wiki/concepts/ wiki/modules/ wiki/flows/ wiki/components/ wiki/dependencies/
```

Group the output by parent directory (the domain). Count pages per domain. Skip files in `wiki/_archived/` (handled by the path filter — `_archived/` is not in the list).

### 9c. Threshold check

If any single domain has ≥ 2 added pages since `CONSOLIDATED_SHA`: emit `CONSOLIDATE_TRIGGERED: true`. Otherwise: emit `CONSOLIDATE_TRIGGERED: false`.

The threshold rationale: cross-page redundancy emerges when multiple SPECs land in the same domain. One SPEC promoting to one domain has nothing to consolidate against. Two SPECs in the same domain is the minimum case where supersession or near-collision can occur.

### 9d. Append to summary

Add the trigger line to the report from Step 8. Example final summary on a triggered sync:

```
Wiki sync complete.

  Range:    abc123..def456
  Total:    5 commits
  Worthy:   3
  Skipped:  2
  Pages edited: wiki/decisions/auth-strategy.md, wiki/modules/Sessions.md
  ADRs created: wiki/decisions/auth-strategy.md
  State advanced to def456.

CONSOLIDATE_TRIGGERED: true
```

The wrapper reads the last line and decides whether to invoke `/wiki-consolidate`. The gate itself never invokes consolidate directly — it stays a read-only check.

### 9e. Edge cases

- **Drift=0 sync (no commits since last sync).** Gate still runs. The page-add count is computed against `last_consolidated_sha`, not against the sync's evaluation range, so accumulated adds from earlier syncs may still meet threshold.
- **Re-anchor (rebase).** Step 1 exits before Step 9. After re-anchor, the next sync's Step 6 will preserve any existing `last_consolidated_sha`; the gate resumes counting from there. If the anchor change put `last_consolidated_sha` upstream of HEAD by an unreachable path, the next gate's `git diff` returns empty → `false`. Acceptable; the maintainer can run consolidate manually.
- **Consolidate's own commits in the diff.** If a previous consolidate run produced commits that landed (retirements moving pages to `wiki/_archived/`, near-collision renames inside an active domain), those appear in the next gate's diff. `_archived/` is excluded by path. Renames inside an active domain show as added paths and may trigger a redundant consolidate fire. Living with that — the false positive is cheap (consolidate runs, finds nothing new, advances state, returns).

## Failure modes

- **Mid-sync interruption.** If you've edited some pages but not all, do NOT advance state. Commit only the partial wiki edits with subject `wiki: partial sync (interrupted at {short_sha})` and stop. The next sync resumes from the original `last_evaluated_sha`, not the partial one.
- **Merge conflict on `wiki/log.md`.** Two `/wiki-sync` runs on different branches will both prepend to the log. Resolve by keeping both lines, sorted newest-first.
- **`wiki/.state.json` is corrupted or invalid JSON.** Stop and surface to the user. Do not auto-rewrite — they may have made manual edits worth preserving.
