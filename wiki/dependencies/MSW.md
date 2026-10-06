---
type: dependency
status: active
package: msw
role: api-mocking
created: 2026-04-20
updated: 2026-10-03
tags: [dependency, testing, mocking]
---

# MSW

[Mock Service Worker](https://mswjs.io/). Intercepts HTTP via Service Worker (browser) or interceptors (Node). One mocking layer for tests, Storybook, and dev.

## Entry points

Two setups share the handler set from `frontend/test/mocks`:

- `frontend/test/worker.ts` calls `setupWorker(ping, ...handlers)` from `msw/browser` for the browser Service Worker, prepending the `ping` handler from `frontend/test/mocks/ping` ahead of the domain handlers.
- `frontend/test/msw.server.ts` calls `setupServer(...handlers)` from `msw/node`, persists the instance on `globalThis.__MSW_SERVER`, and exports `startApiMocks` (start on first call, restart on subsequent calls).

## Companion packages

`@msw/data` (in-memory DB), `frontend/public/mockServiceWorker.js` (worker via `msw.workerDirectory` in `package.json`). `msw-storybook-addon` is wired into Storybook: stories supply handlers through `parameters.msw.handlers`. See [[Storybook Stories]].

See [[MSW Handlers]] for handler structure.
