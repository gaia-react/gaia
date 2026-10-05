---
type: module
path: frontend/test/, frontend/.playwright/
status: active
language: typescript
purpose: Four-layer testing setup: unit, stories as component tests, E2E, visual regression
depends_on:
  - '[[Vitest]]'
  - '[[Storybook]]'
  - '[[Playwright]]'
  - '[[Chromatic]]'
  - '[[MSW]]'
created: 2026-04-20
updated: 2026-10-05
tags: [module, testing]
---

# Testing

Testing has **four layers**, all sharing a common [[MSW Handlers|MSW]] mocking layer:

- Unit: [[Vitest]] in `frontend/app/utils/tests/` (pure and server code), and `vitest-browser-react` tests for hooks
- Component and page: Storybook stories with `play` functions in `frontend/app/components/*/tests/`, `frontend/app/pages/*/tests/`, run by Vitest through `@storybook/addon-vitest`
- E2E: [[Playwright]] in `frontend/.playwright/e2e/*.spec.ts`
- Visual regression: [[Chromatic]] (CI only), driven by the same stories

A story is the component test and the visual-regression input, so both share one source of truth. See [[Stories as Tests]] and [[Component Testing]].

## Vitest

One config, `frontend/vitest.config.ts`, defines three projects: `node` for pure and server code, `browser` for hooks and any `*.test.tsx`, and `storybook` for every story. Read it for the exact membership. The `browser` and `storybook` projects run in headless Chromium; no project uses an emulated DOM.

> [!info] Watch mode needs a TTY
> Vitest only enters watch mode with an interactive TTY; in CI or under Claude, a bare `pnpm test` runs once and exits. Use `pnpm test --run` for an explicit single pass. See [[Test Runner]].

### Setup prerequisite

Run `pnpm install:browsers` once per machine. It installs every Playwright browser with its OS dependencies, which local `pnpm pw` uses too. Vitest's browser projects need Chromium from it; a missing browser fails the run with an install command rather than skipping the tests.

### Accessibility coverage

`@storybook/addon-a11y` axe-checks every story under Vitest, in the **light theme only**. The dark-theme check is `pnpm pw` (the Playwright story scan), so run it on any theme or token change. See [[Accessibility]].

## Component test pattern

Test a component or page with a story that has a `play` function. Never manually mock framework deps (`react-router`, `react-i18next`, etc.); use the stubs. See [[Stories as Tests]] and [[Component Testing]] for the canonical pattern.

## Playwright

- Tests in `frontend/.playwright/e2e/*.spec.ts`, config in `frontend/playwright.config.ts`
- Use the bundled `hydration(page)` helper after `page.goto()` to wait for React Router hydration before interacting

### a11y scanning

Most shipped e2e specs are axe-core a11y scans; others cover hydration errors and render-performance smoke. `frontend/.playwright/a11y.ts` exports `expectNoSeriousA11yViolations(page, testInfo, options?)`: critical and serious violations fail the test; moderate and minor violations attach as an `axe-advisory.json` and surface via `console.warn`. `frontend/.playwright/fixtures.ts` exposes the `makeAxeBuilder` fixture (WCAG 2.0/2.1 A and AA tags) for custom scans.

### Cold-start hydration self-heal

`frontend/playwright.config.ts` wires `globalSetup: './.playwright/global-setup.ts'`, a serial `/` navigation that warms Vite's cold dep-optimize cache before the parallel specs run. Local retries are 0 (2 on CI) by design, so the `hydration(page)` helper's probe-then-reload self-heals the cold dep-optimize race rather than masking real flakes. The first `pnpm pw` after a dependency or Vite-config change boots a cold cache and can lose the race on the dynamic import of `entry.client.tsx`.

## Chromatic

- Visual regression on every PR
- `pnpm chromatic` (run in CI), `CHROMATIC_PROJECT_TOKEN` env var on CI
- See [[Chromatic Opt-Out]] if you want to remove it

## ESLint rules on test files

Test files are linted by the `testing` preset of [[gaia-lint]] and stories by its `storybook` preset. See [[ESLint Fixes]] for fix patterns.

## Pre-commit

The pre-commit hook runs `pnpm typecheck`, `pnpm exec lint-staged` (eslint, prettier, stylelint), then `pnpm test:lint-staged` (`vitest --run --changed --passWithNoTests --bail 1`) as a separate step, so only tests affected by the staged changes run (browser projects included, so Chromium must be installed). See [[Quality Gate]].

For the current `frontend/test/` folder inventory and helper signatures, query Serena (`.claude/rules/code-search.md`).
