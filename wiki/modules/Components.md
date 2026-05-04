---
type: module
path: app/components/
status: active
language: typescript
purpose: Shared UI components used across pages
created: 2026-04-20
updated: 2026-05-04
tags: [module, components]
---

# Components

`app/components/` holds shared UI components. Page-specific UI lives in `app/pages/` (see [[Pages]]).

## Component folder convention (ESLint-enforced)

Each component lives in `app/components/{PascalName}/`:

- `index.tsx` — main component
- `styles.module.css` — CSS module styles (when needed)
- `types.ts` — types (when needed)
- `utils.ts` — utility functions (when needed)
- `assets/` — component-specific assets
- `hooks/` — component-specific hooks
- `state/` — component-specific Context/Provider
- `tests/` — Vitest tests + Storybook stories

> [!key-insight] Co-location with a `tests/` folder
> Co-locating everything next to the component keeps things discoverable, but flat sibling files get messy. The dedicated `tests/` folder (for stories + tests) restored the tidiness without sacrificing co-location. Same pattern extends to `assets/`, `hooks/`, `state/`. ESLint enforces this.

## Lifting components

> [!quote]
> "Lift" a child component only up to its highest level where it is shared.

Not strict, but a strong default. Refactoring is easier when the folder hierarchy mirrors actual usage.

## Naming conventions

- PascalCase folder names
- `index.tsx` for the main file (configurable in ESLint if you prefer `ComponentName.tsx`)

## Where to look up the inventory

The current set of bundled components changes over time. Use Serena (`.claude/rules/code-search.md`) to list `app/components/` rather than maintaining a roster here. Notable exceptions:

- `Form/` — the headline feature with its own deep dives ([[Form Components]])
- `ThemeSwitch` lives at `app/routes/resources+/theme-switch.tsx` (co-located with its action and hook), not under `app/components/`. See [[Theme Flow]].

See [[Component Testing]] for the `composeStory` test pattern.
