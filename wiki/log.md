---
type: meta
title: Log
status: active
created: 2026-06-12
updated: 2026-06-12
tags: [meta, log]
---

# Log

## [Unreleased]

- `/update-deps` override audit re-resolves with `pnpm dedupe`, not `pnpm install` (which short-circuits "Already up to date" on an overrides-only change and leaves a security floor unapplied), and now asserts the lockfile `overrides:` block matches `pnpm-workspace.yaml` before finishing. New page [[pnpm-overrides]] documents the gotcha; [[pnpm-audit]] and [[pnpm]] cross-link it.

## [v1.6.1] 2026-06-12 | Released

See CHANGELOG.md for details.
