---
type: concept
status: active
created: 2026-05-03
updated: 2026-10-03
tags: [concept, claude, workflow, wiki]
---

# Wiki Sync

Drift between code and knowledge is detected and resolved in the user's existing Claude Code session (no spawned sub-Claudes) by combining a statusline nudge with a single workhorse command.

## The three pieces

1. **Statusline nudge.** The only drift signal. When the count of commits since the last sync reaches the threshold the statusline wrapper declares, the wrapper shows `🧠 Run /gaia-wiki` in the last nudge slot, below `/gaia-residue`. The count is computed by the cache refresher `.gaia/scripts/check-updates.sh` from `gaia wiki state --json`'s `drift_count` and cached as `wikiDriftCount`, so it catches anything that landed in the repo since the last sync, including commits made outside Claude (terminal, GitHub UI, automerge, teammate's pull). The threshold lives in `.gaia/statusline/gaia-statusline.sh`; adopters can neither tune nor disable it. No hook injects a drift reminder into the conversation.

2. **Stop hook** (`Stop`). `wiki-session-stop.sh` prompts a `hot.md` refresh when the session committed changes under `wiki/` or left uncommitted `wiki/` content changes. A companion `SessionStart` hook (`wiki-session-start.sh`) records a session-start marker (`$GIT_DIR/claude-session-start`) it compares HEAD against and a baseline of the uncommitted `wiki/` content, clears stale per-session caches, and runs the janitor. See [[Claude Hooks]] for both triggers and the paths the uncommitted check ignores. The janitor's base-catch-up report reaches the conversation through `janitor-report-drain.sh` (`UserPromptSubmit`), which reads and deletes the report so the line surfaces exactly once.

3. **`/gaia-wiki sync` command.** The workhorse. Reads commits between `last_evaluated_sha` and `HEAD`, classifies each as WORTHY or SKIP (subjects-and-stats first, deep-read only the worthy ones), edits relevant pages, appends `wiki/log.md`, advances `wiki/.state.json`, commits.

`wiki/.state.json` is the single source of truth for sync state. Two commands write to it: `/gaia-wiki sync` owns `last_evaluated_sha` and `last_evaluated_at`; `/gaia-wiki consolidate` owns `last_consolidated_sha` and `last_consolidated_at`. Each writer preserves the other's fields. The hooks and the statusline are read-only.

`/gaia-wiki` always runs locally when invoked. There is no scheduled or CI-side wiki run.

### The drift count

`gaia wiki state --json` reports `drift_count`, the one drift definition the CLI, the statusline, and the release preflight share. It counts commits from `last_evaluated_sha` to HEAD when that SHA is reachable, else from `suggested_base`, else the whole history, and excludes wiki bookkeeping commits (`wiki: sync|maintenance chain|consolidate|lint through ...`) so a landed sync never counts against itself. `gaia wiki sync land` and `gaia wiki chain finish` invalidate the refresher's cache after a land, so the nudge clears on the next refresh. When the land is a queued auto-merge that has not merged yet, the recompute still reads the old state and the nudge stays until the merge lands and the main checkout's `wiki/.state.json` advances.

## Convergence, not real-time

Wiki updates lag the code deliberately. The statusline nudge is the convergence point: once drift crosses the threshold it shows on every prompt, and the user (or Claude) decides whether to address it now or defer. This catches commits made outside Claude (via `gh pr merge`, GitHub UI, or terminal), regardless of how they landed.

## State file shape

`wiki/.state.json`:

```json
{
  "version": 1,
  "last_evaluated_sha": "<full 40-char SHA>",
  "last_evaluated_at": "<ISO 8601 UTC>",
  "last_consolidated_sha": "<full 40-char SHA>",
  "last_consolidated_at": "<ISO 8601 UTC>"
}
```

`last_evaluated_sha` is the commit through which `/gaia-wiki sync` has fully evaluated. Drift is the commit count of `<last_evaluated_sha>..HEAD`, minus wiki bookkeeping commits.

`last_evaluated_at` is the timestamp of that evaluation, and it anchors recovery. Because a SHA is fragile under squash- and rebase-merge, the recorded commit is replaced and becomes unreachable, the timestamp provides a stable second anchor: `gaia wiki state` resolves a reachable baseline from it and reports it as `suggested_base`, the baseline a recovering sync resumes from. The Orphaned baseline failure mode below is where that resolution is described.

`last_consolidated_sha` is owned by `/gaia-wiki consolidate`. On the first sync that bootstraps this field, it is set to the new HEAD value, giving the consolidate gate a baseline to accumulate from.

If the file is missing, the drift count covers the whole history and the first `/gaia-wiki sync` run initializes the file.

## Cost

The nudge costs no tokens: it is a statusline segment, not an injection. The Stop hook's `hot.md` prompt is free when no wiki change was committed or left uncommitted.

`/gaia-wiki sync` is where the real cost lives. Two-pass design keeps it bounded:

| Drift size | Approximate token spend | Approximate $ on Sonnet |
| ---------- | ----------------------- | ----------------------- |
| 1–3        | ~10K                    | ~$0.03                  |
| 5–10       | ~30K                    | ~$0.10                  |
| 20+        | ~80K                    | ~$0.25                  |

If drift exceeds 30 commits, `/gaia-wiki sync` asks before proceeding; long-skipped projects shouldn't surprise-bill.

`/gaia-wiki sync` dispatches a Sonnet subagent in a fresh context to run the playbook; Sonnet handles the judgment and prose work (deep-reading WORTHY diffs, locating the right page, writing accurate edits and ADRs), and the fresh context keeps git diffs and log content out of the parent (which may be on Opus). All cost still lives in the user's Claude Code session; there are no `claude -p` background invocations.

## What `/gaia-wiki sync` does

For each commit since `last_evaluated_sha`:

1. **First-pass:** read subject + file stats. Classify WORTHY (likely needs a wiki update) or SKIP (typo, formatting, dep bump with no behavior change, etc.). The classifier's source-path discrimination (which paths count as this project's source, as opposed to tests or tooling) is a declared, repo-configurable input under `gaia.wikiClassify` in `package.json`, defaulting to values sized for an adopter app under `frontend/app/**`; a repo whose source lives elsewhere (GAIA's own template repo included) tunes it there, and `/update-gaia` never touches keys outside its managed sections, so the tuning survives an update. Each run also reports a health signal, the share of evaluated commits that reached a fail-open default rather than a discriminating rule, and warns when that share crosses a threshold, so a stale or mistuned path vocabulary is visible rather than silently classifying every commit WORTHY.
2. **Second-pass on WORTHY only:** read the diff. Edit the relevant `wiki/services/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/dependencies/`, etc. pages. If a commit looks worthy from its subject but turns out to be a refactor on diff inspection, demote to SKIP.
3. **Log every decision** (worthy and skipped) to `wiki/log.md` with a one-line reason.
   3b. **Fabrication guard.** Before advancing state, asserts every WORTHY edit was actually written to disk: a per-path porcelain check confirms each claimed page shows as changed or created, and a broader content-change check confirms at least one wiki content file is modified when the WORTHY set is non-empty. Any failure aborts the run before state advances, leaving `last_evaluated_sha` unchanged so the next sync re-evaluates the same range.
4. **Advance state** to current HEAD.
5. **Commit** the wiki changes as `wiki: sync through <short_sha> (N updated, N skipped)`. The landing strategy is branch-aware: on `main` (push-protected), it creates `wiki/sync-<date>-<short_sha>`, pushes, and enables auto-merge (`gh pr merge --squash --auto --delete-branch`); it then takes one bounded wait on the PR. `--delete-branch` removes no branch at all on the queued path, so the repo's own auto-delete-head-branches setting is what removes the remote head branch once the merge lands. If the merge lands inside that wait, the CLI cleans up locally itself, returning to the base branch, pulling, deleting the local `wiki/sync-*` branch, and pruning. On the common path the merge gate outlasts any wait that fits in a single invocation, so the CLI returns with the local cleanup outstanding: auto-merge stays queued and GitHub completes it once checks pass. [[Local Working State|The session-start janitor]] then catches the local checkout up: it prune-fetches, reaps the merged-and-gone branch once `git cherry` confirms its work is already represented upstream, and fast-forwards base with `--ff-only`; that obligation is durable across sessions and needs no new landing to discharge. On any other branch (feature/fix/release/worktree), it commits in place so the maintainer's working state isn't fragmented.

When invoked as part of the no-arg `/gaia-wiki` full chain, `gaia wiki chain begin` pre-cuts the branch before sync runs, so this same step commits in place rather than opening its own PR. `gaia wiki chain finish` opens one PR covering all stage commits (sync, consolidate, lint) at the end of the chain. Standalone `/gaia-wiki sync` is unaffected: it still self-lands via `sync land --branch-aware`.

`sync land` inspects the working tree with `git status --porcelain=v1 -z -uall`, parsed by a shared `-z` record reader (`util/git-status.ts`) also used by the region regeneration runner. `-z` sidesteps quoting entirely: git's default C-style quoting would otherwise wrap any path with a space, a quote, or a non-ASCII byte in `"..."`, and would turn a rename into one ambiguous `old -> new` payload that cannot be split on `" -> "` without corrupting a name containing it. Under `-z`, a rename's origin path arrives as its own trailing record instead, so neither hazard occurs. Nearly every GAIA wiki page has a space in its filename, so this is required for `sync land` to recognize wiki edits and proceed, and it holds equally for a wiki page rename carrying a non-ASCII byte in its path.

The skip-with-reason audit trail is load-bearing: absence of log entries signals the system has stopped running. `/gaia-wiki lint` check #11 surfaces this drift.

## Consolidation gate

After every sync (including no-op syncs), `/gaia-wiki sync` runs a cheap precheck: if any single wiki domain (`decisions/`, `concepts/`, `modules/`, `flows/`, `components/`, `dependencies/`) has ≥ 2 added pages since `last_consolidated_sha`, the sync wrapper automatically invokes [[Wiki Consolidate|`/gaia-wiki consolidate`]]. The gate emits `CONSOLIDATE_TRIGGERED: true` in that case.

The threshold is calibrated so cross-page redundancy is detectable: one SPEC promoting to one domain has nothing to consolidate against; two SPECs in the same domain is the minimum case where supersession or near-collision can occur.

## When to run `/gaia-wiki sync`

- When the `🧠 Run /gaia-wiki` nudge shows
- After landing a meaningful change yourself
- Before opening a PR with substantive code changes
- When `/gaia-wiki lint` flags drift as WARN or ERROR
<!-- gaia:maintainer-only:start -->
- Before `/gaia-release` (which refuses to bump version on non-zero drift)
<!-- gaia:maintainer-only:end -->

You don't need to run it after every commit. The nudge lets you defer with full visibility.

## When NOT to run `/gaia-wiki sync`

- Mid-debug session, when you're going to revert anyway
- On a feature branch that's still in flux: wait until the branch is at a checkpoint
- When the only commits since last sync are pure formatting / dep bumps with no behavior change (the SKIP path will handle them, but you can also run `/gaia-wiki sync` later to consolidate)

## Failure modes

- **Mid-sync interruption.** `/gaia-wiki sync` does not advance state on partial completion. The next sync resumes from the original `last_evaluated_sha`.
- **Fabrication guard abort.** If WORTHY commits were classified but the decided edits are absent from the working tree (a model narrated edits without writing them), the run aborts before Step 6/7. State is not advanced and nothing is committed; the next sync re-evaluates the same range from the unchanged `last_evaluated_sha`. Distinct from a mid-sync interruption: here the gap is between decided and written, not started and finished.
- **`wiki/.state.json` corrupted.** `/gaia-wiki sync` stops and asks; it won't auto-rewrite over manual edits.
- **Orphaned baseline.** GAIA's squash-merge flow replaces the evaluated branch SHA with a new squash commit on every merge, so `last_evaluated_sha` is regularly unreachable from HEAD, not just after a manual rebase. The drift count falls back to `suggested_base` while it is unreachable. `/gaia-wiki sync` recovers the un-evaluated window: it resolves a reachable baseline (the newest commit on HEAD's first-parent chain at or older than `last_evaluated_at`) and runs the normal evaluation pass from there, cataloguing every commit in between. The first-parent walk is what keeps the window honest, since a commit's committer date is not when it reached the trunk: a merge commit carries the merged branch's original dates onto the trunk later, so a baseline resolved over every ancestor can settle on a commit that arrived after the marker and drop it from the window. Resolving along the trunk's own integration points errs toward re-evaluating commits instead. Only when no baseline resolves, no `last_evaluated_at`, or it predates all history, does it fall back to a lossy re-anchor straight to HEAD with a `RE_ANCHOR` log entry.
- **Concurrent syncs on different branches.** `wiki/log.md` will conflict on merge. Resolve by keeping both lines, sorted newest-first.

## Adopters

`create-gaia` scaffolds:

- The wiki hooks pre-wired in `.claude/settings.json` and the statusline nudge
- The `/gaia-wiki sync` command
- An initialized `wiki/.state.json` matching the release tag

Adopters customize wiki content; the sync mechanism is inherited as-is.

See [[Quality Gate]], [[GAIA Plan]], [[Claude Hooks]].
