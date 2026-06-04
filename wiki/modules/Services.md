---
type: module
path: app/services/
status: active
language: typescript
purpose: API client (Ky wrapper) and domain-specific service layers
depends_on:
  - '[[Ky]]'
  - '[[Zod]]'
created: 2026-04-20
updated: 2026-05-04
tags: [module, services, api]
---

# Services

`app/services/` is where API calls and business logic live.

## `api/` vs `gaia/`: the convention

- `app/services/api/`: the [[Ky]] wrapper. A `create()` factory plus path/search-param interpolation, snake_case ↔ camelCase conversion, and per-request `token` / `language` request options. **Reusable across domains.**
- `app/services/gaia/`: the GAIA template's domain layer. Rename to your company name or 3rd-party API name; Claude updates imports, barrels, and references across the app.

The pattern: each domain owns its own `Ky` instance (`api.ts`), its URL constants (`urls.ts`), and a server-only barrel (`index.server.ts`). Domain subfolders (`auth/`, `users/`, etc.) hold request functions, types, and parsers. `/new-service` scaffolds the full pattern.

## Why URL constants are mandatory

`GAIA_URLS` in `app/services/gaia/urls.ts` is the contract between the service layer and the MSW mocks ([[MSW Handlers]]). Both sides import the same constant; when a path changes, both sides update together. Hardcoding paths breaks the contract and lets requests escape to the real network in tests.

## See also

- [[Ky]]: full Ky wrapper details
- [[API Service Pattern]]: service folder shape and conventions
- [[MSW Handlers]]: mock-side contract
