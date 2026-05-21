---
type: dependency
status: active
package: ky
version: ^2.0.1
role: http-client
created: 2026-04-20
updated: 2026-04-20
tags: [dependency, http]
---

# Ky

Tiny HTTP client built on `fetch`. GAIA's `app/services/api/index.ts` wraps it:

- `create()` factory that returns a typed request function
- per-request `token` / `language` options that set `Authorization` and `Accept-Language` headers per call
- snake_case ↔ camelCase conversion via hooks (`useSnakeCase: true` by default)
- Path-param + search-param interpolation via `query-string`

See [[Services]].
