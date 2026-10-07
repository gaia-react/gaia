---
type: concept
status: active
created: 2026-10-06
updated: 2026-10-06
tags: [concept, services, routing, data-loading]
---

# Data Loading

How a route gets its data, and how the data layer behind it is wired. The rule text lives in `frontend/.claude/skills/react-code/SKILL.md`; this page explains the decision logic and shows short excerpts. The scaffold templates under `.gaia/cli/templates/` (`route/`, `service/`, `data-layer/`) are the authoritative code, so a full listing is never repeated here.

Related: [[API Service Pattern]], [[Services]], [[Thin Routes]], [[Routing]], [[Ky]], [[State]], [[Stories as Tests]], [[MSW Handlers]]

## The rule in one table

| Who owns the data                                  | Where it is read                                  |
| -------------------------------------------------- | ------------------------------------------------- |
| The URL (the page cannot render without it)        | The route's `loader` or `clientLoader`            |
| A component (an in-place widget, not a route)      | `useQuery` or `useMutation` inside the component  |
| Both (route shows it, a widget keeps it fresh)     | `clientLoader` primes the cache, the page reads `useSuspenseQuery` |

`react-code` owns the wording and the review checks. The `clientLoader` and component-owned rows need TanStack Query; the server loader row does not.

## Server loader

The default for first-paint, public, and SEO content. The server runs the loader, renders the page with the data, and ships finished HTML. Nothing waits on JavaScript to show content.

```tsx
export const loader = async ({
  request,
}: Route.LoaderArgs): Promise<LoaderData> => ({
  items: await getAllItems(request.signal),
});
```

Scaffold: `gaia scaffold route items --group _public --data server --service items --shape list`.

## clientLoader

A route that exports `clientLoader` and no `loader` renders only `HydrateFallback` on the server. The content then waits on the HTML, the JavaScript, hydration, and finally the fetch. That wait is the first-load cost, paid once per full page load; later in-app navigations call the `clientLoader` directly with no document round trip. The title and meta tags come from `HydrateFallback` and the page, since there is no server loader to resolve them.

Use it for authenticated or personalized data that gains nothing from server rendering.

```tsx
export const clientLoader = async ({
  request,
}: Route.ClientLoaderArgs): Promise<LoaderData> => ({
  items: await getAllItems(request.signal),
});

export const HydrateFallback = () => <ItemsHydrateFallback />;
```

The scaffold writes the fallback as a skeleton component in the page folder (`app/pages/<name>/hydrate-fallback/`), carrying the page's title and description.

Scaffold: `--data client`. A route that also takes `--action` keeps a server `action`.

## clientLoader + TanStack Query

Opt-in. The `clientLoader` awaits `getQueryClient().query(...)` and returns nothing; the page reads the same key with `useSuspenseQuery`, so navigation fetches once. A `clientAction` mutates, awaits `invalidateQueries` on the service's `all` key, and then redirects, so the list the user lands on is already fresh.

```tsx
export const clientLoader = async () => {
  await getQueryClient().query(itemsQuery());
};
```

`invalidateQueries` with the default `refetchType` refetches only mounted queries. A query for an off-screen route is marked stale and fetched once by its `clientLoader` on the next navigation to it.

Scaffold: `gaia scaffold route items --group _public --data query --service items --shape list --action`. The route scaffold refuses `--data query` when Query is not installed, and when the bound service has no `queries.ts`; each refusal names the command that fixes it.

The imperative methods `ensureQueryData`, `fetchQuery`, and `prefetchQuery` (and the infinite variants) are banned in `app/**` by the local lint rule `local/no-imperative-query-fetch` (`frontend/eslint/no-imperative-query-fetch.mjs`). The lint rule exists so a route has one fetch idiom; `queryClient.query` is the supported call and the message says so.

## The service side

- `requests.ts` calls `api(URL, {schema: envelope(<schema>), signal, ...})` and returns the unwrapped `data`. `envelope` (in the domain layer's `api.ts`) wraps a schema as `{data: schema}`. Ky validates the body through `.json(schema)`. `signal` is the last parameter of every read, so a query's cancellation reaches the network request.
- `queries.ts` holds a key factory (`all`, `list`, `detail`) and `queryOptions` for the list and by-id reads. It exists only when Query is installed.
- `gaia scaffold service <name> --queries-only [--layer <folder>]` writes just `queries.ts` into an existing service folder, for a service created before Query was on. It refuses when Query is not installed, the folder is missing, or `requests.ts` has no list getter and by-id getter.

The templates are `.gaia/cli/templates/service/requests.ts.tmpl` and `queries.ts.tmpl`.

## QueryClient scope

`gaia init configure-data-layer --query true` writes `query-client.ts` into `frontend/app/` and `query-provider.tsx` into `frontend/app/state/`, from the templates in `.gaia/cli/templates/data-layer/`; neither file exists until Query is turned on. `query-client.ts` exposes one accessor, `getQueryClient()`. On the server it returns a fresh client on every call; in the browser it returns a lazily built singleton with `staleTime: 30_000`, long enough that a `clientLoader`'s fetch is still fresh when the page reads it. No module exports a client instance, so nothing can capture one at import time.

`query-provider.tsx` obtains its client once per render tree (`useState(getQueryClient)`) and is composed inside `<State>` ([[State]]). A server render never shares a cache with another request, because the module-level singleton exists only when `window` does. A module-scope client on the server would serve one user's cached data into another user's HTML.

## Mutations

Route actions are the default for mutations: the form posts, the action runs the mutation request function, and the navigation revalidates. `useMutation` is for in-place widget mutations that need optimistic UI, where a navigation would be wrong.

## Gaps and costs

- `<Link prefetch>` never runs a `clientLoader`. A prefetch warms the route's JavaScript and a server `loader`'s data, not a `clientLoader`, so a `clientLoader` route always fetches on navigation.
- Every `clientAction` also revalidates the root server loader (`frontend/app/root.tsx`), so a client-action submit still costs one server round trip.
- Opting into Query puts `@tanstack/react-query` in the root chunk, because the provider mounts in the root. The data-layer subcommand is the opt-in; Query-off projects ship no Query code.

## Security

- Identity changes (sign-in, sign-out, user switch) call `queryClient.clear()` or do a full document navigation, because the browser cache holds the previous user's data.
- The `clientLoader` and Query variants suit unauthenticated or cookie-authenticated APIs. Tokens never enter the root loader's `ENV`; the config a browser service needs is non-secret by construction.
- A service is isomorphic and imports nothing named `*.server*`; React Router's build error for a dot-server import in the client graph is the guard that keeps it so.

## Adopter recipe: server-side prefetch with dehydrate

GAIA does not ship this; it is a recipe for an adopter who wants server-rendered Query data. Build a request-scoped `QueryClient` (for example through React Router context), prefetch into it in the server `loader`, return `dehydrate(client)`, and wrap the component in `HydrationBoundary`. Do not use the shipped `getQueryClient()` accessor for it: the accessor's server branch makes a new client per call, so the client the loader fills is not the one the render reads.

## OpenAPI generators

For a large or fast-moving API, a generator such as Hey API or Orval can produce a typed client and Zod schemas from the OpenAPI document. Wrap the generated client in the service's request functions in place of `api`; the route and query wiring on this page is unchanged.

## Turning it on later, and reversing it

`gaia init` asks two data-layer questions (backend casing and whether to use TanStack Query; see [[GAIA Init Workflow]]). After init has finished, `./.gaia/cli/gaia init configure-data-layer --query true` adds Query: it writes the dependency into `frontend/package.json`, the runtime files, and one anchored edit in each of the provider, Storybook preview, and the two Vite configs, then prints the `next` commands (`pnpm install`, and `scaffold service <name> --queries-only` for each eligible existing service). It never runs pnpm.

The subcommand is additive and removes nothing. To remove Query, delete the three files it wrote, the `QueryProvider` wrapper, the Storybook decorator entry, the `optimizeDeps` entries, and the dependency by hand. To return a layer to the camelCase default, drop `isSnakeCaseEnabled` (or set it to `false`) on the layer's `create()` call.

Ownership: `app/query-client.ts`, `app/state/query-provider.tsx`, and the Storybook Query decorator are adopter-owned from the moment they are written, so a later fix to them reaches adopters as CHANGELOG guidance, not as an `/update-gaia` merge.
