---
type: module
path: frontend/app/styles/
status: active
language: css
purpose: Tailwind setup and shared utilities
depends_on: [[Tailwind]]
created: 2026-04-20
updated: 2026-10-05
tags: [module, styles, tailwind]
---

# Styles

`frontend/app/styles/tailwind.css` is the entry point for [[Tailwind]] v4: it imports Tailwind, `tw-animate-css`, shadcn's Tailwind layer and `theme.css`, and holds `@theme inline`, the base `@layer`, and the few shared `@utility` blocks. `frontend/app/styles/theme.css` holds the token values: the `:root` and `.dark` blocks and `color-scheme`. Components are styled with role-token utilities in their own class names; a component's own CSS file is the exception, not the rule.

## Conventions (load-bearing)

See the `tailwind` skill (`.claude/skills/tailwind/`, which owns class composition with `cn`) and the `tailwind` rule (`frontend/.claude/rules/tailwind.md`):

- **No `px` units** in Tailwind classes: use the spacing scale or `rem` for custom values
- **No template-literal class strings**: they defeat Tailwind's static analysis
- **Role tokens only for color**: `bg-background`, `text-foreground`, `border-input` and the rest of the set in `theme.css`, never a raw palette class. Each token holds its light and dark values, so components write one utility, not a `dark:` pair. The contract is `frontend/.claude/rules/tailwind.md`; the token values are a replaceable placeholder ([[Design System]], [[shadcn Component Layer]])

## Dark mode pipeline (no React state)

> [!key-insight] Cookie + inline pre-paint script, not React state
> Dark mode is wired through a cookie read server-side and a synchronous inline script that sets `<html class="dark">` before first paint. `frontend/app/hooks/use-theme.ts` tracks OS changes post-hydration via `useSyncExternalStore`. No React state, no flash of incorrect theme on hydration. See [[Theme Flow]].

The pipeline (query Serena for current paths):

- `frontend/app/utils/theme.server.ts`: reads/writes the `__theme` cookie
- `frontend/app/hooks/use-theme.ts`: tracks OS `prefers-color-scheme` via `useSyncExternalStore` (`useSystemTheme`), derives the optimistic theme from pending `useFetchers()` (`useOptimisticThemeMode`), and resolves the effective theme (`useOptionalTheme`) from optimistic value, then the loader cookie preference, then OS
- `frontend/app/routes/resources.theme-switch.tsx`: action + `ThemeFormSchema` only
- `frontend/app/components/theme-switch/index.tsx`: the `ThemeSwitch` UI
- The `.dark` token block in `theme.css`, selected through `@custom-variant dark` in `tailwind.css`
- Storybook's `@vueless/storybook-dark-mode` addon (unchanged)

For the current Tailwind plugin inventory, query Serena or `package.json`.
