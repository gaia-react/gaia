---
type: dependency
status: active
package: 'husky, lint-staged, is-ci'
version: '9.1.7, 17.0.0'
role: pre-commit
created: 2026-04-20
updated: 2026-04-20
tags: [dependency, ci]
---

# Husky + lint-staged

Pre-commit hooks. Configured by `pnpm prepare` (skipped in CI via `is-ci`).

`.lintstagedrc.json` runs `typecheck`, `lint`, and `vitest --run --changed --bail 1` against staged files.

> [!key-insight] Tests on commit, not just lint
> GAIA runs **`vitest --run --changed`** in lint-staged. Most setups skip this because it's slow; GAIA accepts the cost because it catches regressions before they reach CI.

See [[Quality Gate]].
