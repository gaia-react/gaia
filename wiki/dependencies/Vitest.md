---
type: dependency
status: active
package: vitest
role: test-runner
created: 2026-04-20
updated: 2026-10-05
tags: [dependency, testing]
---

# Vitest

Test runner for unit tests and, through `@storybook/addon-vitest`, for the story play functions that test components and pages. Browser-mode projects run in headless Chromium via `@vitest/browser-playwright`; no DOM emulation is used. See [[Stories as Tests]].

## Companion packages

- `@vitest/coverage-v8`: coverage reports (direct devDependency)
- `@vitest/browser-playwright` and `vitest-browser-react`: the browser provider and the hook-test renderer for the `browser` project
- `@storybook/addon-vitest`: the `storybook` project's plugin, which turns every story into a test

Vitest-aware lint rules come from `@vitest/eslint-plugin`, which the shared `@gaia-react/lint` config pulls in transitively; GAIA's `package.json` does not declare it directly.

## Conventions

- `*.test.{ts,tsx}` for pure code, server code and hooks; component and page tests are stories (`*.stories.tsx`) with `play` functions
- Tests and stories live in `tests/` subfolders next to components/pages/hooks
- Explicit imports in every test file: `import {describe, expect, test} from 'vitest'`
- Keep `vitest/globals` out of `frontend/tsconfig.json` types: the explicit imports are what type-check
- `frontend/vitest.config.ts` defines three projects (`node`, `browser`, `storybook`); read it for membership and settings. `frontend/test/setup.ts` serves the `node` project: it loads `test.server`, resets test data after each test, and supplies fallback env vars (see the file for the current list) so server modules parse in clean environments. `frontend/test/setup.browser.ts` serves the `browser` project. The `storybook` project takes its setup from `.storybook/preview.ts`
- The browser projects need Chromium: run `pnpm install:browsers` once. See [[Testing]]

## Run rules

> [!info] Watch mode needs a TTY
> Vitest only enters watch mode with an interactive TTY; in CI or under Claude, a bare `pnpm test` runs once and exits. Use `pnpm test --run` for an explicit single pass, or at an interactive terminal to avoid watch mode. See [[Test Runner]] rule.

See [[Testing]], [[Component Testing]].

React Compiler runs in this pipeline; see [[React Compiler]].
