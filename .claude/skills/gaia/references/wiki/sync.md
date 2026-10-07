# wiki-sync playbook

Dispatched by the `/gaia-wiki` router (`references/wiki.md` → "Sync"). Runs in a Sonnet subagent context.

## Playbook

Evaluate every commit between `wiki/.state.json` `last_evaluated_sha` and HEAD. For each, decide whether the wiki needs an update. Edit pages, log decisions, advance state, commit.

`wiki/.state.json` is written by two workflows: this one writes the sync-related fields (`last_evaluated_sha`, `last_evaluated_at`); the consolidate stage writes the consolidate-related field (`last_consolidated_sha`). Each must preserve fields owned by the other when writing. Everything else that reads it, the statusline nudge included, is a read-only consumer.

## Step 1: Read state and compute drift

Run `.gaia/cli/gaia wiki state --json` and parse the result. Use `head_short`, `state_sha`, `commits_ahead`, `drift_count`, `reachable`, and `suggested_base` directly.

Throughout this playbook, **the evaluation baseline** is the ref Steps 2, 3, and 8 evaluate from. On the normal path it is `last_evaluated_sha`; on the recovery path (below) it is `suggested_base`. Each branch states which.

- If the command exits non-zero with a `state_missing` (or equivalent) reason, this is a fresh project (no prior sync). Treat the first commit as the baseline. Run `.gaia/cli/gaia wiki state-init "$(git rev-list --max-parents=0 HEAD | tail -1)"` to create `wiki/.state.json` with `{version, last_evaluated_sha, last_evaluated_at}`, then commit with `.gaia/cli/gaia wiki chain commit --label "wiki: sync through <short-head>"` (`<short-head>` from `git rev-parse --short HEAD`). Stop, no commits to evaluate yet, and emit no `SYNC_COMPLETE: true` line.
- If `commits_ahead === 0`: skip the evaluation pass (no commits to evaluate), print `Wiki already in sync at {short_sha}.` and then, on its own line, `SYNC_COMPLETE: true`.
- If `reachable === false`: the recorded `last_evaluated_sha` is not in HEAD's history. GAIA's squash-merge flow orphans it on **every** merge, the evaluated branch SHA is replaced by a new squash commit on `main`, so this is the common case, not just a manual rebase. Recover the un-evaluated window instead of discarding it:
  - **Recovery path, when `suggested_base` is non-empty.** The CLI resolved `suggested_base` to the newest commit on HEAD's **first-parent chain** at or older than `last_evaluated_at`. That can sit before where the orphaned SHA left off, so expect some already-catalogued commits in the window; Step 5's dedup guard skips them. Adopt `suggested_base` as the evaluation baseline and run the normal pass (Steps 2–8) from it, ending with `SYNC_COMPLETE: true`. Do NOT jump to HEAD and do NOT log a `RE_ANCHOR` line, the window is evaluated, not abandoned. Step 6 advances `last_evaluated_sha` to HEAD as usual.
  - **Fallback path, when `suggested_base` is empty.** Only when the CLI cannot resolve a baseline (no `last_evaluated_at`, or it predates all history) revert to the lossy-but-safe re-anchor: run `.gaia/cli/gaia wiki state-bump last_evaluated_sha "$(git rev-parse HEAD)"`, then `.gaia/cli/gaia wiki log-prepend --sha "$(git rev-parse --short HEAD)" --decision RE_ANCHOR --reason "re-anchored after history rewrite (no recoverable baseline)"`, commit with `.gaia/cli/gaia wiki chain commit --label "wiki: sync through <short-head>"`, and exit. Emit no `SYNC_COMPLETE: true` line, there is no recovered range to evaluate.
- Otherwise proceed with the evaluation pass on the normal baseline (`last_evaluated_sha`).

## Step 2: Drift cap check

If drift > 30 commits, ASK the user via `AskUserQuestion`:

- Question: `Wiki is {N} commits behind HEAD. Syncing all may cost ~${estimated} in tokens. Proceed?`
- Options:
  - `Sync all {N} commits` (description: full evaluation)
  - `Sync recent N commits only` (description: evaluate the last 20 commits, re-anchor state)
  - `Cancel` (description: do nothing)

`Cancel` is an abort: do nothing and emit no `SYNC_COMPLETE: true` line.

Only proceed automatically when drift ≤ 30.

The drift count is `drift_count`, on the normal path and on the recovery path alike. The CLI already counts from the right base (the recorded SHA when reachable, else `suggested_base`) and leaves out the wiki bookkeeping commits, so do not recompute it with `git rev-list`. Apply the cap to `drift_count`. A batch that landed since the last sync (worst case, a whole release) shows up here and is capped exactly like normal drift.

## Step 3: First-pass, classify commits

Run, using the evaluation baseline from Step 1 (normal path: `last_evaluated_sha`; recovery path: `suggested_base`):

```bash
# Normal path: BASE=$(jq -r .last_evaluated_sha wiki/.state.json)
# Recovery path: BASE=<suggested_base from `.gaia/cli/gaia wiki state --json`>
.gaia/cli/gaia wiki commit-classify --since "$BASE" --json
```

On the recovery path, classify from `suggested_base`, NOT the orphaned `last_evaluated_sha`. The orphaned SHA's `..HEAD` range is topologically unreliable after a squash; `suggested_base` is reachable and time-anchored.

The CLI emits a deterministic `suggestion` field per commit (`WORTHY` or `SKIP`) along with `subject`, `body`, file stats, and `suggestion_reason`. Treat the `WORTHY` subset as candidates for deep-read. Trust the CLI's classification, do not re-derive WORTHY/SKIP rules in prose. Log the `suggestion_reason` verbatim alongside the decision in Step 5.

## Step 4: Second-pass, read diffs for WORTHY commits only

For each WORTHY commit:

```bash
git show <sha>
```

Read the diff. Decide what wiki page(s) need updating:

- New service in `frontend/app/services/`: edit or create `wiki/services/<name>.md`
- New hook in `frontend/app/hooks/`: edit or create `wiki/hooks/<name>.md`
- New route group: edit `wiki/decisions/Thin Routes.md` and/or `wiki/modules/Pages.md`
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

  Derive `<today>` from `date +%F` (shell), never guess the current date. Take the `date`/`created` commit-date values from the commit itself: `git show -s --format=%cs <sha>`.

Match the existing wiki voice: declarative, no preamble, concrete examples where useful. Don't paraphrase the commit message, extract the load-bearing facts and integrate them into the page's narrative.

**Follow `.claude/rules/wiki-style.md` when writing or editing prose.** Present tense only. Never reference UAT-NNN, SPEC-NNN, PR numbers, commit SHAs, or "changed from X to Y on date" inside body prose. The historical record lives in `wiki/log.md` (which Step 5 maintains) and in git, not in pages.

If a commit's diff turns out NOT to be wiki-worthy on closer inspection (e.g. subject suggested feature but it was a refactor), demote to SKIP and proceed.

## Step 5: Append to wiki/log.md

For each commit (worthy or skipped), first dedup against the existing ledger, then run:

```bash
# Skip commits a prior sync already catalogued, avoids double-logging.
# Grep the working-tree log so lines this sync already prepended count too.
grep -qF "<short_sha>" wiki/log.md && continue
.gaia/cli/gaia wiki log-prepend --sha <short_sha> --decision <WORTHY|SKIP> --reason "<one-line reason>"
```

The dedup guard matters most on the recovery path (Step 1), where the resolved `suggested_base` can sit behind commits a prior sync already logged. Skip any commit whose short SHA is already in `wiki/log.md` rather than appending a duplicate line.

The CLI inserts a single canonical line `- <YYYY-MM-DD> <sha> <decision>, <reason>` at the top of `wiki/log.md` (after frontmatter), atomically, newest entries on top. Examples:

- WORTHY: `.gaia/cli/gaia wiki log-prepend --sha abc1234 --decision WORTHY --reason "added /services/Gemini integration → wiki/services/Gemini.md"`
- SKIP: `.gaia/cli/gaia wiki log-prepend --sha def5678 --decision SKIP --reason "typo-only commit"`
- Serena-policy SKIP: `.gaia/cli/gaia wiki log-prepend --sha 9a0b1c2 --decision SKIP --reason "Serena handles inventory, added Button variant in frontend/app/components/button"`

## Step 5b: Fabrication guard, verify edits landed on disk

Before advancing state or committing, prove the Step 4 decisions actually wrote to disk. This is the fabrication guard: a run that logged WORTHY decisions in Step 5 and is about to advance state (Step 6) and commit (Step 7) MUST have produced the corresponding page edits. Without this check a model can satisfy the workflow's success signal (summary + log + state) while writing no content, and Step 7 launders that empty sync into a green commit.

`CLAIMED` is the set of page paths Step 4 decided to edit or create for WORTHY commits, the same paths the Step 8 "Pages edited" / "ADRs created" lists report.

Check each claimed path individually (wiki filenames contain spaces, so do NOT field-split a combined listing):

```bash
# 1. No-empty-WORTHY check: WORTHY commits must produce at least one content change.
CONTENT_CHANGES=$(git status --porcelain -- wiki/ \
  ':(exclude)wiki/.state.json' ':(exclude)wiki/log.md' \
  ':(exclude)wiki/hot.md' ':(exclude)wiki/meta/')

# 2. Per-claim check: every CLAIMED path must show as changed/created.
#    git status --porcelain -- "<path>" is empty when the path is unmodified.
for p in "${CLAIMED[@]}"; do
  [ -z "$(git status --porcelain -- "$p")" ] && echo "MISSING: $p"
done
```

ABORT on either failure, do NOT run Step 6, do NOT run Step 7, leave the working tree untouched, and print the failure block below **instead of** the Step 8 summary, then stop:

1. **No empty WORTHY sync.** `N_worthy >= 1` but `CONTENT_CHANGES` is empty ⇒ edits were decided but none written. Abort.
2. **Every claimed page exists in the diff.** Any `MISSING:` line from the loop ⇒ that edit was narrated, not written. Abort, naming the missing pages.

The all-SKIP case is legitimate: `N_worthy == 0` with empty `CONTENT_CHANGES` and an empty `CLAIMED` passes both checks, proceed to Step 6 normally.

Failure block:

```
Wiki sync ABORTED, fabrication guard tripped.

  Worthy commits:   {N_worthy}
  Pages claimed:    {CLAIMED}
  Pages on disk:    {changed wiki content paths}
  Missing:          {CLAIMED minus on-disk}

State not advanced. Nothing committed. Re-run sync; if this recurs, the dispatched
model is narrating edits without performing them, escalate the model.
```

The abort emits no `SYNC_COMPLETE: true` line, and the router (`references/wiki.md` → "Full chain") treats the absent line as a known-incomplete state and skips consolidate and lint, so an abort fails the whole chain safely without further wiring.

## Step 6: Advance state file

Run:

```bash
NEW_HEAD=$(git rev-parse HEAD)
NEW_HEAD_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
.gaia/cli/gaia wiki state-bump last_evaluated_sha "$NEW_HEAD"
.gaia/cli/gaia wiki state-bump last_evaluated_at "$NEW_HEAD_AT"
```

`state-bump` writes atomically, preserving sibling fields (`last_consolidated_sha`, which the consolidate stage owns) and key order.

If `last_consolidated_sha` is absent on the existing state (first sync ever): bootstrap it with `.gaia/cli/gaia wiki state-bump last_consolidated_sha "$NEW_HEAD"`. This seeds `last_consolidated_sha` on the first sync so the field always holds a commit.

## Step 7: Commit

Run: `.gaia/cli/gaia wiki chain commit --label "wiki: sync through <short-head>"`, with `<short-head>` from `git rev-parse --short HEAD` taken before the commit. The label matches the drift excluder, so the commit never counts as drift.

Exit codes:

- 0, committed, or nothing to commit
- 1, refused (non-wiki changes, or a protected branch because `chain begin` did not cut one): surface stderr verbatim and stop, with no `SYNC_COMPLETE: true` line
- 2, unexpected: surface it, do NOT retry, and emit no `SYNC_COMPLETE: true` line

Do NOT inline branch logic, manual `gh pr` calls, or any push narrative. The CLI is authoritative.

## Step 8: Report

Print a brief summary:

```
Wiki sync complete.

  Range:    {baseline}..{head_sha}
  Total:    {N} commits
  Worthy:   {N_worthy}
  Skipped:  {N_skipped}
  Pages edited: {list}
  ADRs created: {list, if any}
  State advanced to {head_sha}.
```

`{baseline}` is `state_sha` on the normal path and `suggested_base` on the recovery path, the ref the range was actually evaluated from.

(On the no-op path from Step 1's drift=0 branch: print `Wiki already in sync at {short_sha}.` instead of the block above.)

After the summary block, print `SYNC_COMPLETE: true` on its own line (no leading whitespace). The router (`references/wiki.md` → "Full chain") reads this line to decide whether consolidate and lint run next. Example final summary:

```
Wiki sync complete.

  Range:    abc123..def456
  Total:    5 commits
  Worthy:   3
  Skipped:  2
  Pages edited: wiki/decisions/auth-strategy.md, wiki/modules/Sessions.md
  ADRs created: wiki/decisions/auth-strategy.md
  State advanced to def456.

SYNC_COMPLETE: true
```

The line is omitted on the state-init path, the fallback re-anchor path (`suggested_base` empty), the Step 2 `Cancel` answer, a non-zero `chain commit` in Step 7, and every entry under Failure modes.

## Failure modes

- **Mid-sync interruption.** If you've edited some pages but not all, do NOT advance state. Commit only the partial wiki edits through `.gaia/cli/gaia wiki chain commit --label "wiki: sync through <short-head>"` and stop, emitting no `SYNC_COMPLETE: true` line. The next sync resumes from the original `last_evaluated_sha`, not the partial one.
- **Fabrication guard abort (Step 5b).** WORTHY commits were classified but the decided edits are absent from the working tree. State is not advanced and nothing is committed, so the next sync re-evaluates the same range from the unchanged `last_evaluated_sha`. No `SYNC_COMPLETE: true` line is emitted. Distinct from a mid-sync interruption: here the gap is between decided and written, not started and finished.
- **Merge conflict on `wiki/log.md`.** Two sync runs on different branches will both prepend to the log. Resolve by keeping both lines, sorted newest-first.
- **`wiki/.state.json` is corrupted or invalid JSON.** Stop and surface to the user. Do not auto-rewrite, they may have made manual edits worth preserving. No `SYNC_COMPLETE: true` line is emitted.
