---
type: decision
status: active
priority: 2
date: 2026-04-26
created: 2026-04-26
updated: 2026-04-26
tags: [decision, theme, dark-mode]
---

# Decision: Modernize Dark Mode (Cookie + Client Hints)

GAIA's original dark-mode implementation was inherited from a 2022-era pattern: a React `ThemeProvider` context, `localStorage` for client-side persistence, a cookie for SSR, and a 30+ line inline blocking script (`clientThemeCode`) to repaint the wrong-themed page on first paint. We migrated to the Epic Stack pattern: cookie-as-truth + `@epic-web/client-hints` + optimistic `useFetchers()` UI.

## Why

The old implementation had three real problems:

1. **State-sync drift.** Four sources of truth (cookie, `localStorage`, React state, OS `matchMedia`) drifted out of sync. The provider's persistence `useEffect` ran only on mount, so a click that flipped React state did not reliably `submit()` to the cookie route, meaning toggles could fail to persist. A `setTimeout(saveInitialTheme)` workaround masked the same race on first render.
2. **Inline blocking script.** `clientThemeCode` ran synchronously before hydration to set the right class on `<html>` and prevent FOUC. With the cookie as truth and SSR rendering the class directly, the script is unnecessary, and its absence improves the CSP story.
3. **`localStorage` for theme.** `localStorage` is a duplicate of the cookie. With the cookie already round-tripping every request, `localStorage` adds nothing except a way for the two to disagree.

## What changed

- **Added** `app/utils/theme.server.ts`, `app/utils/request-info.ts`, `app/hooks/useTheme.ts`.
- **Added** `app/routes/resources+/theme-switch.tsx`: co-located action, schema, hooks, and `ThemeSwitch` component.
- **Removed** `app/state/theme.tsx`, `app/sessions.server/theme.ts`, `app/routes/actions+/set-theme.ts`, `app/components/ThemeSwitcher/index.tsx`.
- **Updated** `app/root.tsx` loader to return `requestInfo`. `<State>` no longer carries `theme`.
- **Updated** `app/components/Document/index.tsx` to call `useOptionalTheme()` and render `<ClientHintCheck/>` in `<head>`.
- **Updated** `app/components/Header/index.tsx` to use the new `ThemeSwitch`.
- **Updated** `app/components/Errors/RootErrorBoundary/index.tsx` to drop `getPreferredTheme()`.

## Trade-offs

- **3-state cycle (`light → dark → system → light`).** The Epic Stack pattern includes `'system'` (delete cookie). The previous GAIA toggle was 2-state. We kept the 3-state cycle in the action/schema; the visible UI still shows only sun/moon icons (resolved theme), but the cycle now passes through `system` to let users follow the OS again. This is a minor behavioral change.
- **Cookie name preserved.** We kept `__theme` (vs Epic Stack's `theme`) to avoid invalidating existing user preferences after deploy.
- **`@conform-to/*` not adopted.** GAIA already has Conform installed for forms, but the theme action uses plain Zod to keep the resource route minimal. Forms with user-facing validation continue to use Conform.

## Bugs the migration fixes

- **Toggle-not-persisted.** The mount-only `useEffect` in `ThemeProvider` could miss subsequent toggles. Now the action writes the cookie on every submit; nothing depends on `useEffect` firing.
- **Hydration mismatch on first paint.** Removed `clientThemeCode`; SSR now emits the right class directly when the cookie is set. `suppressHydrationWarning` covers the brief revalidation window for OS-driven first visits.
- **`localStorage` drift.** Eliminated.

## Storybook

`@vueless/storybook-dark-mode` continues to work; it toggles the `dark` class on `<html>`, which Tailwind's `@custom-variant dark` matches. No story changes required.

See [[Theme Flow]], [[Styles]], [[State]].
