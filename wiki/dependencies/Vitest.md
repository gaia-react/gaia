---
type: dependency
status: active
package: vitest
version: 4.1.9
role: test-runner
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, testing]
---

# Vitest

Test runner for unit + integration tests. Paired with `happy-dom` and [[React Testing Library]].

## Companion packages

- `@vitest/coverage-v8`: coverage reports (direct devDependency)

Vitest-aware lint rules come from `@vitest/eslint-plugin`, which the shared `@gaia-react/lint` config pulls in transitively; this repo does not declare it directly.

## Conventions

- `*.test.{ts,tsx}` anywhere in `app/`
- Tests live in `tests/` subfolders next to components/pages/hooks
- Explicit imports in every test file: `import {describe, expect, test} from 'vitest'`
- `globals: true` in `vitest.config.ts` enables Testing Library's auto-cleanup between tests; it does not replace the explicit imports. Keep `vitest/globals` out of `tsconfig.json` types: a hook blocks it, and the explicit imports are what type-check
- `vitest.config.ts` runs tests under `environment: 'happy-dom'` with `setupFiles: ['./test/setup.ts']`. `test/setup.ts` registers Storybook project annotations, imports jest-dom matchers, loads `test.server`, and supplies fallback env vars (`API_URL`, `SESSION_SECRET`, `SITE_URL`) so server modules parse in clean environments. Add new global matchers or env defaults there

## Run rules

> [!warning] Never run bare `pnpm test` in CI
> Bare `pnpm test` starts watch mode. Use `pnpm test --run` for CI-style. See [[Test Runner]] rule.

See [[Testing]], [[Component Testing]].
