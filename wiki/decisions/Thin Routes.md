---
type: decision
status: active
priority: 1
date: 2026-04-20
created: 2026-04-20
updated: 2026-10-05
tags: [decision, routing, architecture]
---

# Decision: Thin Routes, Fat Pages

Route files (`frontend/app/routes/**`) contain only data exports and a one-line render of a page component: `loader`, `clientLoader`, `action`, `clientAction`, `HydrateFallback`, and `meta`. No hooks live in a route module. All UI, and every hook, lives in a folder under `frontend/app/pages/` derived from the route path (layout owned by `frontend/.claude/rules/coding-guidelines-react.md`). The page types its loader data with `LoaderData` from its own folder's `types.ts` and never imports from a route (the lint boundary forbids it). Which loader to export is the decision in [[Data Loading]].

## Rationale

- Easy to scan a route file and see what data flows in/out
- Page components are easy to test in isolation (Storybook stories with play functions)
- Sub-components can live next to the page that owns them; no cross-imports through routes
- Route group prefixes organize the routes; see [[Routing]] for the naming convention

## Meta pattern

Set `title`/`description` in the loader via `getInstance(context).t(...)`. Render the resulting `<title>` / `<meta>` either directly in the route component (index route) or pass them as props to the page component, which renders them (legal pages).

## Actions

Scaffolded route actions and client actions validate with `parseWithZod` from `@conform-to/zod/v4` against the service's input schema and pass only `submission.value` to the request function; the failure branch returns `submission.reply()`. Simple no-UI endpoints (`actions.*`, `resources.*`) may validate a bare `FormData` with a Zod schema directly. See [[Form Submit Flow]].

## Enforcement

- `frontend/app/routes/**` rule (`frontend/.claude/rules/routes.md`) guides code review
- The `new-route` skill scaffolds in this exact pattern

See [[Routing]], [[Pages]], and the `routes` rule at `frontend/.claude/rules/routes.md`.
