---
name: new-service
description: Scaffold a new API service with request functions, Zod schemas, URL constants, and optional MSW mock handlers. Use this skill whenever the user asks to "add a service", "create the projects API", "scaffold a new GAIA service", "wire up CRUD for users", or anything implying a new folder under `app/services/gaia/{name}/` with parsers/types/requests + matching `test/mocks/{name}/` collections.
model: haiku
---

# new-service

Trigger: user asks to scaffold an API service.

## Workflow

1. Confirm: name (kebab), endpoints, schema (`name:type` pairs), with mocks?
2. Run: `.gaia/cli/gaia scaffold service <name> --endpoints "..." --schema "..." [--mocks]`
3. Verify: `pnpm typecheck` clean; if `--mocks`, run a single MSW round-trip in a vitest test.
4. Wire the service into the consuming page/hook (CLI does not do this — manual).

## Flags

- `--endpoints "get,post,put,delete"` — required (subset of get/post/put/delete)
- `--schema "id:string,name:string,status:enum(active,archived)"` — required
- `--mocks` — also emit MSW mock collection
- `--json` — emit `ScaffoldResult` JSON

Schema types: `string`, `number`, `boolean`, `datetime`, `enum(a,b,...)`. Append `?` for optional.

## See

- `wiki/concepts/API Service Pattern.md` — pattern source of truth
- `.claude/rules/api-service.md` — quick pointer
