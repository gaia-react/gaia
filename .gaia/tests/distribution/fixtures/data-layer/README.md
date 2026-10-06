# Data-layer fixtures

Maintainer test infrastructure for the API data layer, never shipped. `19-data-layer-query-on.sh` copies the SSR, query-client, service, flow, and story-isolation fixtures into a staged tree's `frontend/` after the Query runtime is installed there (the `@tanstack/react-query` dependency, `app/query-client.ts`, `app/state/query-provider.tsx` wrapped around `{children}` in `app/state/index.tsx`, and the Storybook `QueryClientDecorator`) and the `items` service (`--schema "id:string,displayName:string" --mocks`) and its Query list and detail routes are scaffolded, then runs them. `20-data-layer-query-off.sh` copies the lint probes, one at a time, into a tree without Query. Every fixture except the lint probes is lint- and typecheck-clean in its tree as written; the probes exist to fail lint.

| Fixture | Destination under `frontend/` | Asserts |
| --- | --- | --- |
| `ssr/routes/_public.ssr-seed.tsx` | `app/routes/_public.ssr-seed.tsx` (URL `/ssr-seed`) | Thin route rendering the seed page. |
| `ssr/pages/ssr-seed/page.tsx` | `app/pages/ssr-seed/page.tsx` | During render, writes `isolation-seed-value` into the provider's client under `['ssr-isolation-probe']` and renders it. |
| `ssr/routes/_public.ssr-read.tsx` | `app/routes/_public.ssr-read.tsx` (URL `/ssr-read`) | Thin route rendering the read page. |
| `ssr/pages/ssr-read/page.tsx` | `app/pages/ssr-read/page.tsx` | Renders the provider client's `['ssr-isolation-probe']` value, or `isolation-cache-empty` when it holds none. |
| `ssr/routes/_public.ssr-query.tsx` | `app/routes/_public.ssr-query.tsx` (URL `/ssr-query`) | A clientLoader + Query route with no server `loader`: the clientLoader awaits `getQueryClient().query(...)`, and `HydrateFallback` renders `<title>Query probe loading</title>` and `hydrate-fallback-rendered`. |
| `ssr/pages/ssr-query/page.tsx`, `ssr/pages/ssr-query/query.ts` | `app/pages/ssr-query/` | The page reads the query with `useSuspenseQuery` and renders `query-data-rendered`; the query fetches a relative URL, which throws on the server, so a server render of the page fails loudly. |
| `ssr/check-ssr-isolation.mjs` | Run in place with `node`, after `pnpm build` | See below. |
| `query-client/query-client.test.ts` | `test/query-client.test.ts` (node project) | Two `getQueryClient()` calls on the server return distinct clients. |
| `query-client/query-client.browser.test.tsx` | `test/query-client.browser.test.tsx` (browser project) | Two `getQueryClient()` calls in the browser return the same client, and after `setBrowserQueryClient(x)` the next call returns `x`. |
| `service/items-service.test.ts` | `test/items-service.test.ts` (node project) | Through the scaffolded `items` service: a 200 body violating the schema resolves `attempt` to a 500 with a non-empty `statusText`; a plain `Error` inside `attempt` rejects; `createItem({displayName})` sends `display_name` and returns `displayName`; a request starts with the server `API_URL`; `cancelQueries` on the detail key aborts the in-flight request the handler sees. |
| `service/items-base-url.test.tsx` | `test/items-base-url.test.tsx` (browser project) | `getAllItems()` requests start with the `API_URL` injected on `window.process`. |
| `flow/items-flow.test.tsx` | `test/items-flow.test.tsx` (browser project) | Mounts the scaffolded `_public.items` and `_public.items_.$id` route modules in `createRoutesStub` under a fresh per-test QueryClient and the `test/worker.ts` worker (`onUnhandledFrame: 'error'`, scaffolded `items` handlers), walks list, detail, rename, and the redirect back, and asserts the per-endpoint GET counts at each step. Runs twice in one file, so a client shared across tests fails the second run's first list count. |
| `story-isolation/item-names/index.tsx` | `app/components/item-names/index.tsx` | Renders `useQuery(itemsQuery())` names. |
| `story-isolation/item-names/tests/handler-a-first.stories.tsx`, `handler-b-first.stories.tsx` | `app/components/item-names/tests/` | Two stories per file with different `parameters.msw.handlers` for the same query key, in opposite orders; each play asserts only its own handler's data, so a QueryClient shared across stories fails the second story of either file. |
| `lint-probes/imperative-query-probe.ts` | `app/imperative-query-probe.ts`, removed after the run | Four imperative fetches through local stand-ins; each must fail `local/no-imperative-query-fetch` naming `queryClient.query`. |
| `lint-probes/restricted-properties-probe.ts` | `app/restricted-properties-probe.ts`, removed after the run | `Math.pow` must still fail the inherited `no-restricted-properties` entry. |
| `lint-probes/restricted-syntax-probe.tsx` | `app/restricted-syntax-probe.tsx`, removed after the run | A ternary rendering `null` must still fail the `@gaia-react/lint` `no-restricted-syntax` selector. |

## The SSR check

`check-ssr-isolation.mjs` imports the staged tree's `build/server/index.js`, wraps it in `createRequestHandler` from the tree's own `react-router`, and requests three routes in one process, in order:

1. the seed route: HTML contains the seed value;
2. the read route: HTML contains the empty marker and not the seed value, so no QueryClient survived the previous request;
3. the clientLoader route: status 200, HTML contains the fallback marker and the fallback `<title>`, and not the forbidden string, so the page and its `useSuspenseQuery` never rendered on the server.

It fills in the environment values `app/env.server.ts` requires when they are unset. Exit 0 on pass, 1 on any failed assertion (each printed as `FAIL ...`), 2 on a usage error.

```bash
node .gaia/tests/distribution/fixtures/data-layer/ssr/check-ssr-isolation.mjs \
  --frontend <staged>/frontend \
  --seed /ssr-seed --read /ssr-read --client-loader /ssr-query \
  --fallback-marker hydrate-fallback-rendered --forbidden query-data-rendered \
  --title 'Query probe loading'
```

To check a scaffolded clientLoader + Query route instead, point `--client-loader` at its URL and pass its `HydrateFallback` marker and a string only its page renders. `--title` is optional: without it the check accepts any non-empty `<title>`. `--seed-value` and `--empty-marker` default to the seed and read pages' strings.

The check fails when isolation breaks: with the provider taking a module-scope `getQueryClient()`, or with `getQueryClient()` returning one module-level client on the server, step 2 fails on the seed value. With a server `loader` added to the clientLoader route, step 3 fails (status 500, no fallback marker or title), because the page then renders on the server.
