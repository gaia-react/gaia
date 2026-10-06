---
type: module
path: frontend/test/mocks/, frontend/test/worker.ts, frontend/test/test.server.ts, frontend/vite.config.ts, frontend/app/entry.client.tsx, frontend/app/entry.server.tsx
status: active
language: typescript
purpose: API mocking layer shared across Vitest, Storybook, and dev
depends_on: [[MSW]]
created: 2026-04-20
updated: 2026-10-06
tags: [module, msw, testing, mocking]
---

# MSW (Mock Service Worker)

The app uses [[MSW]] + `@msw/data` as the **single mocking layer** for unit tests, Playwright E2E, and optional dev mode.

> [!key-insight] One mock set, three environments
> The same handlers and in-memory database serve Vitest (CI/local), the dev server (`MSW_ENABLED=true`), and Playwright runs. You define a mock once; every surface sees the same fake API.

See also: [[API Service Pattern]], [[Services]], [[Testing]], [[Test Runner]].

## Why MSW lives at the network layer

MSW intercepts HTTP requests at the network layer; no monkey-patching, no import mocking. Because the service layer uses `ky` with `API_URL` as the prefix, every outbound request goes through a real fetch. MSW catches it before it leaves the process (Node) or browser (Service Worker).

This means tests exercise the full request path: route loader → service function → ky → MSW handler → fake DB → response parsing. Import-level mocking would skip the request layer and hide URL drift, parser bugs, and serialization issues.

## Service-layer contract: the load-bearing invariant

**MSW handler URLs must exactly match the URLs the service layer constructs at runtime.**

A request URL is built by joining `API_URL` (env, e.g. `http://localhost:3001/api/`) with a path token from the domain's `{NAME}_URLS` constant (e.g. `'resources/:id'`). `ky` does the join in the service layer. The handler must use the same logic; the `url()` helper in `frontend/test/mocks/url.ts` mirrors ky's prefix-join (strips trailing slash from prefix, leading slash from path, joins with exactly one `/`).

```ts
import {http} from 'msw/http';
import {RESOURCES_URLS} from '~/services/gaia/resources/urls';
import {url} from '../url';

http.get(url(RESOURCES_URLS.resources), () => { ... });
```

> [!warning] URL drift = escaped requests
> If a handler URL doesn't match the ky-constructed URL, MSW passes the request through (`onUnhandledFrame: 'bypass'`). The request goes to the real network, fails silently in tests, and appears as a flaky fetch error rather than a mock miss.

The fix: both the service request functions and the handlers import the same per-domain `{NAME}_URLS` from `frontend/app/services/gaia/{domain}/urls.ts`. **Never hardcode paths in handler files.** When a URL constant changes, both sides update together.

## Three runtime modes

- **Dev**: with `MSW_ENABLED=true` in `.env`, browser and SSR requests both go through the msw/vite plugin's network; wiring in [[MSW]].
- **Vitest**: Node `setupServer` via `frontend/test/test.server.ts`, registered in `frontend/test/setup.ts`. `beforeAll → listen`, `afterEach → resetHandlers`, `afterAll → close`.
- **Playwright**: the Playwright web server is `pnpm dev`, so with `MSW_ENABLED=true` its requests are mocked on both the browser and SSR sides (see [[MSW]]).

## Writing a new mock

**Ask Claude to scaffold it via `/new-service`.** The skill creates the full mock layer alongside the service so the two stay in sync; request functions and matching handlers drop in together, URLs share the domain's `{NAME}_URLS` constants, and the database factory registers the new resource.

If you're editing an existing mock by hand instead of scaffolding, the invariants you must preserve:

- Handlers use `url({NAME}_URLS.key)`, never a hardcoded string
- Mock data keeps the server's wire shape: camelCase by default, snake_case when the layer's `create()` sets `isSnakeCaseEnabled: true` (the service layer then converts to camelCase)
- New collections register their `reset*()` in `resetTestData()`

See the `api-service` rule (`frontend/.claude/rules/api-service.md`) for the full contract and [[API Service Pattern]] for the service side.

## Database collection pattern

Each resource owns its `@msw/data` `Collection` in `frontend/test/mocks/{resource}/data.ts`. `frontend/test/mocks/database.ts` re-exports those collections and aggregates each domain's `reset*()` into one `resetTestData()`.

Reads and removals on a `Collection` are sync (`findFirst`, `findMany`, `delete`, `deleteMany`, `clear`); only `create`, `createMany`, `update`, and `updateMany` are async, and awaiting a sync call fails the `await-thenable` lint rule. The query API is predicate-based:

```ts
things.findFirst((q) => q.where({id: 'abc'}));
things.findMany(); // all
await things.update((q) => q.where({id: 'abc'}), {
  data(t) {
    t.name = 'new';
  },
});
```

### When `resetTestData()` runs

`resetTestData()` is async and runs automatically in an `afterEach` hook in `frontend/test/setup.ts`, the setup file of the `node` Vitest project. Every test in that project starts from a freshly wiped and re-seeded database; no manual reset is needed.

```ts
// frontend/test/setup.ts
afterEach(resetTestData);
```

Stories and browser-project tests run neither the MSW node server nor this reset. Stories mock the API through the wired `msw-storybook-addon`: a story passes handlers in `parameters.msw.handlers`, and a handler that serves a mutation reads the typed JSON body with `request.json()` (never `formData`) and answers `{data}`. Stories read seed data from the `@msw/data` collections directly, so they treat those collections as read-only.

> [!warning] `resetHandlers` ≠ `resetTestData`
> `frontend/test/test.server.ts` calls `server.resetHandlers()` in its own `afterEach`; this resets runtime handler overrides but **not** the database. The database reset is the separate `resetTestData()` wired into `frontend/test/setup.ts`.

`frontend/test/mocks/faker.ts` exports a seeded `faker` instance (seed `7`) so generated values are deterministic across runs.

## Common pitfalls

- **Request escapes to real network** → handler URL doesn't match ky URL. Use `url({NAME}_URLS.key)`, never a hardcoded string.
- **Test sees stale data after mutation** → the test runs outside the `node` project (a story or browser test), where the automatic `afterEach` `resetTestData()` never runs; keep stories and browser tests from mutating the collections.
- **MSW not active in dev** → `MSW_ENABLED` missing or false in `.env`.
- **Server-side requests bypass mock in dev** → `MSW_ENABLED` is not truthy in the server's environment, or the request URL matches no handler (`onUnhandledFrame: 'bypass'` lets it through).
- **Handler added but never triggered** → not registered in `frontend/test/mocks/index.ts`.
- **Runtime override persists across tests** → `server.use()` was called outside a test body. Don't.
- **Playwright ignores mocks** → `MSW_ENABLED` is not `true` in the environment that launches the `pnpm dev` web server.

For the current folder structure and file inventory, query Serena (`.claude/rules/code-search.md`).
