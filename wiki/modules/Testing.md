---
type: module
path: test/, .playwright/
status: active
language: typescript
purpose: Four-layer testing setup — unit, integration, E2E, visual regression
depends_on: [[Vitest]], [[React Testing Library]], [[Playwright]], [[Chromatic]], [[MSW]]
created: 2026-04-20
updated: 2026-04-27
tags: [module, testing]
---

# Testing

GAIA ships **four layers** of testing, all sharing a common [[MSW Handlers|MSW]] mocking layer.

| Layer             | Tool                               | Where                                           |
| ----------------- | ---------------------------------- | ----------------------------------------------- |
| Unit              | [[Vitest]]                         | `app/utils/tests/`, `app/hooks/tests/`          |
| Integration       | Vitest + [[React Testing Library]] | `app/components/*/tests/`, `app/pages/*/tests/` |
| E2E               | [[Playwright]]                     | `.playwright/e2e/*.spec.ts`                     |
| Visual regression | [[Chromatic]] (CI only)            | Storybook stories                               |

## Vitest config

- `vitest.config.ts` at root
- Looks for `*.test.{ts,tsx}` anywhere in `app/`
- Runs against `happy-dom`
- See [[Test Runner]] rule: never run bare `pnpm test` in CI; use `pnpm test --run`

## test/ folder

| File             | Purpose                                                                          |
| ---------------- | -------------------------------------------------------------------------------- |
| `mocks/`         | MSW handlers + `@msw/data` collections — see [[MSW Handlers]] for full structure |
| `stubs/`         | Storybook decorators (`reactRouter()`, `state()`)                                |
| `msw.server.ts`  | MSW server entry used by `entry.server.tsx` when `MSW_ENABLED=true`              |
| `rtl.tsx`        | RTL setup with i18n strings + auto-cleanup                                       |
| `setup.ts`       | Vitest setup file                                                                |
| `test.server.ts` | MSW server for Vitest                                                            |
| `utils.ts`       | Test helpers (delay, date generators)                                            |
| `worker.ts`      | MSW browser worker handlers                                                      |

## Component test pattern

Always use Storybook stories with `composeStory`. Never manually mock framework deps. See [[Component Testing]] for the pattern.

## Playwright

- Tests in `.playwright/e2e/*.spec.ts`
- Config in `playwright.config.ts`
- Use the bundled `hydration(page)` helper after `page.goto()` to wait for React Router hydration before interacting
- Sample tests: `language-switch.spec.ts`

## Chromatic

- Visual regression on every PR
- `pnpm chromatic` (run in CI)
- `CHROMATIC_PROJECT_TOKEN` env var on CI
- See [[Chromatic Opt-Out]] if you want to remove it

## ESLint rules on test files

Test files (`**/*.test.ts?(x)`) enforce two additional plugin configs:

| Plugin                          | Config             | Rules                                                                                                                      |
| ------------------------------- | ------------------ | -------------------------------------------------------------------------------------------------------------------------- |
| `eslint-plugin-testing-library` | `flat/react`       | 22 rules — prefer `screen` queries, `await` all `userEvent` calls, no `act()` wrappers, no manual cleanup, etc.            |
| `eslint-plugin-jest-dom`        | `flat/recommended` | 11 rules — prefer jest-dom matchers (`toHaveValue`, `toBeChecked`, `toHaveTextContent`, etc.) over raw DOM property checks |

See [[ESLint Fixes]] for fix patterns.

## Pre-commit

- `lint-staged` runs `vitest --run --changed` (only files affected by the staged changes)
- See [[Quality Gate]]
