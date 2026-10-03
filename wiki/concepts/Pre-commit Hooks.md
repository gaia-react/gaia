---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-03
tags: [concept, ci, quality]
---

# Pre-commit Hooks

GAIA runs ESLint, Prettier, Stylelint, and Vitest on staged files before every commit through a native git hook that calls [[lint-staged]].

## The hook

The hook is `.githooks/pre-commit`: executable, POSIX `sh`. Git runs it directly through `core.hooksPath`. The hook arms `set -e` itself and puts the workspace `node_modules/.bin` on `PATH`, so it does not depend on the invoking shell.

`pnpm install` runs the root `prepare` script, which sets `core.hooksPath` to `.githooks` in the clone's local git config. `prepare` does nothing when `CI` is set or when the package directory has no `.git` of its own (a Docker build, an extracted tarball, or a GAIA directory nested inside another repository, whose config it leaves alone).

Any non-empty `CI`, including `CI=false` or `CI=0`, skips hook setup. A shell that exports `CI=false` gets no hook until it runs `git config core.hooksPath .githooks`.

## What it runs

The hook decides which package a staged path belongs to from the registry and descriptors in [[Package Descriptor]], and refuses to commit when that registry cannot be read. For each affected package it runs typecheck, lint-staged, and `test:lint-staged`. It also guards generated settings drift, retired root frontend paths, and duplicate react-doctor configs. The hook file is the source of truth for the arms.

## Repairing a clone

A clone whose hook does not run reports nothing. Check `git config --get core.hooksPath`: it must print `.githooks`. If it does not, run `pnpm install` or `git config core.hooksPath .githooks`.

See [[Quality Gate]], [[Test Runner]].
