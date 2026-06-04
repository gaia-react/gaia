---
type: dependency
status: active
package: tailwindcss
version: 4.2.2
role: styling
created: 2026-04-20
updated: 2026-04-20
tags: [dependency, styling]
---

# Tailwind

Utility-first CSS framework. GAIA uses **Tailwind v4** with the Vite plugin.

## Companion packages

- `@tailwindcss/vite`: v4 Vite plugin
- `@tailwindcss/forms`, `@tailwindcss/typography`: official plugins
- `tailwind-merge`: runtime class merging (`twJoin`, `twMerge`)
- `prettier-plugin-tailwindcss`: auto-sort classes
- `eslint-plugin-better-tailwindcss`: lint rules
- `stylelint-config-tailwindcss`: Stylelint integration

## Conventions

See `tailwind` rule (`.claude/rules/tailwind.md`) for the full ruleset. `dark:` variant powers the [[Theme Flow]].
