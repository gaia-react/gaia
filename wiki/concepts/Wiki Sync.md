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

3. **`/gaia-wiki` command.** The workhorse; its sync stage does the drift work. Reads commits between `last_evaluated_sha` and `HEAD`, classifies each as WORTHY or SKIP (subjects-and-stats first, deep-read only the worthy ones), edits relevant pages, appends `wiki/log.md`, advances `wiki/.state.json`, commits.

`wiki/.state.json` is the single source of truth for sync state. Two stages of `/gaia-wiki` write to it: the sync stage owns `last_evaluated_sha` and `last_evaluated_at`; the consolidate stage owns `last_consolidated_sha` and `last_consolidated_at`. Each writer preserves the other's fields. The hooks and the statusline are read-only.

`/gaia-wiki` always runs locally when invoked. There is no scheduled or CI-side wiki run.

### The drift count

`gaia wiki state --json` reports `drift_count`, the one drift definition the CLI, the statusline, and the release preflight share. It counts commits from `last_evaluated_sha` to HEAD when that SHA is reachable, else from `suggested_base`, else the whole history, and excludes wiki bookkeeping commits (`wiki: sync|maintenance chain|consolidate|lint through ...`) so a landed sync never counts against itself. `gaia wiki chain commit` and `gaia wiki chain finish` invalidate the refresher's cache after a commit or land, so the nudge clears on the next refresh. When the land is a queued auto-merge that has not merged yet, the recompute still reads the old state and the nudge stays until the merge lands and the main checkout's `wiki/.state.json` advances. The refresher records the `last_evaluated_sha` it computed against as `wikiStateSha` and treats a cache whose value differs from the state file's as past its TTL, so the nudge clears on the first refresh after the state file advances, by whatever route it reached the main checkout.

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

`last_evaluated_sha` is the commit through which the sync stage of `/gaia-wiki` has fully evaluated. Drift is the commit count of `<last_evaluated_sha>..HEAD`, minus wiki bookkeeping commits.

`last_evaluated_at` is the timestamp of that evaluation, and it anchors recovery. Because a SHA is fragile under squash- and rebase-merge, the recorded commit is replaced and becomes unreachable, the timestamp provides a stable second anchor: `gaia wiki state` resolves a reachable baseline from it and reports it as `suggested_base`, the baseline a recovering sync resumes from. The Orphaned baseline failure mode below is where that resolution is described.

`last_consolidated_sha` is owned by the consolidate stage of `/gaia-wiki`. The first sync that bootstraps this field sets it to the new HEAD value.

If the file is missing, the drift count covers the whole history and the first `/gaia-wiki` run initializes the file.

## Cost

The nudge costs no tokens: it is a statusline segment, not an injection. The Stop hook's `hot.md` prompt is free when no wiki change was committed or left uncommitted.

The sync stage of `/gaia-wiki` is where the real cost lives. Two-pass design keeps it bounded:

| Drift size | Approximate token spend | Approximate $ on Sonnet |
| ---------- | ----------------------- | ----------------------- |
| 1–3        | ~10K                    | ~$0.03                  |
| 5–10       | ~30K                    | ~$0.10                  |
| 20+        | ~80K                    | ~$0.25                  |

If drift exceeds 30 commits, the sync stage asks before proceeding; long-skipped projects shouldn't surprise-bill.

`/gaia-wiki` dispatches a Sonnet subagent in a fresh context to run the playbook; Sonnet handles the judgment and prose work (deep-reading WORTHY diffs, locating the right page, writing accurate edits and ADRs), and the fresh context keeps git diffs and log content out of the parent (which may be on Opus). All cost still lives in the user's Claude Code session; there are no `claude -p` background invocations.

## What the sync stage does

For each commit since `last_evaluated_sha`:

1. **First-pass:** read subject + file stats. Classify WORTHY (likely needs a wiki update) or SKIP (typo, formatting, dep bump with no behavior change, etc.). The classifier's source-path discrimination (which paths count as this project's source, as opposed to tests or tooling) is a declared, repo-configurable input under `gaia.wikiClassify` in `package.json`, defaulting to values sized for an adopter app under `frontend/app/**`; a repo whose source lives elsewhere (GAIA's own template repo included) tunes it there, and `/update-gaia` never touches keys outside its managed sections, so the tuning survives an update. Each run also reports a health signal, the share of evaluated commits that reached a fail-open default rather than a discriminating rule, and warns when that share crosses a threshold, so a stale or mistuned path vocabulary is visible rather than silently classifying every commit WORTHY.
2. **Second-pass on WORTHY only:** read the diff. Edit the relevant `wiki/services/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/dependencies/`, etc. pages. If a commit looks worthy from its subject but turns out to be a refactor on diff inspection, demote to SKIP.
3. **Log every decision** (worthy and skipped) to `wiki/log.md` with a one-line reason.
   3b. **Fabrication guard.** Before advancing state, asserts every WORTHY edit was actually written to disk: a per-path porcelain check confirms each claimed page shows as changed or created, and a broader content-change check confirms at least one wiki content file is modified when the WORTHY set is non-empty. Any failure aborts the run before state advances, leaving `last_evaluated_sha` unchanged so the next sync re-evaluates the same range.
4. **Advance state** to current HEAD.
5. **Commit** the wiki changes with `gaia wiki chain commit`, labelled `wiki: sync through <short_sha>`.

`/gaia-wiki` runs the stage inside its full chain: `gaia wiki chain begin` cuts the branch (or stays on a feature branch), the stages commit in place, and `gaia wiki chain finish` opens one PR covering every stage commit. `.claude/skills/gaia/references/wiki.md` owns invocation and landing, and [[Local Working State|the session-start janitor]] catches the local checkout up after a queued auto-merge.

`gaia wiki chain commit` and `gaia wiki chain finish` inspect the working tree with `git status --porcelain=v1 -z -uall`, parsed by a shared `-z` record reader (`util/git-status.ts`, with the branch helpers in `util/branch.ts`) also used by the region regeneration runner. `-z` sidesteps quoting entirely: git's default C-style quoting would otherwise wrap any path with a space, a quote, or a non-ASCII byte in `"..."`, and would turn a rename into one ambiguous `old -> new` payload that cannot be split on `" -> "` without corrupting a name containing it. Under `-z`, a rename's origin path arrives as its own trailing record instead, so neither hazard occurs. Nearly every GAIA wiki page has a space in its filename, so this is required for the chain commands to recognize wiki edits and proceed, and it holds equally for a wiki page rename carrying a non-ASCII byte in its path.

The skip-with-reason audit trail is load-bearing: absence of log entries signals the system has stopped running. `/gaia-wiki`'s lint stage check #11 surfaces this drift.

## Consolidation

Consolidate runs on every chain whose sync completes normally: sync's summary ends with `SYNC_COMPLETE: true`, and the router branches on that line. See [[Wiki Consolidate]].

## When to run `/gaia-wiki`

- When the `🧠 Run /gaia-wiki` nudge shows
- After landing a meaningful change yourself
- Before opening a PR with substantive code changes
- When the lint stage of `/gaia-wiki` flags drift as WARN or ERROR
<!-- gaia:maintainer-only:start -->
- Before `/gaia-release` (which refuses to bump version on non-zero drift)
<!-- gaia:maintainer-only:end -->

You don't need to run it after every commit. The nudge lets you defer with full visibility.

## When NOT to run `/gaia-wiki`

- Mid-debug session, when you're going to revert anyway
- On a feature branch that's still in flux: wait until the branch is at a checkpoint
- When the only commits since last sync are pure formatting / dep bumps with no behavior change (the SKIP path handles them)

## Failure modes

- **Mid-sync interruption.** The sync stage does not advance state on partial completion. The next sync resumes from the original `last_evaluated_sha`.
- **Fabrication guard abort.** If WORTHY commits were classified but the decided edits are absent from the working tree (a model narrated edits without writing them), the run aborts before Step 6/7. State is not advanced and nothing is committed; the next sync re-evaluates the same range from the unchanged `last_evaluated_sha`. Distinct from a mid-sync interruption: here the gap is between decided and written, not started and finished.
- **`wiki/.state.json` corrupted.** The sync stage stops and asks; it won't auto-rewrite over manual edits.
- **Orphaned baseline.** GAIA's squash-merge flow replaces the evaluated branch SHA with a new squash commit on every merge, so `last_evaluated_sha` is regularly unreachable from HEAD, not just after a manual rebase. The drift count falls back to `suggested_base` while it is unreachable. The sync stage recovers the un-evaluated window: it resolves a reachable baseline (the newest commit on HEAD's first-parent chain at or older than `last_evaluated_at`) and runs the normal evaluation pass from there, cataloguing every commit in between. The first-parent walk is what keeps the window honest, since a commit's committer date is not when it reached the trunk: a merge commit carries the merged branch's original dates onto the trunk later, so a baseline resolved over every ancestor can settle on a commit that arrived after the marker and drop it from the window. Resolving along the trunk's own integration points errs toward re-evaluating commits instead. Only when no baseline resolves, no `last_evaluated_at`, or it predates all history, does it fall back to a lossy re-anchor straight to HEAD with a `RE_ANCHOR` log entry.
- **Concurrent syncs on different branches.** `wiki/log.md` will conflict on merge. Resolve by keeping both lines, sorted newest-first.

## Adopters

`create-gaia` scaffolds:

- The wiki hooks pre-wired in `.claude/settings.json` and the statusline nudge
- The `/gaia-wiki` command
- An initialized `wiki/.state.json` matching the release tag

Adopters customize wiki content; the sync mechanism is inherited as-is.

See [[Quality Gate]], [[GAIA Plan]], [[Claude Hooks]].
