---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-24
tags: [concept, testing]
---

# Test Runner Rule

The `test` script is plain `vitest`. Vitest only enters watch mode when it detects an interactive TTY; without one, as when Claude or CI runs it, a bare `pnpm test` / `pnpm run test` runs once and exits. Use `pnpm test --run` for an explicit single CI-style pass, and at an interactive terminal to avoid entering watch mode. The one-shot scripts are `test:ci` (`vitest --run --passWithNoTests --coverage --bail 1`) and `test:lint-staged` (`vitest --run --changed --passWithNoTests --bail 1`).

See [[Vitest]], [[Pre-commit Hooks]], [[Claude Hooks]].
