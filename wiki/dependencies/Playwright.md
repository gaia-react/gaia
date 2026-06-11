---
type: dependency
status: active
package: '@playwright/test'
version: 1.59.1
role: e2e-testing
created: 2026-04-20
updated: 2026-06-11
tags: [dependency, testing, e2e]
---

# Playwright

End-to-end testing. Tests live in `.playwright/e2e/*.spec.ts`. Config in `playwright.config.ts`.

## Architecture

E2E tests run against `pnpm dev` (localhost:5173). MSW's browser service worker is active in dev, so tests exercise the full React Router loader/action stack with MSW intercepting API calls; no separate mock server required.

Tests that mutate MSW in-memory state call `resetTestData()` from `test/mocks/database.ts` in `test.afterEach` to restore seed data between tests.

## Hydration helper

> [!key-insight] React Router 7 SSR + Playwright timing
> Pages are rendered server-side first; Playwright sees them before JS hydrates. The `hydration()` helper in `.playwright/utils.ts` waits for `<meta name="hydrated" content="true">` before any interaction proceeds.

```ts
import {hydration} from '../utils';

await page.goto('/');
await hydration(page); // must come before any interaction
```

## Selectors

Prefer ARIA roles and accessible names; fall back to `page.locator()` with text/attribute filters. Never use CSS class selectors or XPath. See `.claude/rules/playwright.md` for examples.

## Locale and language tests

Set locale and `Accept-Language` per `test.describe` block, not globally. See `.claude/rules/playwright.md` and `language-switch.spec.ts` for the canonical pattern.

## Auth / session setup

When a project requires authentication, use a global setup file (`auth.setup.ts`) that logs in once and saves Playwright storage state. Configure it as a `setup` project dependency so authenticated specs reuse the session. Tests that must start unauthenticated call `await page.context().clearCookies()` explicitly.

## Parallelism and CI

`fullyParallel: true`; CI uses `workers: 1`, `retries: 2`. Locally, `retries: 1`: the first run after a dependency or `vite.config` change boots the dev server with a cold Vite dep-optimize cache, which can fail the dynamic import of `entry.client.tsx` before hydration completes; the retry runs against the now-warm server. A genuine failure still fails on both attempts. Multi-browser (webkit, Firefox, mobile) is opt-in via `TEST_ALL_BROWSERS`. See `.claude/rules/playwright.md` for the full table.

## Traces and screenshots

`trace: 'retain-on-failure'`: traces saved to `.playwright/output/` on test failure. Use the Playwright trace viewer (`pnpm exec playwright show-trace`) to inspect. No manual screenshot calls in specs.

## Scripts

```
pnpm pw        # headless run
pnpm pw-ui     # interactive UI mode
```

## Companion packages

- `@playwright-testing-library/test`
- `eslint-plugin-playwright`
- `playwright install --with-deps` runs in `pnpm prepare` (Husky)
