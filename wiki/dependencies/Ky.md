---
type: dependency
status: active
package: ky
version: 2.0.2
role: http-client
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, http]
---

# Ky

Tiny HTTP client built on `fetch`. GAIA's `app/services/api/index.ts` wraps it:

- `create()` factory that returns a typed request function
- per-request `token` / `language` options that set `Authorization` and `Accept-Language` headers per call
- snake_case ↔ camelCase conversion via hooks (`useSnakeCase: true` by default)
- search-param serialization via `query-string`; path-param interpolation via `:token` string replacement

See [[Services]].
