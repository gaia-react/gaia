---
type: module
path: app/utils/
status: active
language: typescript
purpose: Shared helpers used throughout the app: pure functions plus a few React-context utilities
created: 2026-04-20
updated: 2026-06-24
tags: [module, utils]
---

# Utils

`app/utils/` holds shared helpers. Most are pure functions: array, date, dom, environment, function, http (split `http.ts` / `http.server.ts`), object, string. A few are React-context utilities: `nonce` (`NonceProvider`, `useNonce`), `request-info` (`useRequestInfo`, `useOptionalRequestInfo`), and `theme.server` (`getTheme`, `setTheme`). Each should be well-named, self-explanatory, and unit-tested.

## Convention

`.server.ts` suffix excludes a helper from the client bundle when it touches Node-only APIs; the server-only helpers are `http.server.ts` and `theme.server.ts` (the latter reads `cookie` and `~/env.server`). Trivial wrappers around native APIs may not warrant a test; use judgment.

For the current helper inventory and signatures, query Serena (`.claude/rules/code-search.md`).
