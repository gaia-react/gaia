<!--
CACHE DISCIPLINE — enforced on every rewrite (Stop hook):
  - Max ~200 words total
  - Purpose: "where did we leave off?" — the current state of the work
  - Include: current branch / milestone, last-shipped thing, recent wiki changes, active threads
  - If a fact appears here twice across sessions, move it to the right wiki page and delete it from this cache
  - It is a cache, not a journal. Overwrite completely each update.
-->

---

type: meta
title: Hot Cache
status: active
created: 2026-04-20
updated: 2026-04-30
tags: [meta]

---

# Recent Context

## Last Updated

2026-04-30. Release-prep audit complete on `main`.

## Key Facts

- Rules/skills rebalance: `eslint-fixes` rule → skill; `component-testing` rule retired (Conform/`useInputControl` content moved to `tdd` references); `api-service` rule slimmed to a wiki pointer.
- New safeguard hooks: `block-rm-rf`, `block-secrets-write`, `block-env-write`, `block-lockfile-edit`. `block-main-destructive-git` now denies plain `git push` from main/master too. New `wiki-update-evaluator` PostToolUse hook autonomously triages each commit via a backgrounded `claude -p` sub-agent; output folds into the standard wiki branch flow.
- `.claude/settings.json`: permissions `allow` 21 → 52, `deny` 5 → 13; leading-slash glob bug fixed.
- Dockerfile + husky + playwright.config now pnpm-native.

## Recent Changes

- Updated: [[Claude Hooks]], [[Claude Skills]], [[Claude Integration Conventions]], [[Code Review Audit Agent]], [[Quality Gate]], [[index]], [[log]].

## Active Threads

- Release-prep plan folder gets self-deleted by orchestrator (Phase 5; gitignored).
