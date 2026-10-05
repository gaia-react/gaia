---
paths:
  - 'app/**/*.tsx'
  - 'app/**/*.css'
---

# Tailwind Conventions

Authoring patterns live in `frontend/.claude/skills/tailwind/SKILL.md`. This rule covers the role-token contract and the project-specific facts.

## Tailwind v4

Config lives in `app/styles/tailwind.css` under `@theme` / `@layer` / `@utility`; the token values live in `app/styles/theme.css`, which `tailwind.css` imports. GAIA ships no `tailwind.config.ts`.

## Role tokens

Every color comes from a theme role token (`bg-background`, `text-foreground`, `text-muted-foreground`, `border-input`, `text-destructive`, `bg-primary`, and the rest of the set), never a raw palette class (a color name plus a shade, or `white` or `black`) or an arbitrary color in square brackets. The token blocks in `app/styles/theme.css` (`:root` and `.dark`) are the list of what exists; read them rather than a copy here. The `@theme inline` block in `app/styles/tailwind.css` maps each token to its utilities. shadcn's theming doc describes what each role means: https://ui.shadcn.com/docs/theming.

The light and dark values live in the token, so write one utility, not a `dark:` pair. A `dark:` variant on a color is a sign the wrong token was picked.

Lint enforces the contract: `shadcn/no-raw-colors` rejects raw palette classes and color literals in source files.

## Adding a token

- A role token whose value equals an existing token, or a value the code already repeats, needs no approval.
- Introducing a new color value asks first.
- When to create a token and how to name it: the tailwind skill's "When to create a role token" section.

## Dark mode

Class strategy: `@custom-variant dark (&:where(.dark, .dark *))`. The `.dark` block in `theme.css` swaps the token values, so components do not branch on theme.

## No arbitrary colors

No hex, `rgb()`, `hsl()` or `oklch()` literals in `[]` or in a component's CSS. Colors live in `theme.css` only.
