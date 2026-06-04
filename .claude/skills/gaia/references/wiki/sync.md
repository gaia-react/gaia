# wiki-sync playbook

Dispatched by the `/gaia-wiki` router (`references/wiki.md` → "Sync"). Runs in a Sonnet subagent context.

## Playbook

Evaluate every commit between `wiki/.state.json` `last_evaluated_sha` and HEAD. For each, decide whether the wiki needs an update. Edit pages, log decisions, advance state, commit.

`wiki/.state.json` is written by two workflows: this one writes the sync-related fields (`last_evaluated_sha`, `last_evaluated_at`); `/gaia-wiki consolidate` writes the consolidate-related field (`last_consolidated_sha`). Each must preserve fields owned by the other when writing. The hooks (`wiki-drift-check`, `wiki-commit-nudge`, `wiki-session-stop`) are read-only consumers.

## Step 1: Read state and compute drift

Run `.gaia/cli/gaia wiki state --json` and parse the result. Use `head_short`, `state_sha`, `commits_ahead`, `reachable`, and `suggested_base` directly.

Throughout this playbook, **the evaluation baseline** is the ref Steps 2, 3, and 8 evaluate from. On the normal path it is `last_evaluated_sha`; on the recovery path (below) it is `suggested_base`. Each branch states which.

- If the command exits non-zero with a `state_missing` (or equivalent) reason, this is a fresh project (no prior sync). Treat the first commit as the baseline. Run `.gaia/cli/gaia wiki state-init "$(git rev-list --max-parents=0 HEAD | tail -1)"` to create `wiki/.state.json` with `{version, last_evaluated_sha, last_evaluated_at}`, then commit as `wiki: initialize state at {short_sha}`. Stop, no commits to evaluate yet.
- If `commits_ahead === 0`: skip the evaluation pass (no commits to evaluate) but DO NOT exit yet, fall through to Step 9 (consolidate gate). The gate may still trigger consolidate based on accumulated page-adds since last consolidate run, even when this sync is a no-op. The Step 8 report still prints; just substitute `Wiki already in sync at {short_sha}.` for the regular summary block, then run Step 9.
- If `reachable === false`: the recorded `last_evaluated_sha` is not in HEAD's history. GAIA's squash-merge flow orphans it on **every** merge, the evaluated branch SHA is replaced by a new squash commit on `main`, so this is the common case, not just a manual rebase. Recover the un-evaluated window instead of discarding it:
  - **Recovery path, when `suggested_base` is non-empty.** The CLI resolved `suggested_base` to the newest commit reachable from HEAD at or older than `last_evaluated_at`, a reachable baseline equivalent to where the orphaned SHA left off. Adopt `suggested_base` as the evaluation baseline and run the normal pass (Steps 2–9) from it. Do NOT jump to HEAD and do NOT log a `RE_ANCHOR` line, the window is evaluated, not abandoned. Step 6 advances `last_evaluated_sha` to HEAD as usual.
  - **Fallback path, when `suggested_base` is empty.** Only when the CLI cannot resolve a baseline (no `last_evaluated_at`, or it predates all history) revert to the lossy-but-safe re-anchor: run `.gaia/cli/gaia wiki state-bump last_evaluated_sha "$(git rev-parse HEAD)"`, then `.gaia/cli/gaia wiki log-prepend --sha "$(git rev-parse --short HEAD)" --decision RE_ANCHOR --reason "re-anchored after history rewrite (no recoverable baseline)"`, commit, exit. Skip Step 9, there is no recovered range to consolidate against.
- Otherwise proceed with the evaluation pass on the normal baseline (`last_evaluated_sha`).

## Step 2: Drift cap check

If drift > 30 commits, ASK the user via `AskUserQuestion`:

- Question: `Wiki is {N} commits behind HEAD. Syncing all may cost ~${estimated} in tokens. Proceed?`
- Options:
  - `Sync all {N} commits` (description: full evaluation)
  - `Sync recent N commits only` (description: evaluate the last 20 commits, re-anchor state)
  - `Cancel` (description: do nothing)

Only proceed automatically when drift ≤ 30.

The drift count is `commits_ahead` on the normal path. On the recovery path `commits_ahead` is `0` (the recorded SHA is unreachable, so the CLI cannot count from it); use the recovered range size instead, `git rev-list --count <suggested_base>..HEAD`, and apply this same cap to it. A batch that landed since the last sync (worst case, a whole release) shows up here and is gated exactly like normal drift.

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

The dedup guard matters most on the recovery path (Step 1): the resolved `suggested_base` is time-anchored, so it can sit one or two commits behind a boundary a prior sync already logged. Skip any commit whose short SHA is already in `wiki/log.md` rather than appending a duplicate line.

The CLI inserts a single canonical line `- <YYYY-MM-DD> <sha> <decision>, <reason>` at the top of `wiki/log.md` (after frontmatter), atomically, newest entries on top. Examples:

- WORTHY: `.gaia/cli/gaia wiki log-prepend --sha abc1234 --decision WORTHY --reason "added /services/Gemini integration → wiki/services/Gemini.md"`
- SKIP: `.gaia/cli/gaia wiki log-prepend --sha def5678 --decision SKIP --reason "typo-only commit"`
- Serena-policy SKIP: `.gaia/cli/gaia wiki log-prepend --sha 9a0b1c2 --decision SKIP --reason "Serena handles inventory, added Button variant in app/components/Button"`

## Step 5b: Fabrication guard, verify edits landed on disk

Before advancing state or landing, prove the Step 4 decisions actually wrote to disk. This is the fabrication guard: a run that logged WORTHY decisions in Step 5 and is about to advance state (Step 6) and commit (Step 7) MUST have produced the corresponding page edits. Without this check a model can satisfy the workflow's success signal (summary + log + state) while writing no content, and Step 7 launders that empty sync into a green commit.

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

Because the run aborts before Step 8/9, no `CONSOLIDATE_TRIGGERED` line is emitted. The router (`references/wiki.md` → "Full chain") already treats an absent trigger line as a known-incomplete state and skips consolidate and lint, so an abort fails the whole chain safely without further wiring.

## Step 6: Advance state file

Run:

```bash
NEW_HEAD=$(git rev-parse HEAD)
NEW_HEAD_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
.gaia/cli/gaia wiki state-bump last_evaluated_sha "$NEW_HEAD"
.gaia/cli/gaia wiki state-bump last_evaluated_at "$NEW_HEAD_AT"
```

`state-bump` writes atomically, preserving sibling fields (`last_consolidated_sha` owned by `/gaia-wiki consolidate`) and key order.

If `last_consolidated_sha` is absent on the existing state (first sync ever): bootstrap it with `.gaia/cli/gaia wiki state-bump last_consolidated_sha "$NEW_HEAD"`. This gives the consolidate gate a baseline so subsequent runs accumulate from a known point.

## Step 7, Land

Run: `.gaia/cli/gaia wiki sync land --branch-aware`

Exit codes:

- 0, landed (CLI summary line shows how)
- 1, refused (CLI stderr explains why; surface to user verbatim)
- 2, unexpected (surface to user; do NOT retry)

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

After the summary block, append the Step 9 result line `CONSOLIDATE_TRIGGERED: <true|false>` on its own line (no leading whitespace). The router (`references/wiki.md`) reads this to decide whether to invoke consolidate next.

## Step 9: Consolidate gate

Cheap precheck. Decides whether `/gaia-wiki consolidate` should fire next based on per-domain new-page accumulation since the last consolidate run.

### 9a. Read state

```bash
CONSOLIDATED_SHA=$(jq -r '.last_consolidated_sha // empty' wiki/.state.json)
HEAD_SHA=$(git rev-parse HEAD)
```

If `CONSOLIDATED_SHA` is empty (the bootstrap case from Step 6 wasn't reached because Step 6 was skipped on the drift=0 path AND no prior sync ever wrote the field): emit `CONSOLIDATE_TRIGGERED: false` and exit. Step 6 will bootstrap the field on the next non-zero-drift sync. Do not bootstrap from inside Step 9, keep this step read-only on the state file.

### 9b. Count added pages per domain

```bash
git diff --name-only --diff-filter=A "$CONSOLIDATED_SHA"..HEAD -- \
  wiki/decisions/ wiki/concepts/ wiki/modules/ wiki/flows/ wiki/components/ wiki/dependencies/
```

Group the output by parent directory (the domain). Count pages per domain. Skip files in `wiki/_archived/` (handled by the path filter, `_archived/` is not in the list).

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

The router reads the last line and decides whether to invoke consolidate. The gate itself never invokes consolidate directly, it stays a read-only check.

### 9e. Edge cases

- **Drift=0 sync (no commits since last sync).** Gate still runs. The page-add count is computed against `last_consolidated_sha`, not against the sync's evaluation range, so accumulated adds from earlier syncs may still meet threshold.
- **Recovery re-anchor (Step 1, `suggested_base` resolved).** The run goes through the full pass, so Step 9 executes normally, the recovered range is evaluated and the gate counts page-adds as usual.
- **Fallback re-anchor (Step 1, `suggested_base` empty).** Step 1 exits before Step 9. After the fallback re-anchor, the next sync's Step 6 will preserve any existing `last_consolidated_sha`; the gate resumes counting from there. If the anchor change put `last_consolidated_sha` upstream of HEAD by an unreachable path, the next gate's `git diff` returns empty → `false`. Acceptable; the maintainer can run consolidate manually.
- **Consolidate's own commits in the diff.** If a previous consolidate run produced commits that landed (retirements moving pages to `wiki/_archived/`, near-collision renames inside an active domain), those appear in the next gate's diff. `_archived/` is excluded by path. Renames inside an active domain show as added paths and may trigger a redundant consolidate fire. Living with that, the false positive is cheap (consolidate runs, finds nothing new, advances state, returns).

## Failure modes

- **Mid-sync interruption.** If you've edited some pages but not all, do NOT advance state. Commit only the partial wiki edits with subject `wiki: partial sync (interrupted at {short_sha})` and stop. The next sync resumes from the original `last_evaluated_sha`, not the partial one.
- **Fabrication guard abort (Step 5b).** WORTHY commits were classified but the decided edits are absent from the working tree. State is not advanced and nothing is committed, so the next sync re-evaluates the same range from the unchanged `last_evaluated_sha`. Distinct from a mid-sync interruption: here the gap is between decided and written, not started and finished.
- **Merge conflict on `wiki/log.md`.** Two sync runs on different branches will both prepend to the log. Resolve by keeping both lines, sorted newest-first.
- **`wiki/.state.json` is corrupted or invalid JSON.** Stop and surface to the user. Do not auto-rewrite, they may have made manual edits worth preserving.
