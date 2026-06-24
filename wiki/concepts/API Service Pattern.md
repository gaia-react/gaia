---
type: concept
status: active
created: 2026-04-20
updated: 2026-06-24
tags: [concept, services, api]
---

# API Service Pattern

Canonical reference for adding a domain service. Mirrored by the `api-service` rule (`.claude/rules/api-service.md`) and scaffolded by `/new-service`.

Related: [[Services]], [[MSW Handlers]]

## Folder structure

Each domain lives under `app/services/gaia/{domain}/`:

| File                 | Role                                                                                                               |
| -------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `requests.ts`        | API functions: import the shared `api` from `../api` and parse responses with the domain's Zod schemas             |
| `parsers.ts`         | Zod schemas for response validation                                                                                |
| `types.ts`           | TypeScript types derived from Zod                                                                                  |
| `state.tsx`          | Read-only React Context + hook (optional, add when a route needs to pass fetched data to deeply nested components) |
| `index.ts`           | Barrel re-exporting parsers, types, and urls                                                                       |

Each domain is self-contained: its own `urls.ts` and `index.ts`. The scaffold does not touch the root `app/services/gaia/urls.ts` or `app/services/gaia/index.server.ts`.

## Scaffold output

`/new-service` wraps the deterministic CLI `gaia scaffold service <name> --endpoints "get,post,put,delete" --schema "id:string,name:string" [--mocks]`. Endpoints are a subset of the closed `get/post/put/delete` set; schema types are `string | number | boolean | datetime | enum(a,b,...)` with a trailing `?` for optional. Mocks are opt-in via `--mocks`. It emits all files for a domain. Live examples in `app/services/gaia/`:

| File                 | Key rules                                                                                                              |
| -------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `urls.ts`            | A domain's endpoints in one per-domain `{NAME}_URLS` constant; colon-prefixed segments interpolated from `pathParams`  |
| `api.ts`             | `create<ServerResponse>()` from `../api`; wraps Ky with snake↔camel, base URL, auth headers                            |
| `parsers.ts`         | `z.iso.datetime()` not `z.string().datetime()`; `.nullish()` for optional fields; always `.parse()` not `.safeParse()` |
| `types.ts`           | `z.infer<typeof schema>` only; never hand-maintain types alongside schemas                                             |
| `requests.ts`        | `body: FormData` for mutations; calls `schema.parse(result.data)` directly and lets errors throw                       |
| `index.ts`           | Barrel: `export * from './parsers'; export * from './types'; export * from './urls'`                                   |

A typical request function:

```ts
export const getResourceById = async (id: string): Promise<Resource> => {
  const result = await api(RESOURCES_URLS.resourcesId, {pathParams: {id}});
  return resourceSchema.parse(result.data);
};
```

`attempt` (from `~/services/api/helpers`) wraps a request into `[ApiError, undefined] | [undefined, T]`; use in loaders/actions when you need to handle errors without throwing.

## `state.tsx`: read-only context (optional)

Add `state.tsx` when a route loader fetches data that deeply nested client components need. Read-only context only; no setters; mutations go through actions. See the `state-pattern` rule (`.claude/rules/state-pattern.md`) and [[State]].

## Mocking with MSW

Every service has a matching mock layer in `test/mocks/{domain}/`. The folder structure mirrors the service: `get.ts`, `post.ts`, `put.ts`, `delete.ts` (one file per HTTP method), `data.ts` (server-shape Zod schema + `@msw/data` `Collection` + seed records + reset), and `index.ts` (barrel combining all handlers).

Note: MSW mock data uses snake_case field names (matching the real API wire format). The Ky wrapper converts to camelCase before the Zod schemas see it, so the server schema in `data.ts` reflects the raw server shape, and the `Collection` consumes that schema directly via Standard Schema.

Register handlers in `test/mocks/index.ts` and re-export the new collection (plus its reset) from `test/mocks/database.ts`. See [[MSW Handlers]] for full setup details.

`/new-service` scaffolds all of the above.
