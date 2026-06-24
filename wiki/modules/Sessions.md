---
type: module
path: app/sessions.server/
status: active
language: typescript
purpose: Server-only signed cookie for the language preference
created: 2026-04-20
updated: 2026-06-24
tags: [module, sessions, cookies]
---

# Sessions

`app/sessions.server/` holds server-only cookie code that needs `SESSION_SECRET` for signing. The `.server` suffix excludes it from the client bundle; secrets never reach the browser.

The shipped file, `language.ts`, defines a signed `lng` cookie via React Router 7's `createCookie` to persist the language preference. The secret comes from `env.SESSION_SECRET` (Zod-validated). For full session storage (auth, flash messages), swap in `createCookieSessionStorage`.

## Theme cookie is **not** a session

The `__theme` cookie is read/written as a plain cookie via `app/utils/theme.server.ts` (using the `cookie` package directly), not session storage. It doesn't need signing; its value is non-sensitive (light/dark/system). See [[Theme Flow]] and [[Dark Mode Modernization]] for the full pipeline.

## Adding auth sessions

`_session+/` is the designated hook point for consumer auth. Add your own `createCookieSessionStorage` (or use Clerk, Supabase, Auth0 SDKs) in `app/sessions.server/` and wire a loader into a `_layout.tsx` you create there. See [[Routing]] for the route group overview.

For the current bundled session files, query Serena (`.claude/rules/code-search.md`).

## See also

- [[Theme Flow]]: full SSR→client theme lifecycle
- [[Language Flow]]: language detection + persistence
- [[Routing]]: `_session+/` hook point
