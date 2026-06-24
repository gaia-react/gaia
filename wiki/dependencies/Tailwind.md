---
type: dependency
status: active
package: tailwindcss
version: 4.3.1
role: styling
created: 2026-04-20
updated: 2026-06-24
tags: [dependency, styling]
---

# Tailwind

Utility-first CSS framework. GAIA uses **Tailwind v4** with the Vite plugin.

## Companion packages

- `@tailwindcss/vite`: v4 Vite plugin
- `@tailwindcss/forms`, `@tailwindcss/typography`: official plugins
- `tailwind-merge`: runtime class merging (`twJoin`, `twMerge`)

Tailwind-aware tooling ships via [[gaia-lint]] (`@gaia-react/lint`), not as direct dependencies:

- `prettier-plugin-tailwindcss`: class auto-sort, configured with `twJoin`/`twMerge` as `tailwindFunctions`, loaded by `@gaia-react/lint/prettier`
- `eslint-plugin-better-tailwindcss`: `better-tailwindcss/*` rules, wired via `lint.betterTailwind()` in `eslint.config.mjs`
- `stylelint-config-tailwindcss`: extended by `@gaia-react/lint/stylelint`

## Conventions

See `tailwind` rule (`.claude/rules/tailwind.md`) for the full ruleset. `dark:` variant powers the [[Theme Flow]].
