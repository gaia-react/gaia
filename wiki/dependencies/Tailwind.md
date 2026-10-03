---
type: dependency
status: active
package: tailwindcss
role: styling
created: 2026-04-20
updated: 2026-10-03
tags: [dependency, styling]
---

# Tailwind

Utility-first CSS framework. GAIA ships **Tailwind v4** with the Vite plugin.

## Companion packages

- `@tailwindcss/vite`: v4 Vite plugin
- `@tailwindcss/forms`, `@tailwindcss/typography`: official plugins
- `cn`: runtime class composition and conflict merging (see `package.json`)

Tailwind-aware tooling ships via [[gaia-lint]] (`@gaia-react/lint`), not as direct dependencies:

- `prettier-plugin-tailwindcss`: class auto-sort, loaded by `@gaia-react/lint/prettier`, which owns the sorting configuration
- `eslint-plugin-better-tailwindcss`: `better-tailwindcss/*` rules, wired via `lint.betterTailwind()` in `frontend/eslint.config.mjs`
- `stylelint-config-tailwindcss`: extended by `@gaia-react/lint/stylelint`

## Conventions

See `tailwind` rule (`frontend/.claude/rules/tailwind.md`) for the full ruleset. `dark:` variant powers the [[Theme Flow]].
