---
type: flow
status: active
created: 2026-04-20
updated: 2026-06-24
tags: [flow, theme, dark-mode]
---

# Theme Flow (Dark Mode)

Dark mode is wired through cookie + OS `matchMedia`. The cookie is the source of truth; SSR renders `<html class="dark">` directly. A synchronous pre-paint inline script handles the first-ever visit so the page renders once with the correct theme.

## Pipeline

1. **Cookie**: `app/utils/theme.server.ts` reads/writes the `__theme` cookie (httpOnly) via the plain `cookie` package. Values: `'light'`, `'dark'`, or absent (= follow OS). An explicit theme sets the cookie with a one-year `maxAge` (`31_536_000`); selecting `'system'` clears it (`maxAge: -1`, same `httpOnly`/`sameSite: 'lax'`/`secure` attributes), so following the OS is represented by the cookie's absence.
2. **Pre-paint script**: `app/components/Document/index.tsx` renders a synchronous inline `<script>` in `<head>` when no explicit cookie preference exists. The script calls `window.matchMedia('(prefers-color-scheme: dark)')` and adds the `dark` class to `<html>` before first paint; no reload, no flash.
3. **Loader**: `app/root.tsx` returns `requestInfo: {origin, path, userPrefs: {theme}}`.
4. **Document**: `app/components/Document/index.tsx` calls `useOptionalTheme()` and renders `<html className={theme === 'dark' && 'dark'}>` with `suppressHydrationWarning`. The pre-paint script owns the `dark` class during hydration; React takes over post-hydration without a flash.
5. **System theme hook**: `app/hooks/useTheme.ts` exports `useSystemTheme()` via `useSyncExternalStore`. Returns `undefined` on the server/first-hydration render (matching SSR) then resolves to the live `matchMedia` value on the client. Tracks OS changes reactively.
6. **Switcher**: `app/components/ThemeSwitch/index.tsx` is the switcher component. `app/hooks/useTheme.ts` exports `useOptionalTheme`, `useSystemTheme`, and `useOptimisticThemeMode`. `app/routes/resources+/theme-switch.tsx` exports `ThemeFormSchema` and the `action` that writes the cookie.
7. **Storybook**: `@vueless/storybook-dark-mode` toggles the same `dark` class on `<html>` (Tailwind's `@custom-variant dark` matches it). No story changes required.

## Theme priority (`useOptionalTheme` resolver)

```text
optimistic in-flight submission ('light' | 'dark' | 'system')
  → user cookie preference
    → OS matchMedia via useSyncExternalStore
```

`useOptimisticThemeMode()` reads pending `useFetchers()` and returns the in-flight theme without Zod. `'system'` falls through to the OS `matchMedia` value.

## Hydration safety

- The cookie is `httpOnly`; JavaScript cannot read it. The inline script runs only when there is no explicit preference.
- During hydration `useSyncExternalStore` returns `undefined` (server snapshot), so the hydration render matches SSR HTML.
- `suppressHydrationWarning` on `<html>` prevents React from patching the class set by the inline script.
- Immediately after hydration `useSyncExternalStore` re-renders with the real `matchMedia` value; no flash.

## No-JS path

The `<fetcher.Form>` falls back to a normal HTML POST. The shipped `ThemeSwitch` posts only the `theme` field, so the action returns a `data()` response with the `set-cookie` header and no navigation. The action also accepts an optional `redirectTo` and replies with `redirect()` when present (so the browser navigates and re-runs the loader), but the switcher never sends that field.

See [[State]], [[Sessions]], [[Storybook Stories]], [[Styles]], [[Dark Mode Modernization]].
