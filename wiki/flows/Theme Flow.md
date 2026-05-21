---
type: flow
status: active
created: 2026-04-20
updated: 2026-05-21
tags: [flow, theme, dark-mode]
---

# Theme Flow (Dark Mode)

Dark mode is wired through cookie + OS `matchMedia`. The cookie is the source of truth; SSR renders `<html class="dark">` directly. A synchronous pre-paint inline script handles the first-ever visit so the page renders once with the correct theme.

## Pipeline

1. **Cookie** — `app/utils/theme.server.ts` reads/writes the `__theme` cookie (httpOnly) via the plain `cookie` package. Values: `'light'`, `'dark'`, or absent (= follow OS).
2. **Pre-paint script** — `app/components/Document/index.tsx` renders a synchronous inline `<script>` in `<head>` when no explicit cookie preference exists. The script calls `window.matchMedia('(prefers-color-scheme: dark)')` and adds the `dark` class to `<html>` before first paint — no reload, no flash.
3. **Loader** — `app/root.tsx` returns `requestInfo: {origin, path, userPrefs: {theme}}`.
4. **Document** — `app/components/Document/index.tsx` calls `useOptionalTheme()` and renders `<html className={theme === 'dark' && 'dark'}>` with `suppressHydrationWarning`. The pre-paint script owns the `dark` class during hydration; React takes over post-hydration without a flash.
5. **System theme hook** — `app/routes/resources+/theme-switch.tsx` exports `useSystemTheme()` via `useSyncExternalStore`. Returns `undefined` on the server/first-hydration render (matching SSR) then resolves to the live `matchMedia` value on the client. Tracks OS changes reactively.
6. **Switcher** — `app/routes/resources+/theme-switch.tsx` exports the `ThemeSwitch` component, the `useOptionalTheme` / `useOptimisticThemeMode` hooks, and the action that writes the cookie.
7. **Storybook** — `@vueless/storybook-dark-mode` toggles the same `dark` class on `<html>` (Tailwind's `@custom-variant dark` matches it). No story changes required.

## Theme priority (`useOptionalTheme` resolver)

```text
optimistic in-flight submission ('light' | 'dark' | 'system')
  → user cookie preference
    → OS matchMedia via useSyncExternalStore
```

`useOptimisticThemeMode()` reads pending `useFetchers()` and returns the in-flight theme without Zod. `'system'` falls through to the OS `matchMedia` value.

## Hydration safety

- The cookie is `httpOnly` — JavaScript cannot read it. The inline script runs only when there is no explicit preference.
- During hydration `useSyncExternalStore` returns `undefined` (server snapshot), so the hydration render matches SSR HTML.
- `suppressHydrationWarning` on `<html>` prevents React from patching the class set by the inline script.
- Immediately after hydration `useSyncExternalStore` re-renders with the real `matchMedia` value — no flash.

## No-JS path

The `<fetcher.Form>` falls back to a normal HTML POST. The action accepts an optional `redirectTo` and replies with `redirect()` so the browser navigates and re-runs the loader, picking up the new cookie value.

See [[State]], [[Sessions]], [[Storybook Stories]], [[Styles]], [[Dark Mode Modernization]].
