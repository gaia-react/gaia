---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-03
tags: [concept, ci, quality]
---

# Pre-commit Hooks

GAIA runs ESLint, Prettier, Stylelint, and Vitest on staged files before every commit via [[Husky]] + `lint-staged`. Full setup details in [[Husky]].

The hook decides which package a staged path belongs to from the registry and descriptors in [[Package Descriptor]], and refuses to commit when that registry cannot be read.

See [[Quality Gate]], [[Test Runner]].
