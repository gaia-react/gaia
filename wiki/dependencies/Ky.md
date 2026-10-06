---
type: dependency
status: active
package: ky
role: http-client
created: 2026-04-20
updated: 2026-10-03
tags: [dependency, http]
---

# Ky

Tiny HTTP client built on `fetch`. `frontend/app/services/api/index.ts` wraps it:

- `create()` factory that returns a request function. A `schema` option sends the body through Ky's `.json(schema)` (any Standard Schema, so Zod works) and resolves the validated value; without `schema` the body is never parsed
- a failed validation throws Ky's `SchemaValidationError`, which `attempt` (`frontend/app/services/api/helpers.ts`) maps to `{status: 500}` with a constant message and the issues logged server-side only
- the base URL is resolved on every request, not at import, so it follows `API_URL` on the server and in the browser; an empty value resolves to `/`
- per-request `token` / `language` options that set `Authorization` and `Accept-Language` headers per call
- snake_case ↔ camelCase conversion via hooks (`useSnakeCase: true` by default)
- search-param serialization via `query-string`; path-param interpolation via `:token` string replacement

See [[Services]].
