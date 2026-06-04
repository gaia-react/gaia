---
type: module
path: app/pages/
status: active
language: typescript
purpose: Page-specific UI components, organized by route group
created: 2026-04-20
updated: 2026-05-04
tags: [module, pages]
---

# Pages

`app/pages/` holds page-specific components, the UI that the thin route file in `app/routes/` renders.

This is **different** from `app/components/`, which holds shared UI used across pages. The split is the load-bearing convention for [[Thin Routes]]: routes stay tiny (loader/action/meta only), pages own all UI and are independently testable.

## Folder convention

Pages are grouped by route group: `app/pages/{Group}/{PascalName}/`. Legal pages typically live as static JSX directly in the route file; no `pages/Legal/` folder by convention. When you add auth-guarded pages behind `_session+/`, ask Claude to scaffold a `Session/` folder; `/new-route` handles the wiring.

Within a page folder: `index.tsx`, `tests/index.test.tsx` (Vitest via `composeStory`), `tests/index.stories.tsx` (Storybook). Sub-components in their own PascalCase folders, lifted only as high as needed (same lift rule as [[Components]]).

## Standard page shape

Pages are `FC` components with a default export. All user-facing strings use `useTranslation('pages', {keyPrefix})`; the namespace is always `'pages'` and `keyPrefix` scopes keys to the page. Add keys to every locale folder under `app/languages/`. `/new-route` emits this shape. See [[i18n]] for translation conventions.

For the current page inventory, query Serena (`.claude/rules/code-search.md`).
