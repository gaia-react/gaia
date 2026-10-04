---
type: module
path: frontend/app/components/
status: active
language: typescript
purpose: Shared UI components used across pages
created: 2026-04-20
updated: 2026-10-04
tags: [module, components]
---

# Components

`frontend/app/components/` holds shared UI components. Page-specific UI lives in `frontend/app/pages/` (see [[Pages]]).

## Component folder convention (ESLint-enforced)

Each component lives in its own kebab-case folder under `frontend/app/components/`. Folder naming, the `ui/` exception, and story and test placement are owned by `frontend/.claude/rules/coding-guidelines-react.md`. A component folder holds:

- `index.tsx`: main component
- `styles.module.css`: CSS module styles (when needed)
- `types.ts`: types (when needed)
- `utils.ts`: utility functions (when needed)
- `assets/`: component-specific assets
- `hooks/`: component-specific hooks
- `state/`: component-specific Context/Provider
- `tests/`: Vitest tests + Storybook stories

> [!key-insight] Co-location with a `tests/` folder
> Co-locating everything next to the component keeps things discoverable, but flat sibling files get messy. The dedicated `tests/` folder (for stories + tests) restored the tidiness without sacrificing co-location. Same pattern extends to `assets/`, `hooks/`, `state/`. ESLint enforces this.

## Lifting components

> [!quote]
> "Lift" a child component only up to its highest level where it is shared.

Not strict, but a strong default. Refactoring is easier when the folder hierarchy mirrors actual usage.

## Naming conventions

- Folder names, `index.tsx`, and the default export name: see `frontend/.claude/rules/coding-guidelines-react.md`

## Where to look up the inventory

The current set of bundled components changes over time. Use Serena (`.claude/rules/code-search.md`) to list `frontend/app/components/` rather than maintaining a roster here. Notable exceptions:

- `form/`: the headline feature with its own deep dives ([[Form Components]])
- `ThemeSwitch` lives at `frontend/app/components/theme-switch/`. Its resource-route action and Zod schema live separately at `frontend/app/routes/resources.theme-switch.tsx`, and its theme hooks live at `frontend/app/hooks/use-theme.ts`. See [[Theme Flow]].

See [[Component Testing]] for the `composeStory` test pattern.
