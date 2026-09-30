---
type: concept
status: active
created: 2026-07-01
updated: 2026-08-02
tags: [concept, claude, hooks]
---

# Local Working State

`.gaia/local/` holds machine-local working state for GAIA's subsystems. It is gitignored in full, carries no tracked files, and is absent from `.gaia/manifest.json`, so nothing under it is committed or shipped to adopters. Each developer's copy is private to their machine, and subsystems create the subdirectories they need on demand (`mkdir -p`).

Because the folder is invisible to git, residue a subsystem leaves behind never surfaces in a diff and accumulates silently. Each subsystem owns pruning its own residue; the state registry records who writes and who reaps each entry, so a reader can tell live state from leftovers.

## Layout

`.gaia/state-registry.json` is the entry-by-entry list of `.gaia/local/`: each entry's path, scope (`shared`, `per-tree`, `main-only`, `ephemeral`), reason, writer, and reaper, plus known residue from removed features.

A linked worktree's `.gaia/local` is a single symlink to the main checkout's `.gaia/local`, so every registry entry resolves to one copy rather than forking per tree. `.gaia/state-registry.json` declares each entry's scope, and an entry that has to stay private to one tree gets that isolation from a tree key in its own path rather than from a directory of its own; see [[Worktrees]]. The same linking covers a second, disjoint set: the checkout-root gitignored `.env` / `.env.*` files (every basename matching `.env` or `.env.*`, excluding the committed `.env.example`). Each linked worktree gets `<worktree>/.env` (and any `.env.*`) symlinked to the main checkout's copy, so the worktree's `pnpm dev` and Playwright runs read the same local secrets without a manual copy. These files live at the checkout root, not under `.gaia/local/`, so they aren't registry entries.

An `ephemeral` entry is consumed once and then orphaned; its owner is meant to prune it, and most such entries have no other backstop if the owner doesn't.

## The session-start janitor

`.claude/hooks/local-janitor.sh` runs from the SessionStart hook (`wiki-session-start.sh`) on `startup` and `resume`. It is the side-effect form of a SessionStart hook: it acts on disk and injects nothing into context. It is runnable directly for testing as well (`bash .claude/hooks/local-janitor.sh`).

It runs the wiki-landing local catch-up: the wiki landing CLI (`gaia wiki chain finish` / `wiki sync land`) cuts a throwaway `wiki-sync/<date>-<sha>` branch and enables auto-merge with `gh pr merge --auto`, then takes one bounded in-CLI wait. The merge gate routinely outlasts any wait that fits in a single invocation, so on the common path the CLI returns with the local branch still present and the local base branch still behind. This catch-up covers both, in four steps. First an existence gate: nothing below runs unless a local `wiki-sync/*` branch is present, so an ordinary session pays nothing. Then a bounded, rate-limited `git fetch --prune` of `origin`, capped by `GAIA_WIKI_FETCH_TIMEOUT_SECONDS` (default 5 seconds, floor 1, ceiling 30; `0` disables the fetch outright) and rate-limited by `GAIA_WIKI_FETCH_MIN_INTERVAL_MINUTES` (default 60, floor 5; `0` removes the rate limit rather than disabling anything). Refs and the object store are shared across every linked worktree, so this fetch's effect is repo-global: a worktree-invoked run updates tracking refs every tree observes. Then a guarded reap of each `wiki-sync/*` branch whose upstream now reads `[gone]`. `[gone]` is not proof of a merge, only that the remote head ref is absent, and a PR closed without merging and then branch-deleted reads identically; so the reap refuses any branch carrying work no remote-tracking ref has, tested by patch id with `git cherry` (the only test that can tell a squash-merged branch from an abandoned one, since a squash leaves the tip unreachable by ancestry either way), and hard-deletes the rest with `git branch -D`. Finally a `--ff-only` fast-forward of the base branch to `origin/<base>`, so the landing's own commit is actually present locally. That step makes no network call of its own and is gated on HEAD being on base, a clean working tree, base having an upstream, and the fetch not having been left in an unknown state; its safety comes from `--ff-only` against base's own upstream, which can only advance base to a commit the remote already has, and it is a checkout-aware merge rather than a bare ref write. The catch-up obligation is durable: a session that cannot complete the fast-forward records it in `.gaia/local/cache/shared/wiki-base-catchup.state` and a later qualifying session retries with no new landing required, and because the obligation is one idempotent fact it collapses to at most one file however many landings occur. A fast-forward that a gate declines is a silent skip leaving base byte-identical; one that is attempted and fails writes a single line to `.gaia/local/cache/shared/wiki-base-catchup.report`, which the drift-check hook drains into the conversation on the next prompt. This catch-up is git-scoped, independent of `.gaia/local/`, so a fresh clone can carry an orphaned branch before that directory exists.

The hook is fail-safe throughout. Every gate is cheap and local, `--ff-only` against base's own upstream can only advance base to a commit the remote already has, a failing gate is a silent skip leaving the index and working tree untouched, and an attempt that was made and failed is reported rather than swallowed. It always exits 0, so it can never block a session from starting.

## Deciding by hand

Anything under `.gaia/local/` is safe to delete once its owner is done with it: a spent audit marker for an already-merged PR, a plan directory for a merged or abandoned branch, a `KNOWLEDGE-*.md` report already applied, a gate cache for a merged spec. The append-only ledgers (`red-ledger/observations.jsonl`, `worthiness-ledger/worthiness.jsonl`, `telemetry`), the identity files (`.project-id`, `setup-state.json`), and `.gaia/local/specs/ledger.json` (and the `specs/` store it lives in) are the load-bearing exceptions; deleting the ledger drops per-machine draft-resume state and the local half of SPEC-number allocation.

`.gaia/local/research/` is where GAIA looks for research; a write there binds the session's spend to it (see [[Usage Ledger]]). The state registry stays the source of truth for how each path is classified.

See [[Claude Hooks]] for the hook surface and [[Audit Disposition and Debt Fix]] for the marker lifecycle.
