---
type: module
status: active
created: 2026-05-07
updated: 2026-05-07
tags: [module, cli, scaffolding]
---

# CLI Scaffolding

The CLI provides subcommands for scaffolding new project artifacts: components, hooks, routes, and services. Each subcommand generates boilerplate code following GAIA patterns.

## Subcommands

**`gaia scaffold component`** — Generates a new React component folder at `app/components/<Name>/` with `index.tsx`, optional `tests/index.test.tsx`, and an example Storybook story.

**`gaia scaffold hook`** — Generates a new custom hook file under `app/hooks/` with JSDoc, TypeScript types, and an optional Vitest test.

**`gaia scaffold route`** — Generates a new React Router 7 route with action/loader signatures. Integrates with the route structure (group or top-level page) and matching `app/pages/<Group>/<PageName>/` folder.

**`gaia scaffold service`** — Generates a new service module at `app/services/<name>/` with request functions, Zod schemas, URL constants, and (with `--mocks`) a matching `test/mocks/<name>/` MSW collection that's inserted into the test database barrel.

## Shared infrastructure

All scaffolding subcommands use a common foundation:

- **Template loader** — Reads and interpolates scaffold templates (variables like `ComponentName`, `slug`, etc.). Templates live in `.gaia/cli/templates/`.
- **Barrel insert (service `--mocks` only)** — Edits the test database barrel to register new mock collections. The component, hook, and route flows do not edit barrels — `app/components/`, `app/hooks/`, and `app/services/` have no top-level `index.ts` in this template.

Templates follow GAIA naming conventions and include stubs for i18n keys, TypeScript types, and unit test structure.

## Integration

Triggered via skill `/new-component`, `/new-hook`, `/new-route`, `/new-service`, or manually with `gaia scaffold <type> <name>`.
