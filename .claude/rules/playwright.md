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

## Selectors, prefer semantic over structural

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

## Waiting, web-first assertions only

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

## Asserting on errors, watch both channels

React reports its failures through two separate channels, and a spec that
watches only one silently guards nothing. An attribute mismatch is a direct
`console.error`, but a throw-path failure (`Hydration failed because the
server rendered…`) goes through `window.reportError`, which Chromium delivers
to Playwright's `pageerror` event and never to the console.

Collect both and assert on the union:

```ts
const errors: string[] = [];

page.on('console', (message) => {
  if (message.type() === 'error') {
    errors.push(message.text());
  }
});
page.on('pageerror', (error) => {
  errors.push(error.message);
});

// Absorb the cold dev-server race, then assert on a second, clean load.
await page.goto('/');
await hydration(page);

errors.length = 0;

await page.reload();
const selfHealed = await hydration(page);

expect(selfHealed).toBe(false);
expect(errors).toEqual([]);
```

Once both channels are watched, filtering by message text is unnecessary and
costs coverage: any error during a page load is a failure. The split applies
to every uncaught runtime error, not only hydration.

**Reset the collector before the load you assert on, then prove that load was
clean.** `hydration()` self-heals a cold dev server by calling `page.reload()`,
listeners registered on the `Page` survive that reload, and the requests that
lost the race push errors that say nothing about the app. Asserting on the
first load makes a successful self-heal fail the test. Resetting alone only
moves the exposure, because the asserted load can self-heal too, so
`hydration()` returns whether it did: assert it did not, and a recovered load
fails on that fact instead of on the noise it produced.
`.playwright/e2e/hydration.spec.ts` is the worked example.

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

- `fullyParallel: true`, all specs run in parallel by default.
- CI: `workers: 1`, `retries: 2`, `forbidOnly: true`.
- Locally: unlimited workers, no retries, multi-browser opt-in via `TEST_ALL_BROWSERS`.
- Primary browser: Chromium only by default. Other browsers (webkit, firefox, mobile) guarded behind `TEST_ALL_BROWSERS` flag.

## Traces and screenshots

- `trace: 'retain-on-failure'`, traces saved to `.playwright/output/` on failure.
- No explicit screenshot calls in specs; rely on Playwright trace viewer for debugging.

## Accessibility scans

Use `expectNoSeriousA11yViolations` from `.playwright/a11y.ts` for axe-core
scans of fully-rendered pages. The fixture in `.playwright/fixtures.ts`
exposes `makeAxeBuilder` for tests that need to customize tags, includes, or
disabled rules. Failure threshold is frozen: critical + serious violations
fail the test; moderate + minor violations attach as `axe-advisory.json` and
emit `console.warn`.

```ts
import {test} from '../fixtures';
import {expectNoSeriousA11yViolations} from '../a11y';
import {hydration} from '../utils';

test('home page has no serious a11y violations', async ({page}, testInfo) => {
  await page.goto('/');
  await hydration(page);
  await expectNoSeriousA11yViolations(page, testInfo);
});
```
