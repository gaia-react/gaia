---
type: concept
status: active
created: 2026-07-01
updated: 2026-07-08
tags: [concept, claude, hooks]
---

# Local Working State

`.gaia/local/` holds machine-local working state for GAIA's subsystems. It is gitignored in full, carries no tracked files, and is absent from `.gaia/manifest.json`, so nothing under it is committed or shipped to adopters. Each developer's copy is private to their machine, and subsystems create the subdirectories they need on demand (`mkdir -p`).

Because the folder is invisible to git, residue a subsystem leaves behind never surfaces in a diff and accumulates silently. A SessionStart janitor sweeps the residue whose death is provable; everything else is catalogued here so a reader can tell live state from leftovers.

## Layout

| Path | Owner | Kind | Retention |
|---|---|---|---|
| `.project-id`, `setup-state.json` | setup / identity | live | permanent identity |
| `mentorship.json`, `declined-updates.json` | mentorship / `/update-deps` | live | permanent preference |
| `.patched-statusline.sh`, `maintainer-statusline.sh` | statusline | live | regenerated |
| `audit/<sha>.ok`, `audit/<sha>.dispositions.json` | [[Code Review Audit Agent]] merge gate | ephemeral | spent once orphaned |
| `audit/progress.log` | audit gate | live | overwritten each run |
| `audit/KNOWLEDGE-*.md` | [[GAIA Audit]] | ephemeral | self-pruned by the next applied run |
| `audit/worthiness.jsonl` | worthiness check | live | append-only |
| `red-ledger/observations.jsonl` | TDD RED-verification | live | append-only |
| `debt/` | debt sentinel | live | symlinked to the main worktree's copy so a debt fix merged from a linked worktree arms the main checkout's count cache and sentinel; recomputed |
| `cache/` | [[GAIA Spec]] / gate sessions | ephemeral | reaped on SPEC merge/close and the merged-SPEC age reap; stale entries age-swept |
| `cache/shared/` | release / statusline (`update-gaia`, `check-updates.sh`, coaching) | live | symlinked to the main worktree's copy so every linked worktree shares one copy; self-pruned by its owners (tarball prune on update, coaching marker cleared each session) |
| `specs/` | [[GAIA Spec]] | live | a merged folder is kept at merge; age-reaped after the retention window |
| `specs/ledger.json` | [[GAIA Spec]] | live | per-machine number cache |
| `plans/PLAN-NNN/` | [[GAIA Plan]] | live | a merged folder is kept at merge (reduced to `SUMMARY.md` + `cost.json`, `RUNNING` cleared); age-reaped after the retention window |
| `plans/ledger.json` | [[GAIA Plan]] | live | per-machine number cache |
| `handoff/`, `forensics/` | [[GAIA Handoff]] / [[Forensics]] | live | drop zones |
| `telemetry/` | [[Telemetry]] | live | append-only logs |

Worktree creation symlinks a second, disjoint set alongside the six `.gaia/local/` paths above: the checkout-root gitignored `.env` / `.env.*` files (every basename matching `.env` or `.env.*`, excluding the committed `.env.example`). Each linked worktree gets `<worktree>/.env` (and any `.env.*`) symlinked to the main checkout's copy, so the worktree's `pnpm dev` and Playwright runs read the same local secrets without a manual copy. These files live at the checkout root, not under `.gaia/local/`, so they aren't rows in the table above.

A **live** entry is load-bearing state that tooling reads. An **ephemeral** entry is consumed once and then orphaned; its owner is meant to prune it, and the janitor backstops what the owner misses.

## The session-start janitor

`.claude/hooks/local-janitor.sh` runs from the SessionStart hook (`wiki-session-start.sh`) on `startup` and `resume`. It is the side-effect form of a SessionStart hook: it deletes files and injects nothing into context. It is a backstop, not an owner, so each subsystem still prunes its own residue at its next run. The janitor removes only residue whose death is provable, which makes it safe to run unconditionally every session. It sweeps seven things:

- **Merged-and-gone `wiki-sync/*` branches.** The wiki landing CLI (`gaia wiki chain finish` / `wiki sync land`) cuts a throwaway `wiki-sync/<date>-<sha>` branch, enables auto-merge with `gh pr merge --auto`, then polls for the merge and cleans up locally itself in the common case (checkout base, pull, delete branch, prune). Only when the merge does not land within the bounded poll window does it leave without cleaning up, deferring the local branch to this sweep. Once the PR squash-merges and a later `git fetch --prune` drops the tracking ref, the branch's upstream shows `[gone]`, the provable-death signal; the janitor hard-deletes (`git branch -D`, since a squash merge leaves the tip unmerged by ancestry) any `wiki-sync/*` branch in that state. This sweep is git-scoped, independent of `.gaia/local/`, so it runs before the guard below (a fresh clone can carry an orphaned branch before that directory exists).
- **Orphaned audit markers.** An `audit/<sha>.ok` or `<sha>.dispositions.json` gates `gh pr merge` only while its `<sha>` equals HEAD. Once a PR squash-merges to a new sha, the audited branch tip is no longer HEAD and is unreachable from any local branch, so the marker is spent. The janitor keeps a marker only when its `<sha>` is HEAD or reachable from a local branch; everything else, including a `<sha>` that is not a valid commit, is removed.
- **Completed-but-unswept plan dirs.** A `plans/PLAN-NNN/` (or a colocated `specs/<SPEC-ID>/plan[-N]/`) whose `RUNNING` sentinel names a branch that no longer exists and is not marked `DEFERRED`/`PAUSED`/`PARKED` is a plan that likely merged but whose self-cleanup never ran (an interrupted session). The branch-gone signal alone is not sufficient grounds to act: the janitor hands the directory to `plan-archive.sh` only once the plan's ledger row is confirmed terminal (a spec-less `PLAN-NNN` row at `merged`, or the parent SPEC's row at `merged` for a colocated plan); a non-terminal row leaves the folder in place rather than risking an unrecoverable disposition. `plan-archive.sh` itself keeps a spec-less plan (reduced to `SUMMARY.md` + `cost.json`, `RUNNING` cleared) rather than deleting it outright, gated again there on cost representation and on a consolidated `SUMMARY.md` already existing; a spec-colocated `plan[-N]` subfolder deletes only once the parent SPEC's own `SUMMARY.md` exists. A parked plan is always kept.
- **Stray empty dirs.** Empty directories under `.gaia/local/` are removed with `rmdir`, except the structural drop zones tooling expects to find (`audit`, `cache`, `plans`, `forensics`, `handoff`, `specs`, `telemetry`, and the other roots). `rmdir` cannot remove a non-empty directory, so a content-bearing dir is never at risk.
- **Stale SPEC/react-perf cache artifacts.** SPEC-workflow scratch at the root of `.gaia/local/cache/` (`gate1-*.json`, `draft-*.md`, `spec-session-*.json`, `audit-*/`) and react-perf run dirs (a `<run>/` holding `renders.json`) are reaped once older than 14 days. The window is age-gated rather than reference-checked, and deliberately generous, so a paused multi-day authoring session's live draft is never reaped mid-flight while abandoned drafts and forgotten profiling dumps are still collected. The `cache` drop zone itself is kept; only its stale contents go.
- **Merged SPEC folders past their retention window.** A `.gaia/local/specs/<SPEC-ID>/` folder whose ledger row is `merged` is kept in place at merge rather than deleted; this sweep delegates to the age-gated `spec-archive-merged.sh`, which reaps the folder only once its `merged_at` has aged past the retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days) and its cost is fully represented in `cost.jsonl`. A missing or unparseable `merged_at`, an unrepresented cost, or a folder still inside the window all keep it in place (fail-closed); this sweep is the SPEC-side counterpart to the plan sweep below.
- **Merged spec-less plan folders past their retention window.** A `.gaia/local/plans/PLAN-NNN/` folder already reduced to `SUMMARY.md` + `cost.json` by sweep 3's `plan-archive.sh` delegation stays in place until this sweep; this sweep delegates to the age-gated `plan-archive-merged.sh`, which reaps the folder only once its `merged_at` has aged past the same retention window and its cost is fully represented in `cost.jsonl`. A missing or unparseable `merged_at`, an unrepresented cost, a pending wiki-promote drain, or a folder still inside the window all keep it in place (fail-closed); this sweep is the plan-side counterpart to the SPEC sweep above, symmetric with how sweep 3 delegates the initial plan-folder disposition to `plan-archive.sh`.

The sweep is fail-safe: any inability to prove a thing is dead (no git, an unreadable HEAD, an unparseable sentinel) skips that thing, and the hook always exits 0 so it can never block a session from starting.

## Deciding by hand

Anything under `.gaia/local/` is safe to delete once its owner is done with it: a spent audit marker for an already-merged PR, a plan directory for a merged or abandoned branch, a `KNOWLEDGE-*.md` report already applied, a gate cache for a merged spec. The append-only ledgers (`red-ledger/observations.jsonl`, `audit/worthiness.jsonl`, `telemetry`), the identity files (`.project-id`, `setup-state.json`, `mentorship.json`), and `.gaia/local/specs/ledger.json` (and the `specs/` store it lives in) are the load-bearing exceptions; deleting the ledger drops per-machine draft-resume state and the local half of SPEC-number allocation.

See [[Claude Hooks]] for the hook surface and [[Audit Disposition and Debt Fix]] for the marker lifecycle.
