---
type: module
path: app/pages/
status: active
language: typescript
purpose: Page-specific UI components, organized by route group
created: 2026-04-20
updated: 2026-06-24
tags: [module, pages]
---

# Pages

`app/pages/` holds page-specific components, the UI that the thin route file in `app/routes/` renders.

This is **different** from `app/components/`, which holds shared UI used across pages. The split is the load-bearing convention for [[Thin Routes]]: routes stay tiny (loader/action/meta only), pages own all UI and are independently testable.

## Folder convention

Pages are grouped by route group: `app/pages/{Group}/{PascalName}/`. Legal pages follow the same convention under `app/pages/Legal/{PageName}/`; the route files in `_legal+/` stay thin and render the page component. When you add auth-guarded pages behind `_session+/`, ask Claude to scaffold a `Session/` folder; `/new-route` handles the wiring.

Within a page folder: `index.tsx`, plus `tests/index.test.tsx` (Vitest via `composeStory`) and `tests/index.stories.tsx` (Storybook). The test/story files are co-located by convention but not present on every page: only `Public/IndexPage` ships a `tests/` folder (story only, no test). Sub-components in their own PascalCase folders, lifted only as high as needed (same lift rule as [[Components]]).

## Standard page shape

Pages are `FC` components with a default export. All user-facing strings use `useTranslation('pages', {keyPrefix})`; the namespace is always `'pages'` and `keyPrefix` scopes keys to the page. Add keys to every locale folder under `app/languages/`. `/new-route` emits this shape. See [[i18n]] for translation conventions.

A page may also accept loader-derived data as props and own its document head. The legal pages take a `{title, description}` props type and render `<title>` and `<meta name="description">` themselves; the thin route resolves those strings in its loader and passes them down.

For the current page inventory, query Serena (`.claude/rules/code-search.md`).
