---
type: dependency
status: active
package: '@playwright/test'
version: 1.61.0
role: e2e-testing
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, testing, e2e]
---

# Playwright

End-to-end testing. Tests live in `.playwright/e2e/*.spec.ts`. Config in `playwright.config.ts`.

## Architecture

E2E tests run against `pnpm dev` (localhost:5173). MSW's browser service worker is active in dev, so tests exercise the full React Router loader/action stack with MSW intercepting API calls; no separate mock server required.

Tests that mutate MSW in-memory state call `resetTestData()` from `test/mocks/database.ts` in `test.afterEach` to restore seed data between tests.

## Hydration helper

> [!key-insight] React Router SSR + Playwright timing
> Pages are rendered server-side first; Playwright sees them before JS hydrates. The `hydration()` helper in `.playwright/utils.ts` waits for `<meta name="hydrated" content="true">` before any interaction proceeds.

```ts
import {hydration} from '../utils';

await page.goto('/');
await hydration(page); // must come before any interaction
```

`hydration()` self-heals the cold dev-server race: the first browser hit of a route after a cold start triggers Vite's dep-optimize mid-flight, which can fail the dynamic import of `entry.client.tsx` so the page never hydrates. The helper probes briefly for the hydrated meta; on a cold miss it reloads once onto the now-optimized bundle and waits with a generous window. On a warm server it returns within the probe and skips the reload.

A `globalSetup` (`playwright.config.ts` → `.playwright/global-setup.ts`) fires a serial `/` navigation after the dev server boots, front-loading the initial dep-optimize before the parallel specs race for it. Together these two mechanisms eliminate the need for local retries: `retries: 0` locally, `retries: 2` in CI as general flake insurance.

## Selectors

Prefer ARIA roles and accessible names; fall back to `page.locator()` with text/attribute filters. Never use CSS class selectors or XPath. See `.claude/rules/playwright.md` for examples.

## Locale and language tests

Set locale and `Accept-Language` per `test.describe` block, not globally. See `.claude/rules/playwright.md` and `language-switch.spec.ts` for the canonical pattern.

## Auth / session setup

When a project requires authentication, use a global setup file (`auth.setup.ts`) that logs in once and saves Playwright storage state. Configure it as a `setup` project dependency so authenticated specs reuse the session. Tests that must start unauthenticated call `await page.context().clearCookies()` explicitly.

## Parallelism and CI

`fullyParallel: true`; CI uses `workers: 1`, `retries: 2`. Locally, `retries: 0`: the global-setup warm-up and the `hydration()` probe-then-reload self-heal the cold dep-optimize race, so a real flake fails instead of being masked. Multi-browser (webkit, Firefox, mobile) is opt-in via `TEST_ALL_BROWSERS`. See `.claude/rules/playwright.md` for the full table.

## Traces and screenshots

`trace: 'retain-on-failure'`: traces saved to `.playwright/output/` on test failure. Use the Playwright trace viewer (`pnpm exec playwright show-trace`) to inspect. No manual screenshot calls in specs.

## Scripts

```
pnpm pw                # headless run
pnpm pw-ui             # interactive UI mode
pnpm install:browsers  # provision browsers + OS deps (run once locally)
```

## Companion packages

- `@playwright-testing-library/test`
- Playwright lint rules come from `eslint-plugin-playwright`, supplied transitively by the shared `@gaia-react/lint` config (spread as `...lint.playwright` in `eslint.config.mjs`) rather than declared directly here.
- `pnpm install:browsers` runs `playwright install --with-deps` to provision browsers; local developers run it on demand and CI runs it in a dedicated workflow step
