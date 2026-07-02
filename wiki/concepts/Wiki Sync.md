---
type: concept
status: active
created: 2026-05-03
updated: 2026-07-03
tags: [concept, claude, workflow, wiki]
---

# Wiki Sync

Drift between code and knowledge is detected and resolved in the user's existing Claude Code session (no spawned sub-Claudes) by combining four hooks with a single workhorse command.

## The four pieces

1. **Drift-check hook** (`UserPromptSubmit`). Once per session, on the first prompt, compares `wiki/.state.json` to `git HEAD` and injects a one-line nudge if drifted. Catches anything that landed in the repo since the last sync, including commits made outside Claude (terminal, GitHub UI, automerge, teammate's pull).

2. **Commit-nudge hook** (`PostToolUse` on Bash matching `git commit`). After every commit Claude makes, injects a brief diff summary + drift count. Keeps Claude informed during a session, not just between sessions.

3. **Stop-safety-net hook** (`Stop`). At session end, if commits landed but `wiki/.state.json` didn't advance, injects a "review wiki before ending" reminder once per session. It compares HEAD against a session-start marker (`$GIT_DIR/claude-session-start`) written by a companion `SessionStart` hook (`wiki-session-start.sh`), which also clears stale per-session caches.

4. **`/gaia-wiki sync` command.** The workhorse. Reads commits between `last_evaluated_sha` and `HEAD`, classifies each as WORTHY or SKIP (subjects-and-stats first, deep-read only the worthy ones), edits relevant pages, appends `wiki/log.md`, advances `wiki/.state.json`, commits.

`wiki/.state.json` is the single source of truth for sync state. Two commands write to it: `/gaia-wiki sync` owns `last_evaluated_sha` and `last_evaluated_at`; `/gaia-wiki consolidate` owns `last_consolidated_sha` and `last_consolidated_at`. Each writer preserves the other's fields. The hooks are read-only.

When the runtime-generated automation config (`automation.json` under `.gaia/`, created by `/gaia-init configure-automation`, not checked in) sets the `wiki` entry's mode to `ci`, the local hooks (drift-check, commit-nudge, Stop safety net) source `.claude/hooks/lib/gaia-ci-defer.sh` and stand down, so local triggers don't collide with a cron-managed wiki run. In `ci` mode the hooks silently do nothing.

## Convergence, not real-time

Wiki updates lag the code deliberately. The drift-check hook is the convergence point: at the start of every session, drift is surfaced, and the user (or Claude) decides whether to address it now or defer. This catches commits made outside Claude (via `gh pr merge`, GitHub UI, or terminal), regardless of how they landed.

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

`last_evaluated_sha` is the commit through which `/gaia-wiki sync` has fully evaluated. Drift = `git rev-list --count <last_evaluated_sha>..HEAD`.

`last_evaluated_at` is the timestamp of that evaluation, and it anchors recovery. Because a SHA is fragile under squash- and rebase-merge, the recorded commit is replaced and becomes unreachable, the timestamp provides a stable second anchor: `gaia wiki state` resolves the newest commit reachable from HEAD at or older than `last_evaluated_at` and reports it as `suggested_base`, the baseline a recovering sync resumes from.

`last_consolidated_sha` is owned by `/gaia-wiki consolidate`. On the first sync that bootstraps this field, it is set to the new HEAD value, giving the consolidate gate a baseline to accumulate from.

If the file is missing, the hooks treat the project as fresh (silent, no nag). The first `/gaia-wiki sync` run initializes it.

## Cost

The drift check itself is free (~30 tokens of injection once per session). The commit-nudge is light (~50–200 tokens per commit). The Stop safety net is free.

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

1. **First-pass:** read subject + file stats. Classify WORTHY (likely needs a wiki update) or SKIP (typo, formatting, dep bump with no behavior change, etc.).
2. **Second-pass on WORTHY only:** read the diff. Edit the relevant `wiki/services/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/dependencies/`, etc. pages. If a commit looks worthy from its subject but turns out to be a refactor on diff inspection, demote to SKIP.
3. **Log every decision** (worthy and skipped) to `wiki/log.md` with a one-line reason.
   3b. **Fabrication guard.** Before advancing state, asserts every WORTHY edit was actually written to disk: a per-path porcelain check confirms each claimed page shows as changed or created, and a broader content-change check confirms at least one wiki content file is modified when the WORTHY set is non-empty. Any failure aborts the run before state advances, leaving `last_evaluated_sha` unchanged so the next sync re-evaluates the same range.
4. **Advance state** to current HEAD.
5. **Commit** the wiki changes as `wiki: sync through <short_sha> (N updated, N skipped)`. The landing strategy is branch-aware: on `main` (push-protected), it creates `wiki-sync/<date>-<short_sha>`, pushes, and enables auto-merge (`gh pr merge --squash --auto --delete-branch`), which removes the remote head branch on merge regardless of the repo's auto-delete-head-branches setting; it then polls the PR (bounded attempts) until it merges and cleans up locally itself, returning to the base branch, pulling, deleting the local `wiki-sync/*` branch, and pruning. If the merge does not land within the poll window, auto-merge stays queued and cleanup is deferred to [[Local Working State|the session-start janitor]], which prunes the branch once its upstream shows `[gone]`. On any other branch (feature/fix/release/worktree), it commits in place so the maintainer's working state isn't fragmented.

When invoked as part of the no-arg `/gaia-wiki` full chain, `gaia wiki chain begin` pre-cuts the branch before sync runs, so this same step commits in place rather than opening its own PR. `gaia wiki chain finish` opens one PR covering all stage commits (sync, consolidate, lint) at the end of the chain. Standalone `/gaia-wiki sync` is unaffected: it still self-lands via `sync land --branch-aware`.

`sync land` uses `git status --porcelain=v1` to inspect the working tree. Git wraps paths containing spaces or special characters in double quotes; the CLI strips that quoting before classifying paths as wiki or non-wiki changes. Nearly every GAIA wiki page has a space in its filename, so this normalization is required for `sync land` to recognize wiki edits and proceed.

The skip-with-reason audit trail is load-bearing: absence of log entries signals the system has stopped running. `/gaia-wiki lint` check #11 surfaces this drift.

## Consolidation gate

After every sync (including no-op syncs), `/gaia-wiki sync` runs a cheap precheck: if any single wiki domain (`decisions/`, `concepts/`, `modules/`, `flows/`, `components/`, `dependencies/`) has ≥ 2 added pages since `last_consolidated_sha`, the sync wrapper automatically invokes [[Wiki Consolidate|`/gaia-wiki consolidate`]]. The gate emits `CONSOLIDATE_TRIGGERED: true` in that case.

The threshold is calibrated so cross-page redundancy is detectable: one SPEC promoting to one domain has nothing to consolidate against; two SPECs in the same domain is the minimum case where supersession or near-collision can occur.

## When to run `/gaia-wiki sync`

- When drift-check nags at session start
- After landing a meaningful change yourself
- Before opening a PR with substantive code changes
- When `/gaia-wiki lint` reports drift WARN or ERROR
- Before `/gaia-release` (which refuses to bump version on non-zero drift)

You don't need to run it after every commit. The hooks let you defer with full visibility.

## When NOT to run `/gaia-wiki sync`

- Mid-debug session, when you're going to revert anyway
- On a feature branch that's still in flux: wait until the branch is at a checkpoint
- When the only commits since last sync are pure formatting / dep bumps with no behavior change (the SKIP path will handle them, but you can also run `/gaia-wiki sync` later to consolidate)

## Failure modes

- **Mid-sync interruption.** `/gaia-wiki sync` does not advance state on partial completion. The next sync resumes from the original `last_evaluated_sha`.
- **Fabrication guard abort.** If WORTHY commits were classified but the decided edits are absent from the working tree (a model narrated edits without writing them), the run aborts before Step 6/7. State is not advanced and nothing is committed; the next sync re-evaluates the same range from the unchanged `last_evaluated_sha`. Distinct from a mid-sync interruption: here the gap is between decided and written, not started and finished.
- **`wiki/.state.json` corrupted.** `/gaia-wiki sync` stops and asks; it won't auto-rewrite over manual edits.
- **Orphaned baseline.** GAIA's squash-merge flow replaces the evaluated branch SHA with a new squash commit on every merge, so `last_evaluated_sha` is regularly unreachable from HEAD, not just after a manual rebase. The hooks silently skip while it is unreachable. `/gaia-wiki sync` recovers the un-evaluated window: it resolves a reachable baseline (the newest commit at or older than `last_evaluated_at`) and runs the normal evaluation pass from there, cataloguing every commit in between. Only when no baseline resolves, no `last_evaluated_at`, or it predates all history, does it fall back to a lossy re-anchor straight to HEAD with a `RE_ANCHOR` log entry.
- **Concurrent syncs on different branches.** `wiki/log.md` will conflict on merge. Resolve by keeping both lines, sorted newest-first.

## Adopters

`create-gaia` scaffolds:

- The four hooks pre-wired in `.claude/settings.json`
- The `/gaia-wiki sync` command
- An initialized `wiki/.state.json` matching the release tag

Adopters customize wiki content; the sync mechanism is inherited as-is.

See [[Quality Gate]], [[GAIA Plan]], [[Claude Hooks]].
