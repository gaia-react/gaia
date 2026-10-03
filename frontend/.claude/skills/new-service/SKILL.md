---
name: new-service
description: Scaffold a new API service with request functions, Zod schemas, URL constants, and optional MSW mock handlers. Use this skill whenever the user asks to "add a service", "create the projects API", "wire up CRUD for users", or anything implying a new service folder under `app/services/` (`app/services/gaia/{name}/` until the `gaia/` folder is renamed) with parsers/types/requests + matching `test/mocks/{name}/` collections.
model: haiku
---

# new-service

Trigger: user asks to scaffold an API service.

## Workflow

1. Confirm: name (kebab), endpoints, schema (`name:type` pairs), with mocks?
2. Run from the repo root: `./.gaia/cli/gaia scaffold service <name> --endpoints "..." --schema "..." [--mocks]`. It writes into the domain-layer folder under `app/services/`, found as the one folder there besides `api/` (shipped as `gaia/`, often renamed to the company or API name). If it refuses because several folders qualify, ask which one and rerun with `--layer <folder>`.
3. Verify: `pnpm typecheck` clean; if `--mocks`, run a single MSW round-trip in a vitest test.
4. Wire the service into the consuming page/hook (CLI does not do this, manual). Before wiring, read how an existing service is wired into its page or hook and follow that pattern.

## Flags

- `--endpoints "get,post,put,delete"`, required (subset of get/post/put/delete)
- `--schema "id:string,name:string,status:enum(active,archived)"`, required
- `--layer <folder>`, domain-layer folder under `app/services/`; needed only when more than one folder besides `api/` exists
- `--mocks`, also emit MSW mock collection
- `--json`, emit `ScaffoldResult` JSON

Schema types: `string`, `number`, `boolean`, `datetime`, `enum(a,b,...)`. Append `?` for optional.

## See

- `wiki/concepts/API Service Pattern.md`, pattern source of truth
- `frontend/.claude/rules/api-service.md`, quick pointer
