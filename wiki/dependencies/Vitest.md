---
type: dependency
status: active
package: vitest
role: test-runner
created: 2026-04-20
updated: 2026-10-03
tags: [dependency, testing]
---

# Vitest

Test runner for unit + integration tests. Paired with `happy-dom` and [[React Testing Library]].

## Companion packages

- `@vitest/coverage-v8`: coverage reports (direct devDependency)

Vitest-aware lint rules come from `@vitest/eslint-plugin`, which the shared `@gaia-react/lint` config pulls in transitively; GAIA's `package.json` does not declare it directly.

## Conventions

- `*.test.{ts,tsx}` anywhere in `frontend/app/`
- Tests live in `tests/` subfolders next to components/pages/hooks
- Explicit imports in every test file: `import {describe, expect, test} from 'vitest'`
- `globals: true` in `frontend/vitest.config.ts` enables Testing Library's auto-cleanup between tests; it does not replace the explicit imports. Keep `vitest/globals` out of `frontend/tsconfig.json` types: the explicit imports are what type-check
- `frontend/vitest.config.ts` runs tests under `environment: 'happy-dom'` with `setupFiles: ['./test/setup.ts']`. `frontend/test/setup.ts` registers Storybook project annotations, imports jest-dom matchers, loads `test.server`, and supplies fallback env vars (see `frontend/test/setup.ts` for the current list) so server modules parse in clean environments. Add new global matchers or env defaults there

## Run rules

> [!info] Watch mode needs a TTY
> Vitest only enters watch mode with an interactive TTY; in CI or under Claude, a bare `pnpm test` runs once and exits. Use `pnpm test --run` for an explicit single pass, or at an interactive terminal to avoid watch mode. See [[Test Runner]] rule.

See [[Testing]], [[Component Testing]].
