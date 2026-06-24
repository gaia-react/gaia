---
type: decision
status: active
priority: 1
date: 2026-04-20
created: 2026-04-20
updated: 2026-06-24
tags: [decision, routing, architecture]
---

# Decision: Thin Routes, Fat Pages

Route files (`app/routes/**`) contain only loader, action, meta, and a one-line render of a page component. All UI lives in `app/pages/{Group}/{PageName}/`.

## Rationale

- Easy to scan a route file and see what data flows in/out
- Page components are easy to test in isolation (composeStory + Storybook stories)
- Sub-components can live next to the page that owns them; no cross-imports through routes
- Route group folders (`_public+`, `_session+`, `_legal+`, `actions+`, `resources+`) become the org chart; `actions+` and `resources+` hold form action endpoints (no UI)

## Meta pattern

Set `title`/`description` in the loader via `getInstance(context).t(...)`. Render the resulting `<title>` / `<meta>` either directly in the route component (index route) or pass them as props to the page component, which renders them (legal pages).

## Actions

Route action endpoints read `formData` and validate with a Zod schema's `safeParse`, returning `data(null, {status: 400})` (or a flattened-error payload) on failure. Conform's `parseWithZod` wires client-side validation in the `Form` components, not the server action endpoints.

## Enforcement

- `app/routes/**` rule (`.claude/rules/routes.md`) guides code review
- The `new-route` skill scaffolds in this exact pattern

See [[Routing]], [[Pages]], and the `routes` rule at `.claude/rules/routes.md`.
