---
type: module
path: test/mocks/, test/worker.ts, test/test.server.ts, test/msw.server.ts
status: active
language: typescript
purpose: API mocking layer shared across Vitest, Storybook, and dev
depends_on: [[MSW]]
created: 2026-04-20
updated: 2026-06-24
tags: [module, msw, testing, mocking]
---

# MSW (Mock Service Worker)

GAIA uses [[MSW]] + `@msw/data` as the **single mocking layer** for unit tests, Playwright E2E, Storybook stories, and optional dev mode.

> [!key-insight] One mock set, three environments
> The same handlers and in-memory database serve Vitest (CI/local), the dev server (`MSW_ENABLED=true`), and Playwright runs. You define a mock once; every surface sees the same fake API.

See also: [[API Service Pattern]], [[Services]], [[Testing]], [[Test Runner]].

## Why MSW lives at the network layer

MSW intercepts HTTP requests at the network layer; no monkey-patching, no import mocking. Because the service layer uses `ky` with `API_URL` as the prefix, every outbound request goes through a real fetch. MSW catches it before it leaves the process (Node) or browser (Service Worker).

This means tests exercise the full request path: route loader → service function → ky → MSW handler → fake DB → response parsing. Import-level mocking would skip the request layer and hide URL drift, parser bugs, and serialization issues.

## Service-layer contract: the load-bearing invariant

**MSW handler URLs must exactly match the URLs the service layer constructs at runtime.**

A request URL is built by joining `API_URL` (env, e.g. `http://localhost:3001/api/`) with a path token from the domain's `{NAME}_URLS` constant (e.g. `'resources/:id'`). `ky` does the join in the service layer. The handler must use the same logic; the `url()` helper in `test/mocks/url.ts` mirrors ky's prefix-join (strips trailing slash from prefix, leading slash from path, joins with exactly one `/`).

```ts
import {http} from 'msw';
import {RESOURCES_URLS} from '~/services/gaia/resources/urls';
import {url} from '../url';

http.get(url(RESOURCES_URLS.resources), () => { ... });
```

> [!warning] URL drift = escaped requests
> If a handler URL doesn't match the ky-constructed URL, MSW passes the request through (`onUnhandledRequest: 'bypass'`). The request goes to the real network, fails silently in tests, and appears as a flaky fetch error rather than a mock miss.

The fix: both the service request functions and the handlers import the same per-domain `{NAME}_URLS` from `app/services/gaia/{domain}/urls.ts`. **Never hardcode paths in handler files.** When a URL constant changes, both sides update together.

## Three runtime modes

- **Dev**: Browser Service Worker (`test/worker.ts`, client) + Node `SetupServer` (SSR) run simultaneously when `MSW_ENABLED=true` in `.env`. The SSR side runs `startApiMocks` from `test/msw.server.ts`, imported by `app/entry.server.tsx` (gated on `NODE_ENV !== 'production' && MSW_ENABLED`); it stores the server on `globalThis.__MSW_SERVER` so it survives HMR restarts. The browser worker prepends a `ping` passthrough handler (`test/mocks/ping.ts`) so the dev server's `/ping` hot-update endpoint reaches the real network instead of being intercepted.
- **Vitest**: Node `setupServer` via `test/test.server.ts` (distinct from the dev SSR `test/msw.server.ts`), registered in `test/setup.ts`. `beforeAll → listen`, `afterEach → resetHandlers`, `afterAll → close`.
- **Playwright**: MSW is **not** wired automatically. Start `pnpm dev` with `MSW_ENABLED=true` and point Playwright's `baseURL` at it.

## Writing a new mock

**Ask Claude to scaffold it via `/new-service`.** The skill creates the full mock layer alongside the service so the two stay in sync; request functions and matching handlers drop in together, URLs share the domain's `{NAME}_URLS` constants, and the database factory registers the new resource.

If you're editing an existing mock by hand instead of scaffolding, the invariants you must preserve:

- Handlers use `url({NAME}_URLS.key)`, never a hardcoded string
- Mock data stays snake_case (server shape); camelCase conversion happens in the service layer
- New collections register their `reset*()` in `resetTestData()`

See the `api-service` rule (`.claude/rules/api-service.md`) for the full contract and [[API Service Pattern]] for the service side.

## Database collection pattern

Each resource owns its `@msw/data` `Collection` in `test/mocks/{resource}/data.ts`. `test/mocks/database.ts` re-exports those collections and aggregates each domain's `reset*()` into one `resetTestData()`.

Reads on a `Collection` are sync (`findFirst`, `findMany`); mutations are async (`await create()`, `await update()`, `await delete()`, `await deleteMany()`). The query API is predicate-based:

```ts
things.findFirst((q) => q.where({id: 'abc'}));
things.findMany(undefined); // all
await things.update((q) => q.where({id: 'abc'}), {
  data(t) {
    t.name = 'new';
  },
});
```

### When `resetTestData()` runs

`resetTestData()` is async and runs automatically in an `afterEach` hook inside `test/rtl.tsx` (the Testing Library re-export wrapper). Every test that imports the project's RTL re-export starts from a freshly wiped and re-seeded database; no manual reset is needed. Tests that import `@testing-library/react` directly, bypassing `test/rtl.tsx`, must reset state themselves.

```ts
// test/rtl.tsx
import {resetTestData} from './mocks/database';

afterEach(async () => {
  await resetTestData();
  cleanup();
});
```

> [!warning] `resetHandlers` ≠ `resetTestData`
> `test/test.server.ts` calls `server.resetHandlers()` in its own `afterEach`; this resets runtime handler overrides but **not** the database. The database reset is the separate `resetTestData()` wired into `test/rtl.tsx`.

`test/mocks/faker.ts` exports a seeded `faker` instance (seed `7`) so generated values are deterministic across runs.

## Common pitfalls

- **Request escapes to real network** → handler URL doesn't match ky URL. Use `url({NAME}_URLS.key)`, never a hardcoded string.
- **Test sees stale data after mutation** → test bypasses `test/rtl.tsx`, so the automatic `afterEach` `resetTestData()` never runs.
- **MSW not active in dev** → `MSW_ENABLED` missing or false in `.env`.
- **Server-side requests bypass mock in dev** → `entry.server.tsx` check failed; ensure `env.MSW_ENABLED` is truthy.
- **Handler added but never triggered** → not registered in `test/mocks/index.ts`.
- **Runtime override persists across tests** → `server.use()` was called outside a test body. Don't.
- **Playwright ignores mocks** → start dev server with `MSW_ENABLED=true` and point Playwright at it.

For the current folder structure and file inventory, query Serena (`.claude/rules/code-search.md`).
