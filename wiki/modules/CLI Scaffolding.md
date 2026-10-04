---
type: module
status: active
created: 2026-05-07
updated: 2026-10-04
tags: [module, cli, scaffolding]
---

# CLI Scaffolding

The CLI provides subcommands for scaffolding new project artifacts: components, hooks, routes, and services. Each subcommand generates boilerplate code following the project's patterns.

## Subcommands

**`gaia scaffold component`**: Generates a new React component folder at `frontend/app/components/<kebab-name>/` (the name may be kebab-case or PascalCase; the folder is always its kebab-case form) with `index.tsx`, `tests/index.test.tsx`, and (unless `--no-story` is passed) `tests/index.stories.tsx`. Flags: `--no-story`, `--props "name:type,..."` (typed props annotated on the destructured parameter instead of a parameterless component), `--parent <dir>` (an existing parent under `frontend/app/components/` or `frontend/app/pages/<path>/`; `components/ui` and anything outside those two trees is refused), `--json`. Layout is owned by `frontend/.claude/rules/coding-guidelines-react.md`.

**`gaia scaffold hook`**: Generates a custom hook at `frontend/app/hooks/use-<kebab>.ts` plus a matching Vitest test at `frontend/app/hooks/tests/use-<kebab>.test.ts`; the name may be `use-kebab` or `useCamel`, and the export is the camelCase form. The default body is a `// TODO: implement` stub with a `void` return; `--params` and `--returns` add a typed signature. Flags: `--params`, `--returns`, `--json`.

**`gaia scaffold route`**: Generates a new React Router route file at `frontend/app/routes/<group>.<name>.tsx` plus a matching page folder at `frontend/app/pages/<name>/` containing `page.tsx`, `tests/page.test.tsx`, and `tests/page.stories.tsx`; the route file imports `~/pages/<name>/page`. Reserved page-folder names (`tests`, `hooks`, `state`, `utils`, `assets`) are refused. `--group <_public|_session>` is required (the command exits otherwise); loader and action stubs are opt-in via `--loader` and `--action`. Flags: `--group` (required), `--loader`, `--action`, `--i18n`, `--dry-run`, `--json`.

**`gaia scaffold service`**: Generates a new service module at `frontend/app/services/<layer>/<name>/`, where `<layer>` is the domain-layer folder (`gaia/` until you rename it; the CLI finds it as the one folder besides `api/`), with request functions (`requests.ts`), Zod schemas (`parsers.ts`), types (`types.ts`), URL constants (`urls.ts`), and a barrel (`index.ts`). With `--mocks` it also emits a matching `frontend/test/mocks/<name>/` MSW collection and inserts it alphabetically into the test database barrel (`frontend/test/mocks/database.ts`). Flags: `--endpoints "get,post,put,delete"` (required), `--schema "id:string,name:string"` (required), `--layer <folder>` (only when several folders qualify), `--mocks`, `--json`.

## Shared infrastructure

All scaffolding subcommands use a common foundation:

- **Template loader**: Reads and interpolates scaffold templates (variables like `ComponentName`, `slug`, etc.) from `.gaia/cli/templates/`.
- **Idempotency**: All scaffolders write via `writeFileIfAbsent`. A byte-identical existing file is reported as skipped (re-runs are safe), but a file that exists with different content makes the write throw, protecting customizations. The component flow additionally errors when its `--parent` target directory is missing; the hook, route, and service flows create any missing directories on demand (`mkdir -p`).
- **Barrel insert**: The service `--mocks` flow registers new mock collections in the test database barrel (`frontend/test/mocks/database.ts`), and the route `--i18n` flow inserts the new page locale alphabetically into `frontend/app/languages/en/pages/index.ts`. The component and hook flows edit no barrels; `frontend/app/components/` and `frontend/app/hooks/` have no top-level `index.ts` in this template.

Templates follow the project's naming conventions and include TypeScript types and unit-test structure. The route scaffolder additionally emits an i18n locale file and wires the locale barrel when `--i18n` is passed. A `--loader` route reads its copy from the locale only under `--i18n`; without it the loader returns placeholder literals, so the route typechecks without locale keys.

## Integration

Triggered via skill `/new-component`, `/new-hook`, `/new-route`, `/new-service`, or manually with `gaia scaffold <type> <name>`.
