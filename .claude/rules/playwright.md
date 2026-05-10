---
paths:
  - '.playwright/**/*'
  - 'playwright.config.*'
---

# Playwright E2E Conventions

## File locations

- Config: `playwright.config.ts` (repo root)
- Specs: `.playwright/e2e/*.spec.ts`
- Shared helpers: `.playwright/utils.ts`
- Output/traces: `.playwright/output/` (gitignored)

## Scripts

```
pnpm pw         # run all e2e tests (headless)
pnpm pw-ui      # run with Playwright UI (interactive)
```

## Spec file naming

Match the feature or route: `language-switch.spec.ts`, `things.spec.ts`.
One spec file per major user flow; one `test.describe` block per scenario group.

## Selectors — prefer semantic over structural

Use ARIA roles and accessible names first:

```ts
page.getByRole('button', {name: 'Save'});
page.getByRole('link', {name: 'Create'});
page.getByRole('textbox', {name: 'Name'});
```

Fall back to `page.locator()` with meaningful attributes only when role queries are insufficient:

```ts
page.locator('select', {hasText: 'English'});
```

Do **not** use CSS class selectors or XPath.

## Waiting — web-first assertions only

Never use `page.waitForTimeout`. Use `expect(locator).toBeVisible()` or any
web-first `expect` assertion; Playwright retries until timeout.

## Hydration barrier

React Router 7 SSR renders before JS hydrates. Call the hydration helper
**before** any interaction:

```ts
import {hydration} from '../utils';

await page.goto('/');
await hydration(page); // waits for <meta name="hydrated" content="true">
```

## MSW + real dev server

E2E tests run against `pnpm dev` (localhost:5173). MSW browser worker is
active in dev, so tests exercise the real route/loader/action stack with MSW
intercepting API calls. No separate mock server is needed for e2e.

For tests that mutate MSW in-memory data, call `resetTestData()` in
`test.afterEach` to restore seed state:

```ts
import {resetTestData} from 'test/mocks/database';

test.afterEach(() => {
  resetTestData();
});
```

## Auth / session setup

When a project has authentication, use a Playwright global setup file
(`auth.setup.ts`) that logs in once and saves storage state; configure it as a
`setup` project dependency so authenticated specs reuse the session without
re-logging in per test. Clear cookies explicitly in tests that must start
unauthenticated:

```ts
await page.context().clearCookies();
```

## Locale / language

Set locale and Accept-Language headers at the test level, not globally:

```ts
test.use({locale: 'ja'});
// …
await page.setExtraHTTPHeaders({'Accept-Language': 'ja'});
```

## Parallelism and CI

- `fullyParallel: true` — all specs run in parallel by default.
- CI: `workers: 1`, `retries: 2`, `forbidOnly: true`.
- Locally: unlimited workers, no retries, multi-browser opt-in via `TEST_ALL_BROWSERS`.
- Primary browser: Chromium only by default. Other browsers (webkit, firefox, mobile) guarded behind `TEST_ALL_BROWSERS` flag.

## Traces and screenshots

- `trace: 'retain-on-failure'` — traces saved to `.playwright/output/` on failure.
- No explicit screenshot calls in specs; rely on Playwright trace viewer for debugging.
