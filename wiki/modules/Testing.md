---
type: module
path: test/, .playwright/
status: active
language: typescript
purpose: Four-layer testing setup: unit, integration, E2E, visual regression
depends_on:
  - '[[Vitest]]'
  - '[[React Testing Library]]'
  - '[[Playwright]]'
  - '[[Chromatic]]'
  - '[[MSW]]'
created: 2026-04-20
updated: 2026-06-24
tags: [module, testing]
---

# Testing

GAIA ships **four layers** of testing, all sharing a common [[MSW Handlers|MSW]] mocking layer:

- Unit: [[Vitest]] in `app/utils/tests/`, `app/hooks/tests/`
- Integration: Vitest + [[React Testing Library]] in `app/components/*/tests/`, `app/pages/*/tests/`
- E2E: [[Playwright]] in `.playwright/e2e/*.spec.ts`
- Visual regression: [[Chromatic]] (CI only), driven by Storybook stories

The `composeStory` pattern means integration tests and visual regression share one source of truth. See [[Component Testing]].

## Vitest

Config at `vitest.config.ts`. Looks for `*.test.{ts,tsx}` anywhere in `app/`. Runs against `happy-dom`.

> [!warning] Never run bare `pnpm test` in CI
> Bare `pnpm test` enters watch mode and never exits. Use `pnpm test --run`. See [[Test Runner]].

## Component test pattern

Always use Storybook stories with `composeStory`. Never manually mock framework deps (`react-router`, `react-i18next`, etc.). See [[Component Testing]] for the canonical pattern.

## Playwright

- Tests in `.playwright/e2e/*.spec.ts`, config in `playwright.config.ts`
- Use the bundled `hydration(page)` helper after `page.goto()` to wait for React Router hydration before interacting

### a11y scanning

The shipped e2e specs are axe-core a11y scans. `.playwright/a11y.ts` exports `expectNoSeriousA11yViolations(page, testInfo, options?)`: critical and serious violations fail the test; moderate and minor violations attach as an `axe-advisory.json` and surface via `console.warn`. `.playwright/fixtures.ts` exposes the `makeAxeBuilder` fixture (WCAG 2.0/2.1 A and AA tags) for custom scans.

### Cold-start hydration self-heal

`playwright.config.ts` wires `globalSetup: './.playwright/global-setup.ts'`, a serial `/` navigation that warms Vite's cold dep-optimize cache before the parallel specs run. Local retries are 0 (2 on CI) by design, so the `hydration(page)` helper's probe-then-reload self-heals the cold dep-optimize race rather than masking real flakes. The first `pnpm pw` after a dependency or Vite-config change boots a cold cache and can lose the race on the dynamic import of `entry.client.tsx`.

## Chromatic

- Visual regression on every PR
- `pnpm chromatic` (run in CI), `CHROMATIC_PROJECT_TOKEN` env var on CI
- See [[Chromatic Opt-Out]] if you want to remove it

## ESLint rules on test files

Test files (`**/*.test.ts?(x)`) enforce two additional plugin configs that change how tests are written:

- `eslint-plugin-testing-library`: prefer `screen` queries, `await` all `userEvent` calls, no `act()` wrappers, no manual cleanup
- `eslint-plugin-jest-dom`: prefer jest-dom matchers (`toHaveValue`, `toBeChecked`, `toHaveTextContent`) over raw DOM property checks

See [[ESLint Fixes]] for fix patterns.

## Pre-commit

The pre-commit hook runs `pnpm typecheck`, `pnpm exec lint-staged` (eslint, prettier, stylelint), then `pnpm test:lint-staged` (`vitest --run --changed --passWithNoTests --bail 1`) as a separate step, so only tests affected by the staged changes run. See [[Quality Gate]].

For the current `test/` folder inventory and helper signatures, query Serena (`.claude/rules/code-search.md`).
