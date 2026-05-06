---
name: wiki-sync
description: Evaluate commits since last sync and update the wiki where warranted. Two-pass: subjects first, deep-read only the worthy ones. Updates wiki/.state.json on completion.
---

## Execution model — READ FIRST

**Do not execute the playbook yourself in the current conversation.** Dispatch a Sonnet subagent via the `Agent` tool. The work is mechanical (rule-based WORTHY/SKIP classification, file edits, structured commits) — Sonnet is sufficient, and a fresh context avoids dragging git diffs and log content into the parent. This protects the user even if they're on Opus or forgot to `/clear` before invoking.

Spawn:

- `subagent_type`: `"general-purpose"`
- `model`: `"sonnet"`
- `description`: `"Wiki sync"`
- `prompt`: the string below (literal, no paraphrasing):

  > `You are running the GAIA /wiki-sync workflow in a fresh context. Read .claude/commands/wiki-sync.md from the project root and execute the "Playbook" section (Steps 1–9) verbatim. Your working directory is the project root. Print only the final summary block from Step 8 followed by the CONSOLIDATE_TRIGGERED line from Step 9 — no preamble, no recap, no narration of intermediate steps.`

When the subagent returns, relay its final summary verbatim. Do not redo the work in the parent.

**Consolidation gate.** The summary's last line is `CONSOLIDATE_TRIGGERED: <true|false>` (Step 9 emits it). If `true`, immediately invoke `/wiki-consolidate` after relaying the summary — the gate determined per-domain page-add accumulation has crossed the threshold and consolidation is warranted. If `false`, do nothing further. Never run consolidate yourself in this conversation; `/wiki-consolidate` dispatches its own subagent.

---

## Playbook

Evaluate every commit between `wiki/.state.json` `last_evaluated_sha` and HEAD. For each, decide whether the wiki needs an update. Edit pages, log decisions, advance state, commit.

`wiki/.state.json` is written by two commands: this command writes the sync-related fields (`last_evaluated_sha`, `last_evaluated_at`); `/wiki-consolidate` writes the consolidate-related field (`last_consolidated_sha`). Each must preserve fields owned by the other when writing. The hooks (`wiki-drift-check`, `wiki-commit-nudge`, `wiki-stop-safety-net`) are read-only consumers.

## Step 1: Read state and compute drift

Read `wiki/.state.json`. If it doesn't exist:

- This is a fresh project (no prior sync). Treat the first commit as the baseline. Initialize state to the first commit SHA, write the file, commit it as `wiki: initialize state at {short_sha}`. Stop — no commits to evaluate yet.

If state exists:

- Get `last_evaluated_sha` and run:
  ```bash
  git rev-list --count <sha>..HEAD
  ```
- If 0: skip the evaluation pass (no commits to evaluate) but DO NOT exit yet — fall through to Step 9 (consolidate gate). The gate may still trigger consolidate based on accumulated page-adds since last consolidate run, even when this sync is a no-op. The Step 8 report still prints; just substitute `Wiki already in sync at {short_sha}.` for the regular summary block, then run Step 9.
- If `<sha>` is unreachable from HEAD (rebase scenario): re-anchor — set `last_evaluated_sha` to HEAD, write a `wiki/log.md` entry `{date} - {short_sha} - re-anchored after history rewrite`, commit, exit. Skip Step 9 — re-anchor wipes drift baseline; running consolidate against an unreachable past makes no sense.
- Otherwise proceed with the evaluation pass.

## Step 2: Drift cap check

If drift > 30 commits, ASK the user via `AskUserQuestion`:

- Question: `Wiki is {N} commits behind HEAD. Syncing all may cost ~${estimated} in tokens. Proceed?`
- Options:
  - `Sync all {N} commits` (description: full evaluation)
  - `Sync recent N commits only` (description: evaluate the last 20 commits, re-anchor state)
  - `Cancel` (description: do nothing)

Only proceed automatically when drift ≤ 30.

## Step 3: First-pass — read subjects + stats

Run:

```bash
git log <state_sha>..HEAD --no-merges --reverse --format='COMMIT %H%n%s%n%b%n---END-COMMIT---' --stat
```

Note `--reverse` so commits are processed oldest-first. Each commit gets:

- Full SHA
- Subject
- Body (may be empty)
- File stat block

Build a working list. For each commit:

Decide WORTHY / SKIP based on subject + stats alone, without reading diffs. Worthy if any of:

- Subject prefixed `docs(decision):`, `feat!:`, `chore(adr):`, or `BREAKING CHANGE` in body
- Body explicitly mentions a trade-off, invariant, gotcha, workaround, or non-obvious decision
- Touches `wiki/decisions/`, `wiki/concepts/`, `wiki/flows/`, `wiki/dependencies/`, or `wiki/entities/` directly
- Touches `app/middleware/**`, `app/routes.ts`, `app/i18n.ts`, or `app/sessions.server/**` (flows-relevant)
- Adds or removes a dependency in `package.json`, or swaps one dependency for another (e.g. `axios` → `ofetch`). The dep wiki layer owns "why we use this" — adding, removing, or swapping a dep changes the why. A version bump does **not** change the why and is SKIP regardless of subject prefix.
- Subject prefixed `feat:` AND the diff introduces a new pattern not previously expressed in the codebase (e.g. first state Provider, first server-only utility) — judgment call, log the reasoning

Skip if any of:

- `chore(release):`, `wiki:`, `Merge pull request`, or `style:` prefixes (existing)
- `chore(deps):` prefix when the diff is a version bump only — no dep added, removed, or swapped. If a `chore(deps):` commit actually adds or removes a dep, the dep WORTHY rule above wins.
- Touches only `app/components/**`, `app/hooks/**`, `app/services/**`, or `app/pages/**` AND adds/refactors files without a body mentioning trade-offs / decisions / invariants — Serena handles the inventory; log as `SKIP: Serena handles inventory — {context}`
- Pure formatting / typo / comment-only changes
- Test-only changes (no `app/**` non-test files in the diff)

If unsure: mark WORTHY (false positive better than false negative). Log the decision.

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

For each commit (worthy or skipped), prepend ONE line to `wiki/log.md` in this format:

```
- {YYYY-MM-DD} {short_sha} - {decision}: {one-line reason}
```

- WORTHY example: `2026-05-03 abc1234 - WORTHY: added /services/Gemini integration → wiki/services/Gemini.md`
- SKIP example: `2026-05-03 def5678 - SKIP: typo-only commit`
- Serena-policy SKIP example: `2026-05-03 9a0b1c2 - SKIP: Serena handles inventory — added Button variant in app/components/Button`

Newest entries on top. Group by date if helpful.

## Step 6: Advance state file

Update `wiki/.state.json`. Read the existing file first to preserve `last_consolidated_sha` (owned by `/wiki-consolidate`). On the first write that ever sees a missing `last_consolidated_sha`, bootstrap it to the new HEAD value — this gives the consolidate gate a baseline so subsequent runs accumulate from a known point.

```json
{
  "version": 1,
  "last_evaluated_sha": "<new HEAD SHA, full 40-char>",
  "last_evaluated_at": "<now, ISO 8601 UTC>",
  "last_consolidated_sha": "<preserved if present; bootstrapped to last_evaluated_sha if absent>"
}
```

## Step 7: Commit (branch-aware)

Stage:

- All edited / created `wiki/**` files
- `wiki/log.md`
- `wiki/.state.json`

Then check the current branch and pick the landing strategy:

```bash
current_branch=$(git rev-parse --abbrev-ref HEAD)
```

### Case A — on `main` (or `master`)

`main` is push-protected, so commit-in-place would dead-end. Branch first, commit, push, open PR, merge, return to `main`:

```bash
sync_branch="wiki/sync-$(date +%F)"
git checkout -b "$sync_branch"
git add wiki/
git commit -m "wiki: sync through {short_sha} ({N_worthy} updated, {N_skipped} skipped)"
git push -u origin "$sync_branch"
gh pr create --title "wiki: sync through {short_sha} ({N_worthy} updated, {N_skipped} skipped)" \
  --body "<short summary of WORTHY/SKIP decisions>"
gh pr merge --squash --delete-branch  # release branches have no required checks; sync PRs typically pass quickly
git checkout main
git pull --ff-only
```

If the branch name collides (a previous incomplete sync), append `-2`, `-3`, etc. — never delete the existing branch silently.

### Case B — on any other branch (feature, fix, release, worktree)

The maintainer is mid-task on a non-protected branch. Commit in place — branching would fragment their working state across PRs they didn't ask for:

```bash
git add wiki/
git commit -m "wiki: sync through {short_sha} ({N_worthy} updated, {N_skipped} skipped)"
```

This applies to git worktrees too: a worktree is by definition not on `main`, so commit on the worktree's branch directly.

This commit is intentionally NOT prefixed `wiki: auto-commit` — it's a deliberate sync, not an auto-commit. The squash-autocommits hook will not fold it. Different audit trail.

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
