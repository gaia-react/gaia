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
updated: 2026-06-24
tags: [module, services, api]
---

# Services

`app/services/` is where API calls and business logic live.

## `api/` vs `gaia/`: the convention

- `app/services/api/`: the [[Ky]] wrapper. A `create()` factory plus path/search-param interpolation, snake_case ↔ camelCase conversion, and per-request `token` / `language` request options. **Reusable across domains.**
- `app/services/gaia/`: the GAIA template's domain layer. Rename to your company name or 3rd-party API name; Claude updates imports, barrels, and references across the app.

The pattern: each domain folder under `app/services/gaia/{domain}/` holds `parsers.ts`, `types.ts`, `requests.ts`, its own URL constants (`urls.ts`), and a non-server `index.ts` barrel re-exporting parsers, types, and urls. Domains share the root `Ky` instance (`app/services/gaia/api.ts`) via `import {api} from '../api'`. `/new-service` scaffolds the full pattern and leaves the root `urls.ts` and `index.server.ts` untouched.

## Why URL constants are mandatory

Each domain owns a per-domain URL constant in its own `urls.ts` (e.g. `PROJECTS_URLS` in `app/services/gaia/projects/urls.ts`). That constant is the contract between the service layer and the MSW mocks ([[MSW Handlers]]): both the request functions and the handlers import the same per-domain constant, so a path change updates both sides together. Hardcoding paths breaks the contract and lets requests escape to the real network in tests.

## See also

- [[Ky]]: full Ky wrapper details
- [[API Service Pattern]]: service folder shape and conventions
- [[MSW Handlers]]: mock-side contract
