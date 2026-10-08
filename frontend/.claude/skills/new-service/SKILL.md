---
name: new-service
description: Scaffolds a new API service with request functions, Zod schemas, URL constants, optional TanStack Query options, and optional MSW mock handlers. Use this skill whenever the user asks to "add a service", "create the projects API", "wire up CRUD for users", or anything implying a new service folder under `app/services/` (`app/services/gaia/{name}/` until the `gaia/` folder is renamed) with parsers/types/requests + matching `test/mocks/{name}/` collections.
model: haiku
---

# new-service

Trigger: user asks to scaffold an API service.

## Workflow

1. Confirm: name (kebab), endpoints, schema (`name:type` pairs), with mocks?
2. Run from the repo root: `./.gaia/cli/gaia scaffold service <name> --endpoints "..." --schema "..." [--mocks]`. It writes into the domain-layer folder under `app/services/`, found as the one folder there besides `api/` (shipped as `gaia/`, often renamed to the company or API name). If it refuses because several folders qualify, ask which one and rerun with `--layer <folder>`. Flags and schema types: `./.gaia/cli/gaia scaffold service --help`.
3. Verify: `pnpm typecheck` clean; if `--mocks`, run a single MSW round-trip in a vitest test.
4. Wire the service into the consuming route and page. Which data-loading variant applies is the rule in `frontend/.claude/skills/react-code/SKILL.md`; the `new-route` skill scaffolds a route bound to the service. Before wiring by hand, read how an existing service is wired and follow that pattern.

## Query options

When `@tanstack/react-query` is installed and the service has `get`, the scaffold also writes `queries.ts` (query keys and `queryOptions` factories over the request functions). To add it to an existing service, run `./.gaia/cli/gaia scaffold service <name> --queries-only [--layer <folder>]`; it writes only `queries.ts` and refuses when Query is not installed. Turn Query on with `./.gaia/cli/gaia init configure-data-layer --query true`.

## A new API domain

A backend with its own base URL or casing needs its own `create()` instance. Ask the backend's casing first (camelCase or snake_case). Then create `app/services/<new-layer>/api.ts` modelled on the shipped layer's `api.ts`, passing `create({isSnakeCaseEnabled: true})` for a snake_case backend, and scaffold with `--layer <new-layer>`; the scaffolder reads that flag to pick the mock data's key casing.

For an SDK-client backend (Supabase, Firebase), the Ky layer stays in place for any REST domain. An SDK-backed domain's request functions wrap the SDK's calls instead of `api`, and the data-loading rule applies unchanged.

The `clientLoader` and Query variants suit unauthenticated or cookie-authenticated APIs; a token or secret never goes into the root-loader `ENV`.

## See

- `wiki/concepts/API Service Pattern.md`, pattern source of truth
- `frontend/.claude/rules/api-service.md`, quick pointer
