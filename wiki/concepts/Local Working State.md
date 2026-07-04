---
type: concept
status: active
created: 2026-07-01
updated: 2026-07-04
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
| `debt/` | debt sentinel | live | recomputed |
| `cache/` | [[GAIA Spec]] / gate sessions | ephemeral | reaped on SPEC merge/close; stale entries age-swept |
| `cache/shared/` | release / statusline (`update-gaia`, `check-updates.sh`, coaching) | live | symlinked to the main worktree's copy so every linked worktree shares one copy; self-pruned by its owners (tarball prune on update, coaching marker cleared each session) |
| `specs/`, `specs/archived/` | [[GAIA Spec]] | live | spec store |
| `specs/ledger.json` | [[GAIA Spec]] | live | per-machine number cache |
| `plans/PLAN-NNN/` | [[GAIA Plan]] | ephemeral | self-deleted on merge |
| `plans/ledger.json` | [[GAIA Plan]] | live | per-machine number cache |
| `handoff/`, `forensics/` | [[GAIA Handoff]] / [[Forensics]] | live | drop zones |
| `telemetry/` | [[Telemetry]] | live | append-only logs |

A **live** entry is load-bearing state that tooling reads. An **ephemeral** entry is consumed once and then orphaned; its owner is meant to prune it, and the janitor backstops what the owner misses.

## The session-start janitor

`.claude/hooks/local-janitor.sh` runs from the SessionStart hook (`wiki-session-start.sh`) on `startup` and `resume`. It is the side-effect form of a SessionStart hook: it deletes files and injects nothing into context. It is a backstop, not an owner, so each subsystem still prunes its own residue at its next run. The janitor removes only residue whose death is provable, which makes it safe to run unconditionally every session. It sweeps four things:

- **Merged-and-gone `wiki-sync/*` branches.** The wiki landing CLI (`gaia wiki chain finish` / `wiki sync land`) cuts a throwaway `wiki-sync/<date>-<sha>` branch, enables auto-merge with `gh pr merge --auto`, then polls for the merge and cleans up locally itself in the common case (checkout base, pull, delete branch, prune). Only when the merge does not land within the bounded poll window does it leave without cleaning up, deferring the local branch to this sweep. Once the PR squash-merges and a later `git fetch --prune` drops the tracking ref, the branch's upstream shows `[gone]`, the provable-death signal; the janitor hard-deletes (`git branch -D`, since a squash merge leaves the tip unmerged by ancestry) any `wiki-sync/*` branch in that state. This sweep is git-scoped, independent of `.gaia/local/`, so it runs before the guard below (a fresh clone can carry an orphaned branch before that directory exists).
- **Orphaned audit markers.** An `audit/<sha>.ok` or `<sha>.dispositions.json` gates `gh pr merge` only while its `<sha>` equals HEAD. Once a PR squash-merges to a new sha, the audited branch tip is no longer HEAD and is unreachable from any local branch, so the marker is spent. The janitor keeps a marker only when its `<sha>` is HEAD or reachable from a local branch; everything else, including a `<sha>` that is not a valid commit, is removed.
- **Completed-but-unswept plan dirs.** A `plans/PLAN-NNN/` whose `RUNNING` sentinel names a branch that no longer exists and is not marked `DEFERRED`/`PAUSED`/`PARKED` is a plan that merged but whose self-cleanup never ran (an interrupted session). The janitor removes the directory. A parked plan is always kept.
- **Stray empty dirs.** Empty directories under `.gaia/local/` are removed with `rmdir`, except the structural drop zones tooling expects to find (`audit`, `cache`, `plans`, `forensics`, `handoff`, `specs`, `telemetry`, and the other roots). `rmdir` cannot remove a non-empty directory, so a content-bearing dir is never at risk.

The sweep is fail-safe: any inability to prove a thing is dead (no git, an unreadable HEAD, an unparseable sentinel) skips that thing, and the hook always exits 0 so it can never block a session from starting.

## Deciding by hand

Anything under `.gaia/local/` is safe to delete once its owner is done with it: a spent audit marker for an already-merged PR, a plan directory for a merged or abandoned branch, a `KNOWLEDGE-*.md` report already applied, a gate cache for an archived spec. The append-only ledgers (`red-ledger/observations.jsonl`, `audit/worthiness.jsonl`, `telemetry`), the identity files (`.project-id`, `setup-state.json`, `mentorship.json`), and `.gaia/local/specs/ledger.json` (and the `specs/` store it lives in) are the load-bearing exceptions; deleting the ledger drops per-machine draft-resume state and the local half of SPEC-number allocation.

See [[Claude Hooks]] for the hook surface and [[Audit Disposition and Debt Drain]] for the marker lifecycle.
