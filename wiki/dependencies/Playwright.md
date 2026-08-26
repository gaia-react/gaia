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
to every uncaught runtime error, not only hydration. In an app carrying
third-party scripts (analytics, a CSP reporter, anything an ad blocker
interferes with), scope the **collector** to same-origin or a named allowlist
rather than weakening the **assertion**; deleting the assertion gives back the
whole coverage this pattern buys. Scoping is asymmetric across the two
channels, so plan for both: a console message carries a structured
`message.location().url` and filters directly, while `pageerror` hands the
listener a bare `Error` whose only origin handle is the string in
`error.stack`. That stack stays readable even for a cross-origin script
loaded without CORS, because Playwright feeds `pageerror` from the
inspector's exception channel rather than the page's `error` event, so it
never sees the `Script error.` sanitization that blinds an in-page
`window.onerror`. Fail on an error whose stack will not parse rather than
dropping it; an unattributable error during a page load is exactly what the
broad assertion is for.

**Reset the collector before the load you assert on, then prove that load did
not self-heal.** `hydration()` self-heals a cold dev server by calling
`page.reload()`, listeners registered on the `Page` survive that reload, and
the requests that lost the race push errors that say nothing about the app.
Asserting on the first load makes a successful self-heal fail the test.
Resetting alone only moves the exposure, because the asserted load can
self-heal too, so `hydration()` returns whether it did: assert it did not, and
a recovered load fails on that fact instead of on the noise it produced.
`.playwright/e2e/hydration.spec.ts` is the worked example.

One residual remains, and it is worth knowing rather than discovering. The
flag describes the asserted load's own hydration probe; it is not a provenance
stamp on the collected errors. The previous document stays live with both
listeners attached until the reload commits, so anything it emits between the
reset and that moment lands in the collector while the flag is legitimately
`false`. The failure is directional: it can only produce a false failure
attributed to the wrong load, never a false pass with respect to the reset,
because a real error on the asserted load always lands after it. The other end
of the window holds too, at least for the hydration errors this spec targets:
React emits them before `useHydrated()` flips the meta tag `hydration()` waits
on, so the assertion runs after they have landed. Closing the gap needs
per-load provenance (tag each error with a generation counter bumped on
`framenavigated` for the main frame only, since it fires for subframes as
well), which is not worth doing until it actually flakes.

## Selectors

Prefer ARIA roles and accessible names; fall back to `page.locator()` with text/attribute filters. Never use CSS class selectors or XPath. See `.claude/rules/playwright.md` for examples.

## Locale and language tests

Set locale and `Accept-Language` per `test.describe` block, not globally. See `.claude/rules/playwright.md` and `language-switch-a11y.spec.ts` for the canonical pattern.

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
