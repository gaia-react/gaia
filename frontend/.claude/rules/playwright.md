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

React Router SSR renders before JS hydrates. Call the hydration helper
**before** any interaction:

```ts
import {hydration} from '../utils';

await page.goto('/');
await hydration(page); // waits for <meta name="hydrated" content="true">
```

## MSW + real dev server

E2E tests run against this tree's `pnpm dev` server, on the port
`bash .gaia/scripts/ports.sh` prints (5173 in the main checkout). Playwright
refuses to reuse a server on that port that is not this tree's own. A second
`webServer` serves the built `storybook-static` on this tree's Storybook port for
the story scan (see Accessibility scans). MSW browser
worker is active in dev, so tests exercise the real route/loader/action stack with MSW
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

GAIA's `playwright.config.ts` ships these defaults:

- `fullyParallel: true`, all specs run in parallel by default.
- CI: `workers: '100%'` (one per core), `retries: 2`, `forbidOnly: true`.
- Locally: Playwright default workers (half the cores), no retries, multi-browser opt-in via `TEST_ALL_BROWSERS`.
- Primary browser: Chromium only by default. Other browsers (webkit, firefox, mobile) guarded behind `TEST_ALL_BROWSERS` flag.

## Traces

- `trace: 'retain-on-failure'`, traces saved to `.playwright/output/` on failure.
- Use the trace viewer for debugging.

## Accessibility scans

The Storybook scan (`storybook-a11y.spec.ts`, `storybook-focus.spec.ts`) runs axe over every story in dark and checks focus visibility in light and dark, against `storybook-static`. `pnpm pw` does not build Storybook: run `pnpm build-storybook` first (about 2 seconds). The story server starts even with no build so the other specs run; the story spec fails, never skips, naming `pnpm build-storybook` when `storybook-static/index.json` is missing or its story count differs from the story exports in source. The light theme is not scanned per story here: the Vitest storybook project runs addon-a11y on every story in light, failing on any impact.

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
