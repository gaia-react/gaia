---
type: module
path: frontend/app/pages/
status: active
language: typescript
purpose: Page-specific UI components, organized by route path
created: 2026-04-20
updated: 2026-10-07
tags: [module, pages]
---

# Pages

`frontend/app/pages/` holds page-specific components, the UI that the thin route file in `frontend/app/routes/` renders.

This is **different** from `frontend/app/components/`, which holds shared UI used across pages. The split is the load-bearing convention for [[Thin Routes]]: routes stay tiny (`loader`, `clientLoader`, `action`, `clientAction`, `HydrateFallback`, `meta`, and a one-line render), pages own all UI and every hook and are independently testable.

## Folder convention

Each page lives in a folder derived from its route path, with the page component in `page.tsx` (for example `frontend/app/pages/index/page.tsx`). Route files stay thin and render the page component. `/new-route` handles the wiring. The derivation rule and the full layout are owned by `frontend/.claude/rules/coding-guidelines-react.md`.

Within a page folder: `page.tsx`, plus `tests/page.stories.tsx`, whose play functions are the page's tests ([[Stories as Tests]]). The stories file is co-located by convention but not present on every page: only `pages/index` ships a `tests/` folder. Sub-components live in their own kebab-case folders, lifted only as high as needed (same lift rule as [[Components]]).

## Standard page shape

Pages are components with inline-typed props and a default export. `/new-route` emits this shape. See [[i18n]] for the namespace and `keyPrefix` conventions.

A page that reads route data calls its hook itself (`useLoaderData<LoaderData>()`, or `useSuspenseQuery` for a Query route) and types the data with `LoaderData` from `types.ts` in its own folder. It never imports from a route, type-only imports included, because the lint boundary forbids it. See [[Data Loading]].

A page may also accept loader-derived data as props and own its document head: it takes a `{title, description}` props type and renders `<title>` and `<meta name="description">` itself; the thin route resolves those strings in its loader and passes them down.

For the current page inventory, query Serena (`.claude/rules/code-search.md`).
