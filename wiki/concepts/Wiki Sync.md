---
type: concept
status: active
created: 2026-05-03
updated: 2026-05-06
tags: [concept, claude, workflow, wiki]
---

# Wiki Sync

The wiki only stays accurate if drift between code and knowledge is detected and resolved. GAIA does this in the user's existing Claude Code session — no spawned sub-Claudes, no extra API spend — by combining four hooks with a single workhorse command.

## The four pieces

1. **Drift-check hook** (`UserPromptSubmit`). Once per session, on the first prompt, compares `wiki/.state.json` to `git HEAD` and injects a one-line nudge if drifted. Catches anything that landed in the repo since the last sync — including commits made outside Claude (terminal, GitHub UI, automerge, teammate's pull).

2. **Commit-nudge hook** (`PostToolUse` on Bash matching `git commit`). After every commit Claude makes, injects a brief diff summary + drift count. Keeps Claude informed during a session, not just between sessions.

3. **Stop-safety-net hook** (`Stop`). At session end, if commits landed but `wiki/.state.json` didn't advance, injects a "review wiki before ending" reminder once per session.

4. **`/wiki-sync` command.** The workhorse. Reads commits between `last_evaluated_sha` and `HEAD`, classifies each as WORTHY or SKIP (subjects-and-stats first, deep-read only the worthy ones), edits relevant pages, appends `wiki/log.md`, advances `wiki/.state.json`, commits.

`wiki/.state.json` is the single source of truth for sync state. Two commands write to it: `/wiki-sync` owns `last_evaluated_sha` and `last_evaluated_at`; `/wiki-consolidate` owns `last_consolidated_sha` and `last_consolidated_at`. Each writer preserves the other's fields. The hooks are read-only.

## Convergence, not real-time

Wiki updates lag the code. A commit landing on `main` won't trigger an immediate wiki update. That's deliberate.

- The wiki is a knowledge layer, not a CI gate. It doesn't need to be in sync at every instant.
- It needs to be in sync **before the next meaningful action proceeds** — usually the next Claude session in the project.
- The drift-check hook is the convergence point: at the start of every session, drift is surfaced. The user (or Claude) decides whether to address it now or defer.

This handles the case that broke the previous design (`wiki-update-evaluator.sh`): commits made outside Claude — via `gh pr merge`, GitHub UI, or terminal — were never detected. The new system catches them at the next session, regardless of how they landed.

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

`last_evaluated_sha` is the commit through which `/wiki-sync` has fully evaluated. Drift = `git rev-list --count <last_evaluated_sha>..HEAD`.

`last_consolidated_sha` is owned by `/wiki-consolidate`. On the first sync that bootstraps this field, it is set to the new HEAD value, giving the consolidate gate a baseline to accumulate from.

If the file is missing, the hooks treat the project as fresh (silent — no nag). The first `/wiki-sync` run initializes it.

## Cost

The drift check itself is free (~30 tokens of injection once per session). The commit-nudge is light (~50–200 tokens per commit). The Stop safety net is free.

`/wiki-sync` is where the real cost lives. Two-pass design keeps it bounded:

| Drift size | Approximate token spend | Approximate $ on Sonnet |
| ---------- | ----------------------- | ----------------------- |
| 1–3        | ~10K                    | ~$0.03                  |
| 5–10       | ~30K                    | ~$0.10                  |
| 20+        | ~80K                    | ~$0.25                  |

If drift exceeds 30 commits, `/wiki-sync` asks before proceeding — long-skipped projects shouldn't surprise-bill.

`/wiki-sync` dispatches a Sonnet subagent in a fresh context to run the playbook — Sonnet is sufficient for the rule-based work, and the fresh context keeps git diffs and log content out of the parent (which may be on Opus). All cost still lives in the user's Claude Code session; there are no `claude -p` background invocations.

## What `/wiki-sync` does

For each commit since `last_evaluated_sha`:

1. **First-pass:** read subject + file stats. Classify WORTHY (likely needs a wiki update) or SKIP (typo, formatting, dep bump with no behavior change, etc.).
2. **Second-pass on WORTHY only:** read the diff. Edit the relevant `wiki/services/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/dependencies/`, etc. pages. If a commit looks worthy from its subject but turns out to be a refactor on diff inspection, demote to SKIP.
3. **Log every decision** (worthy and skipped) to `wiki/log.md` with a one-line reason.
4. **Advance state** to current HEAD.
5. **Commit** the wiki changes as `wiki: sync through <short_sha> (N updated, N skipped)`. The landing strategy is branch-aware: on `main` (push-protected), it creates `wiki/sync-YYYY-MM-DD`, pushes, opens a PR, and squash-merges; on any other branch (feature/fix/release/worktree), it commits in place so the maintainer's working state isn't fragmented.

The skip-with-reason audit trail is load-bearing: a project that always says "skipped: typo" tells you the system is running. A project with no log entries tells you the system has stopped. `wiki-lint` check #11 surfaces this drift.

## Consolidation gate

After every sync (including no-op syncs), `/wiki-sync` runs a cheap precheck: if any single wiki domain (`decisions/`, `concepts/`, `modules/`, `flows/`, `components/`, `dependencies/`) has ≥ 2 added pages since `last_consolidated_sha`, the sync wrapper automatically invokes [[Wiki Consolidate|`/wiki-consolidate`]]. The gate emits `CONSOLIDATE_TRIGGERED: true` in that case.

The threshold is calibrated so cross-page redundancy is detectable: one SPEC promoting to one domain has nothing to consolidate against; two SPECs in the same domain is the minimum case where supersession or near-collision can occur.

## When to run `/wiki-sync`

- When drift-check nags at session start
- After landing a meaningful change yourself
- Before opening a PR with substantive code changes
- When `wiki-lint` reports drift WARN or ERROR
- Before `/gaia-release` (which refuses to bump version on non-zero drift)

You don't need to run it after every commit. The hooks let you defer with full visibility.

## When NOT to run `/wiki-sync`

- Mid-debug session, when you're going to revert anyway
- On a feature branch that's still in flux — wait until the branch is at a checkpoint
- When the only commits since last sync are pure formatting / dep bumps with no behavior change (the SKIP path will handle them, but you can also run `/wiki-sync` later to consolidate)

## Failure modes

- **Mid-sync interruption.** `/wiki-sync` does not advance state on partial completion. The next sync resumes from the original `last_evaluated_sha`.
- **`wiki/.state.json` corrupted.** `/wiki-sync` stops and asks — won't auto-rewrite over manual edits.
- **Rebased history.** If `last_evaluated_sha` is no longer reachable, hooks silently skip; `/wiki-sync` re-anchors to HEAD on next run with a log entry.
- **Concurrent syncs on different branches.** `wiki/log.md` will conflict on merge. Resolve by keeping both lines, sorted newest-first.

## Adopters

This system is part of GAIA's standard scaffolding. Anyone who runs `create-gaia` gets:

- The four hooks pre-wired in `.claude/settings.json`
- The `/wiki-sync` command available immediately
- An initialized `wiki/.state.json` matching the release tag

Adopters customize the wiki content (services, decisions, etc.) but inherit the sync discipline. The system stays out of the way until it has something to surface.

See [[Quality Gate]], [[GAIA Plan]], [[Release Workflow]], [[Claude Hooks]].
