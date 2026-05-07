---
type: module
status: active
created: 2026-05-07
updated: 2026-05-07
tags: [module, cli, scaffolding]
---

# CLI Scaffolding

The CLI provides subcommands for scaffolding new project artifacts: components, hooks, routes, and services. Each subcommand generates boilerplate code following GAIA patterns and inserts barrel exports automatically.

## Subcommands

**`gaia scaffold component`** — Generates a new React component with type definitions, example story file, and CSS module. Inserts export in `app/components/index.ts`.

**`gaia scaffold hook`** — Generates a new custom hook with JSDoc and TypeScript types. Inserts export in `app/hooks/index.ts`.

**`gaia scaffold route`** — Generates a new Remix route with action/loader signatures. Integrates with the route structure (group or top-level page).

**`gaia scaffold service`** — Generates a new service module with request/response types. Inserts export in `app/services/index.ts`.

## Shared infrastructure

All scaffolding subcommands use a common foundation:

- **Template loader** — Reads and interpolates scaffold templates (variables like `ComponentName`, `slug`, etc.). Templates live in `.gaia/cli/src/scaffold/templates/`.
- **Barrel insert** — Automatically updates barrel exports (`index.ts` files) when new files are scaffolded. Maintains alphabetical order and proper import syntax.

Templates follow GAIA naming conventions and include stubs for i18n keys, TypeScript types, and unit test structure.

## Integration

Triggered via skill `/new-component`, `/new-hook`, `/new-route`, `/new-service`, or manually with `gaia scaffold <type> <name>`.
