---
type: decision
status: active
priority: 2
date: 2026-04-26
created: 2026-04-26
updated: 2026-06-24
tags: [decision, theme, dark-mode]
---

# Decision: Modernize Dark Mode (Cookie + Optimistic UI)

GAIA's original dark-mode implementation was inherited from a 2022-era pattern: a React `ThemeProvider` context, `localStorage` for client-side persistence, a cookie for SSR, and a 30+ line inline blocking script (`clientThemeCode`) to repaint the wrong-themed page on first paint. The current pattern is cookie-as-truth + a small inline pre-paint `matchMedia` script + a `useSyncExternalStore` OS-theme hook + optimistic `useFetchers()` UI.

## Why

The old implementation had three real problems:

1. **State-sync drift.** Four sources of truth (cookie, `localStorage`, React state, OS `matchMedia`) drifted out of sync. The provider's persistence `useEffect` ran only on mount, so a click that flipped React state did not reliably `submit()` to the cookie route, meaning toggles could fail to persist. A `setTimeout(saveInitialTheme)` workaround masked the same race on first render.
2. **Inline blocking script.** `clientThemeCode` ran synchronously before hydration to set the right class on `<html>` and prevent FOUC. With the cookie as truth and SSR rendering the class directly, the script is unnecessary, and its absence improves the CSP story.
3. **`localStorage` for theme.** `localStorage` is a duplicate of the cookie. With the cookie already round-tripping every request, `localStorage` adds nothing except a way for the two to disagree.

## What changed

- **Added** `app/utils/theme.server.ts`, `app/utils/request-info.ts`, `app/hooks/useTheme.ts`.
- **Added** `app/routes/resources+/theme-switch.tsx`: co-located `action` + Zod `ThemeFormSchema`. The theme hooks live in `app/hooks/useTheme.ts` and the switcher component in `app/components/ThemeSwitch/index.tsx`.
- **Removed** `app/state/theme.tsx`, `app/sessions.server/theme.ts`, `app/routes/actions+/set-theme.ts`, `app/components/ThemeSwitcher/index.tsx`.
- **Updated** `app/root.tsx` loader to return `requestInfo`. `<State>` no longer carries `theme`.
- **Updated** `app/components/Document/index.tsx` to call `useOptionalTheme()` and, when no explicit cookie preference exists, render an inline pre-paint `<script>` (`THEME_SCRIPT`) in `<head>` that adds the `dark` class from `matchMedia`.
- **Updated** `app/components/Errors/RootErrorBoundary/index.tsx` to drop `getPreferredTheme()`.

## Trade-offs

- **3-state cycle (`light → dark → system → light`).** The pattern includes `'system'` (delete cookie). The previous GAIA toggle was 2-state. The action/schema carry the 3-state cycle, and the switcher shows three icons (sun for light, moon for dark, desktop for system) reflecting the current preference rather than the resolved theme. Passing through `system` lets users follow the OS again. This is a minor behavioral change.
- **Cookie name preserved.** We kept `__theme` (vs Epic Stack's `theme`) to avoid invalidating existing user preferences after deploy.
- **`@conform-to/*` not adopted.** GAIA already has Conform installed for forms, but the theme action uses plain Zod to keep the resource route minimal. Forms with user-facing validation continue to use Conform.

## Bugs the migration fixes

- **Toggle-not-persisted.** The mount-only `useEffect` in `ThemeProvider` could miss subsequent toggles. Now the action writes the cookie on every submit; nothing depends on `useEffect` firing.
- **Hydration mismatch on first paint.** Removed `clientThemeCode`; SSR now emits the right class directly when the cookie is set. `suppressHydrationWarning` covers the brief revalidation window for OS-driven first visits.
- **`localStorage` drift.** Eliminated.

## Storybook

`@vueless/storybook-dark-mode` continues to work; it toggles the `dark` class on `<html>`, which Tailwind's `@custom-variant dark` matches. No story changes required.

See [[Theme Flow]], [[Styles]], [[State]].
