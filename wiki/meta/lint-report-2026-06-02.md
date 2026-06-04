---
type: meta
title: 'Lint Report 2026-06-02'
created: 2026-06-02
updated: 2026-06-02
tags: [meta, lint]
status: developing
---

# Lint Report: 2026-06-02

## #11: Wiki drift check

⚠ `wiki/.state.json` `last_evaluated_sha` (`3bca3f6`) is not reachable from HEAD (squashed/rewritten history). Run `/gaia wiki sync`: it resolves a recovery baseline (`6eae9e2`) and evaluates the un-evaluated window.

## #12: Dead repo-relative paths

✓ No dead repo-relative paths detected in wiki body prose.

## #13: UAT/SPEC narrative-ref drift

✓ No narrative `UAT-NNN` or concrete maintainer `SPEC-NNN` references detected outside the structural exemptions in `.claude/rules/wiki-style.md`.
