---
type: dependency
status: active
package: msw
version: 2.14.6
role: api-mocking
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, testing, mocking]
---

# MSW

[Mock Service Worker](https://mswjs.io/). Intercepts HTTP via Service Worker (browser) or interceptors (Node). One mocking layer for tests, Storybook, and dev.

## Entry points

Two setups share the handler set from `test/mocks`:

- `test/worker.ts` calls `setupWorker(ping, ...handlers)` from `msw/browser` for the browser Service Worker, prepending the `ping` handler from `test/mocks/ping` ahead of the domain handlers.
- `test/msw.server.ts` calls `setupServer(...handlers)` from `msw/node`, persists the instance on `globalThis.__MSW_SERVER`, and exports `startApiMocks` (start on first call, restart on subsequent calls).

## Companion packages

`@msw/data` (in-memory DB), `public/mockServiceWorker.js` (worker via `msw.workerDirectory` in `package.json`). `msw-storybook-addon` is installed but deliberately unused; stories seed from `@msw/data` directly. See [[Storybook Stories]] for rationale.

See [[MSW Handlers]] for handler structure.
