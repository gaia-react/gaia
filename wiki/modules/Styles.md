---
type: module
path: frontend/app/styles/
status: active
language: css
purpose: Tailwind setup and shared utilities
depends_on: [[Tailwind]]
created: 2026-04-20
updated: 2026-10-04
tags: [module, styles, tailwind]
---

# Styles

`frontend/app/styles/tailwind.css` is the entry point for [[Tailwind]] v4 and the place to define shared `@layer` utilities/components. Component-specific CSS lives in `frontend/app/components/<kebab-name>/styles.module.css` (CSS Modules), co-located with the component, not centralized here.

## Conventions (load-bearing)

See the `tailwind` skill (`.claude/skills/tailwind/`, which owns class composition with `cn`) and the `tailwind` rule (`frontend/.claude/rules/tailwind.md`):

- **No `px` units** in Tailwind classes: use the spacing scale or `rem` for custom values
- **No template-literal class strings**: they defeat Tailwind's static analysis
- **Prefer semantic `@utility` tokens** defined in `tailwind.css` (`bg-body`, `bg-secondary`, `text-body`, `text-secondary`, `border-normal`, `input-invalid`, etc.) over raw paired `dark:` classes; each token bundles the light/dark pair

## Dark mode pipeline (no React state)

> [!key-insight] Cookie + inline pre-paint script, not React state
> Dark mode is wired through a cookie read server-side and a synchronous inline script that sets `<html class="dark">` before first paint. `frontend/app/hooks/use-theme.ts` tracks OS changes post-hydration via `useSyncExternalStore`. No React state, no flash of incorrect theme on hydration. See [[Theme Flow]].

The pipeline (query Serena for current paths):

- `frontend/app/utils/theme.server.ts`: reads/writes the `__theme` cookie
- `frontend/app/hooks/use-theme.ts`: tracks OS `prefers-color-scheme` via `useSyncExternalStore` (`useSystemTheme`), derives the optimistic theme from pending `useFetchers()` (`useOptimisticThemeMode`), and resolves the effective theme (`useOptionalTheme`) from optimistic value, then the loader cookie preference, then OS
- `frontend/app/routes/resources.theme-switch.tsx`: action + `ThemeFormSchema` only
- `frontend/app/components/theme-switch/index.tsx`: the `ThemeSwitch` UI
- Tailwind's `dark:` variant via `@custom-variant dark` in `tailwind.css`
- Storybook's `@vueless/storybook-dark-mode` addon (unchanged)

For the current Tailwind plugin inventory, query Serena or `package.json`.
