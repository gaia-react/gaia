---
type: module
path: app/styles/
status: active
language: css
purpose: Tailwind setup and shared utilities
depends_on: [[Tailwind]]
created: 2026-04-20
updated: 2026-05-04
tags: [module, styles, tailwind]
---

# Styles

`app/styles/tailwind.css` is the entry point for [[Tailwind]] v4 and the place to define shared `@layer` utilities/components. Component-specific CSS lives in `app/components/{Name}/styles.module.css` (CSS Modules), co-located with the component, not centralized here.

## Conventions (load-bearing)

See the `tailwind` skill (`.claude/skills/tailwind/`) and the `tailwind` rule (`.claude/rules/tailwind.md`):

- **No `px` units** in Tailwind classes: use the spacing scale or `rem` for custom values
- **`twJoin`** for static class lists, **`twMerge`** only when classes can conflict
- **No template-literal class strings**: they defeat Tailwind's static analysis

## Dark mode pipeline (no React state)

> [!key-insight] Cookie + inline pre-paint script, not React state
> Dark mode is wired through a cookie read server-side and a synchronous inline script that sets `<html class="dark">` before first paint. `app/hooks/useTheme.ts` tracks OS changes post-hydration via `useSyncExternalStore`. No React state, no flash of incorrect theme on hydration. See [[Theme Flow]].

The pipeline (query Serena for current paths):

- `app/utils/theme.server.ts`: reads/writes the `__theme` cookie
- `app/hooks/useTheme.ts`: tracks OS `prefers-color-scheme` via `useSyncExternalStore` and resolves the optimistic theme from the loader
- `app/routes/resources+/theme-switch.tsx`: action + `ThemeSwitch` UI + `useOptionalTheme` hook
- Tailwind's `dark:` variant via `@custom-variant dark` in `tailwind.css`
- Storybook's `@vueless/storybook-dark-mode` addon (unchanged)

For the current Tailwind plugin inventory, query Serena or `package.json`.
