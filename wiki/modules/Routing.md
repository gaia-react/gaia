---
type: module
path: app/routes/
status: active
language: typescript
purpose: File-based routing using remix-flat-routes on top of React Router 7
depends_on: [[remix-flat-routes]], [[React Router 7]]
created: 2026-04-20
updated: 2026-05-04
tags: [module, routing]
---

# Routing

GAIA uses [[remix-flat-routes]] on top of [[React Router 7]] for file-based routing. The adapter lives in `app/routes.ts`. You can switch to standard React Router 7 routing if you prefer.

## Route group convention

Routes are organized using flat-routes folder syntax — `_` prefix + `+` suffix marks a folder as a layout/route group:

- `_public+` — home, marketing, public content (no auth)
- `_session+` — hook point for auth-guarded app (intentionally a stub)
- `_legal+` — terms of service, privacy
- `actions+` — root-level form actions (no UI)

`_session+/_layout.tsx` is **intentionally empty**. Add a loader that throws `redirect('/login')` if the user isn't authenticated. All routes nested under `_session+/` inherit the guard. Choose any auth provider: Supabase, Clerk, Auth0, custom sessions.

## Thin Routes Convention

> [!key-insight] Routes are thin
> Route files in `app/routes/` handle only **loader, action, meta, and rendering the page component**. All UI lives in `app/pages/`. This keeps routes easy to scan and pages easy to test in isolation. See [[Thin Routes]].

`/new-route` scaffolds routes in this shape — route file, page folder, tests, story, i18n keys, all in one pass.

## Server-side i18n in loaders

Use `getInstance()` from the i18next middleware to translate meta tags. See [[i18n]].

## Actions

Form actions use [[Conform]] + [[Zod]] for validation: `parseWithZod(formData, {schema})`.

## Where to look up the inventory

For the current set of routes and bundled `actions+` endpoints, query Serena (`.claude/rules/code-search.md`).
