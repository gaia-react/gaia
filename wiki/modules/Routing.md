---
type: module
path: app/routes/
status: active
language: typescript
purpose: File-based routing using @react-router/fs-routes on top of React Router
depends_on:
  - '[[fs-routes]]'
  - '[[React Router]]'
created: 2026-04-20
updated: 2026-09-29
tags: [module, routing]
---

# Routing

GAIA uses [[fs-routes]] (React Router's own file convention) configured in `app/routes.ts`. You can switch to standard React Router routing if you prefer.

## Route group convention

Routes are flat, dot-delimited files directly in `app/routes/`; there are no `+`-suffixed folders. A leading `_` marks a pathless layout: `_public.tsx` is the layout, `_public.<name>.tsx` its children, `_public._index.tsx` the index route under it. Group prefixes:

- `_public`: home, marketing, public content (no auth)
- `_session`: hook point for auth-guarded app (intentionally a stub)
- `_legal`: terms of service, privacy
- `actions`: root-level form actions (no UI), e.g. `actions.set-language.ts`
- `resources`: no-UI resource routes that handle a form submission and write a cookie or return data, e.g. `resources.theme-switch.tsx`

Both `actions.*` and `resources.*` hold no-UI server-side form endpoints. Use `actions.*` for a route whose job is to mutate state and redirect; use `resources.*` for a route that also serves as a data/cookie endpoint a fetcher posts to without navigating.

`app/routes/_session/` ships only a `README.md`. The folder holds no `route.*` or `index.*` module, so fs-routes skips it entirely; it isn't a route. To guard the group, add a `_session.tsx` layout route to `app/routes/` with a loader that throws `redirect('/login')` when the user isn't authenticated, and add children as `app/routes/_session.<name>.tsx`; every route nested under it then inherits the guard. Choose any auth provider: Supabase, Clerk, Auth0, custom sessions. The README walks through the setup.

`app/routes.ts` fails loudly at startup if a leftover `+`-suffixed folder still exists under `app/routes/`, naming the offending folder and pointing at the flat dot-delimited rename.

## Thin Routes Convention

> [!key-insight] Routes are thin
> Route files in `app/routes/` handle only **loader, action, meta, and rendering the page component**. All UI lives in `app/pages/`. This keeps routes easy to scan and pages easy to test in isolation. See [[Thin Routes]].

`/new-route` scaffolds routes in this shape: route file, page folder, tests, story, i18n keys, all in one pass. Run the scaffold from the repo root; output paths resolve from the working directory.

### Scaffold naming conventions

The page folder and its component are named `<PascalName>Page` (e.g. `DashboardPage/index.tsx`). The route component exported from the route file is named `<PascalName>Route`. The two identifiers exist at different layers: `<PascalName>Route` is thin (loader/action/meta only), `<PascalName>Page` holds the UI.

### Scaffold flags

- `--group _public|_session`: required; writes the route file at `app/routes/<group>.<name>.tsx`
- `--loader`: emit a loader stub
- `--action`: emit an action stub
- `--i18n`: emit a flat `<kebab>.ts` locale file and wire it into the locale barrel (fails loudly if the barrel is absent)
- `--dry-run`: preview what would be written without touching the filesystem

### Fetcher action paths

`app/action-paths.ts` exports `ACTION_PATHS`, the single source of truth for every path a fetcher submits to under `actions.*`/`resources.*` (e.g. `themeSwitch: '/resources/theme-switch'`). React Router derives each path from its route file's name, so a hand-copied literal at a call site goes stale silently the moment that file renames: the submission 404s, an optimistic update stops applying while the POST still succeeds, or a story renders the router's error boundary. The component, the optimistic-mode matcher, and the test router stub all read `ACTION_PATHS` instead of keeping their own copies, and `test/action-paths.test.ts` resolves the app's real route config to assert every declared path still resolves to a served route.

## Server-side i18n in loaders

Use `getInstance()` from the i18next middleware to translate meta tags. See [[i18n]].

## Actions

Route actions validate form data with plain [[Zod]]: build a `z.object({...})` schema and call `Schema.safeParse(...)` on the `FormData` entries, returning `data(null, {status: 400})` on failure. ([[Conform]]'s `parseWithZod` is the client-side form-validation helper used in `onValidate`, not in route actions.)

## Where to look up the inventory

For the current set of routes and bundled `actions.*` endpoints, query Serena (`.claude/rules/code-search.md`).
