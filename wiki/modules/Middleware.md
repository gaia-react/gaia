---
type: module
path: app/middleware/
status: active
language: typescript
purpose: React Router 7 middleware
created: 2026-04-20
updated: 2026-05-04
tags: [module, middleware]
---

# Middleware

`app/middleware/` is for [React Router 7 middleware](https://reactrouter.com/how-to/middleware).

## Hook point, not a feature surface

Middleware is the right home for per-request setup that loaders shouldn't have to repeat; i18n is the canonical example. Add new middleware here when a concern needs to run on every request before any loader executes.

The current i18next middleware exposes `i18nextMiddleware` (registered in `root.tsx`), `getLanguage(context)`, and `getInstance(context)` for server-side `t()` calls in loaders. See [[i18n]] for usage. For the current file inventory and signatures, query Serena (`.claude/rules/code-search.md`).
