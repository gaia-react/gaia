---
type: module
path: app/sessions.server/
status: active
language: typescript
purpose: Cookie session storage for language preference
created: 2026-04-20
updated: 2026-05-04
tags: [module, sessions, cookies]
---

# Sessions

`app/sessions.server/` contains cookie session-storage code that needs `SESSION_SECRET` for signing. The `.server` suffix excludes these from the client bundle; secrets never reach the browser.

Uses React Router 7's `createCookieSessionStorage`. Secret comes from `env.SESSION_SECRET` (Zod-validated).

## Theme cookie is **not** a session

The `__theme` cookie is read/written as a plain cookie via `app/utils/theme.server.ts` (using the `cookie` package directly), not session storage. It doesn't need signing; its value is non-sensitive (light/dark/system). See [[Theme Flow]] and [[Dark Mode Modernization]] for the full pipeline.

## Adding auth sessions

`_session+/_layout.tsx` is the designated hook point for consumer auth. Add your own `createCookieSessionStorage` (or use Clerk, Supabase, Auth0 SDKs) in `app/sessions.server/` and wire a loader into that layout file. See [[Routing]] for the route group overview.

For the current bundled session files, query Serena (`.claude/rules/code-search.md`).

## See also

- [[Theme Flow]]: full SSR→client theme lifecycle
- [[Language Flow]]: language detection + persistence
- [[Routing]]: `_session+/` hook point
