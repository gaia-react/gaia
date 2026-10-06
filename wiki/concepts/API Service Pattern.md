---
type: concept
status: active
created: 2026-04-20
updated: 2026-10-03
tags: [concept, services, api]
---

# API Service Pattern

Canonical reference for adding a domain service. Mirrored by the `api-service` rule (`frontend/.claude/rules/api-service.md`) and scaffolded by `/new-service`.

Related: [[Services]], [[MSW Handlers]]

## Folder structure

Each domain lives under `frontend/app/services/gaia/{domain}/`:

| File                 | Role                                                                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `requests.ts`        | API functions: import the shared `api` and `envelope` from `../api`; the response is validated by the schema passed to the call |
| `queries.ts`         | Query key factory and `queryOptions` (only when TanStack Query is installed; see [[Data Loading]])                  |
| `parsers.ts`         | Zod schemas for response validation                                                                                |
| `types.ts`           | TypeScript types derived from Zod                                                                                  |
| `state.tsx`          | Read-only React Context + hook (optional, add when a route needs to pass fetched data to deeply nested components) |
| `index.ts`           | Barrel re-exporting parsers, types, and urls                                                                       |

Each domain is self-contained: its own `urls.ts` and `index.ts`. Services are isomorphic: there is no `.server` barrel, and the same request functions run in a server loader, a `clientLoader`, and a query. The scaffold does not touch the root `frontend/app/services/gaia/urls.ts`.

## Scaffold output

`/new-service` wraps the deterministic CLI `gaia scaffold service <name>`; `gaia scaffold service --help` lists its flags and the schema syntax. It emits all files for a domain. Live examples in `frontend/app/services/gaia/`:

| File                 | Key rules                                                                                                              |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `urls.ts`            | A domain's endpoints in one per-domain `{NAME}_URLS` constant; colon-prefixed segments interpolated from `pathParams`  |
| `api.ts`             | `create()` from `../api` plus the `envelope(schema)` helper; wraps Ky with snake↔camel, per-request base URL, auth headers |
| `parsers.ts`         | `z.iso.datetime()` not `z.string().datetime()`; `.nullish()` for optional fields; an input schema for each mutation     |
| `types.ts`           | `z.infer<typeof schema>` only; never hand-maintain types alongside schemas                                             |
| `requests.ts`        | Passes `schema: envelope(<schema>)` to `api` and returns the unwrapped value; mutations send typed JSON from the input schema |
| `index.ts`           | Barrel: `export * from './parsers'; export * from './types'; export * from './urls'`                                   |

A typical request function:

```ts
export const getResourceById = async (
  id: string,
  signal?: AbortSignal
) =>
  api(RESOURCES_URLS.resourcesId, {
    pathParams: {id},
    schema: envelope(resourceSchema),
    signal,
  }).then(({data}) => data);
```

The call validates the body through Ky's `.json(schema)` over Standard Schema and resolves the typed value; there is no per-request `schema.parse`. A call without `schema` never parses the body, so a 204 resolves `undefined`.

`attempt` (from `~/services/api/helpers`) wraps a request into `[ApiError, undefined] | [undefined, T]`; use in loaders/actions when you need to handle errors without throwing. It maps an HTTP error to its status, and a Ky `SchemaValidationError` to `{status: 500}` with a constant message (the issues are logged on the server only).

## Backend casing

`create()` defaults to `useSnakeCase: true`: incoming response keys convert to camelCase, and outgoing JSON bodies and search params convert to snake_case. A backend that already speaks camelCase needs `useSnakeCase: false` on that `create()` instance. The symptom of leaving the default on a camelCase backend is 400 responses and requests arriving with snake_case keys. `gaia init configure-data-layer --casing camel` writes the flag into the domain layer's `api.ts`; see [[GAIA Init Workflow]].

## `state.tsx`: read-only context (optional)

Add `state.tsx` when a route loader fetches data that deeply nested client components need. Read-only context only; no setters; mutations go through actions. See the `state-pattern` rule (`frontend/.claude/rules/state-pattern.md`) and [[State]].

## Mocking with MSW

Every service has a matching mock layer in `frontend/test/mocks/{domain}/`. The folder structure mirrors the service: `get.ts`, `post.ts`, `put.ts`, `delete.ts` (one file per HTTP method), `data.ts` (server-shape Zod schema + `@msw/data` `Collection` + seed records + reset), and `index.ts` (barrel combining all handlers).

Note: MSW mock data uses snake_case field names (matching the real API wire format). The Ky wrapper converts to camelCase before the Zod schemas see it, so the server schema in `data.ts` reflects the raw server shape, and the `Collection` consumes that schema directly via Standard Schema. Mutation handlers read the JSON body with `request.json()` and answer `{data}`.

Register handlers in `frontend/test/mocks/index.ts` and re-export the new collection (plus its reset) from `frontend/test/mocks/database.ts`. See [[MSW Handlers]] for full setup details.

`/new-service` scaffolds all of the above.
