---
type: flow
status: active
created: 2026-04-20
updated: 2026-06-24
tags: [flow, i18n, language]
---

# Language Flow

How a user's language preference flows through the request lifecycle.

1. **i18next middleware** (`app/middleware/i18next.ts`): runs on every request, attaches an i18next instance and resolved language to `context`.
2. **Loader** (`root.tsx`):
   - `getLanguage(context)` reads the resolved language
   - Sets the `lng` cookie via `languageCookie.serialize(language)` so the choice survives the redirect
   - Renders `<html lang={i18n.language}>` so the client can pick up the SSR language
3. **Client init** (`app/entry.client.tsx`): i18next inits with `initReactI18next` + `LanguageDetector`, `detection: {caches: [], order: ['htmlTag']}`, and `ns: getInitialNamespaces()`, so the client reads the language from the `<html lang>` attribute rather than the cookie or navigator. The `App` effect then calls `i18n.changeLanguage(language)` to keep client-side i18next in sync on navigation.
4. **Switcher**: `LanguageSelect` component → `POST /actions/set-language` (`app/routes/actions+/set-language.ts`) validates the language and `redirectUrl`, sets the `lng` cookie, and returns a `replace()` redirect to that URL so loaders rerun with the new language.

API requests that need the resolved language pass it per call via the `language` request option; there is no global API language state. See [[API Service Pattern]].

## Detection order

The middleware sets no custom `order`, so remix-i18next applies its default server-side detection order: a `?lng=<code>` query param wins first (overriding a stored cookie for that request), then the `lng` cookie, then the `Accept-Language` header (parsed by remix-i18next's built-in Accept-Language parser), then the `en` fallback. The full default order also includes a `session` step between cookie and header; it is a silent no-op here because the middleware configures no `sessionStorage`.

## Cookie

The persisted cookie is named `lng` (`createCookie('lng', ...)` in `app/sessions.server/language.ts`): `httpOnly`, `maxAge` one year, `sameSite: 'lax'`, and `secure` only when `NODE_ENV` is `production` (Safari rejects a `secure` cookie over plain HTTP in dev).

See [[i18n]], [[Middleware]], [[Sessions]].
