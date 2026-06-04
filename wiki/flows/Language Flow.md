---
type: flow
status: active
created: 2026-04-20
updated: 2026-04-20
tags: [flow, i18n, language]
---

# Language Flow

How a user's language preference flows through the request lifecycle.

1. **i18next middleware** (`app/middleware/i18next.ts`): runs on every request, attaches an i18next instance and resolved language to `context`.
2. **Loader** (`root.tsx`):
   - `getLanguage(context)` reads the resolved language
   - Sets the `language` cookie via `languageCookie.serialize(language)` so the choice survives the redirect
3. **Client init**: the `App` effect calls `i18n.changeLanguage(language)` so client-side i18next matches.
4. **Switcher**: `LanguageSelect` component → `POST /actions/set-language` (`app/routes/actions+/set-language.ts`) writes the cookie and revalidates.

API requests that need the resolved language pass it per call via the `language` request option; there is no global API language state. See [[API Service Pattern]].

## Detection order

`accept-language-parser` is included so the middleware can fall back to the browser's `Accept-Language` header when no cookie is set.

See [[i18n]], [[Middleware]], [[Sessions]].
