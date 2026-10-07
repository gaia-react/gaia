---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-05
tags: [concept, ci, quality]
---

# Pre-commit Hooks

GAIA runs ESLint, Prettier, Stylelint, and Vitest on staged files before every commit through a native git hook that calls [[lint-staged]]. The Vitest step launches headless Chromium for stories and hook tests, so `pnpm install:browsers` is a prerequisite ([[Testing]]).

## The hook

The hook is `.githooks/pre-commit`: executable, POSIX `sh`. Git runs it directly through `core.hooksPath`. The hook arms `set -e` itself and puts the workspace `node_modules/.bin` on `PATH`, so it does not depend on the invoking shell.

`pnpm install` runs the root `prepare` script, which sets `core.hooksPath` to `.githooks` in the clone's local git config. `prepare` does nothing when `CI` is set or when the package directory has no `.git` of its own (a Docker build, an extracted tarball, or a GAIA directory nested inside another repository, whose config it leaves alone).

Any non-empty `CI`, including `CI=false` or `CI=0`, skips hook setup. A shell that exports `CI=false` gets no hook until it runs `git config core.hooksPath .githooks`.

## What it runs

The hook decides which package a staged path belongs to from the registry and descriptors in [[Package Descriptor]], and refuses to commit when that registry cannot be read. For each affected package it runs typecheck, lint-staged, and `test:lint-staged`. It also guards generated settings drift, retired root frontend paths, and duplicate react-doctor configs. The hook file is the source of truth for the arms.
<!-- gaia:maintainer-only:start -->

## The pre-push hook

`.githooks/pre-push` runs on branch pushes only, through the same `core.hooksPath`. It hands the pushed commits to the verification runner's `push` mode (`.gaia/tests/verify-harness.sh`), which runs the distribution checks and nothing else; the runner's header names them. Tag pushes and ref deletions exit at once, and a push that mixes a tag with a branch verifies the branch.

It verifies the pushed commit, not the working tree: a pushed sha that is not the clean HEAD is checked out in a temporary detached worktree. A failure that also fails on the merge base with `origin/main` prints as pre-existing and lets the push through. A missing tool or a missing runner fails open with a warning, leaving CI as the remaining check. `git push --no-verify` is the only bypass.

A branch or worktree cut before the hook landed has no pre-push hook until it merges main, because the relative `core.hooksPath=.githooks` reads the checkout's own `.githooks/`.

<!-- gaia:maintainer-only:end -->

## Repairing a clone

A clone whose hook does not run reports nothing. Check `git config --get core.hooksPath`: it must print `.githooks`. If it does not, run `pnpm install` or `git config core.hooksPath .githooks`.

See [[Quality Gate]], [[Test Runner]].
