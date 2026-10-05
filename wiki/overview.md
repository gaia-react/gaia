---
type: overview
title: GAIA React Overview
status: mature
created: 2026-04-20
updated: 2026-10-05
tags: [overview, gaia]
---

# GAIA React

GAIA React eliminates the multi-day setup tax on new projects: linting, testing, i18n, CI, pre-commit hooks, dark mode, Storybook, MSW, and Claude Code integration are all wired together and working, not just installed.

## Philosophy

GAIA ships a vendored [[shadcn]] component layer you own ([[shadcn Component Layer]]). Every tool is pre-configured but **removable**.

See [[GAIA Philosophy]] for the long version.

## Tech Stack at a Glance

- **Framework**: [[React Router]] (SSR, file-based routing via [[fs-routes]])
- **Forms**: [[Conform]] + [[Zod]] composed with ui `Field` parts, see [[Form Components]]
- **Styling**: [[Tailwind]] v4 with `cn` and role tokens, [[shadcn]] components, and [[lucide-react]] icons
- **i18n**: [[remix-i18next]] with TypeScript language files (not JSON)
- **State**: minimal; `frontend/app/state/index.tsx` is a passthrough; theme is cookie-based (no React state for theme)
- **Testing**: [[Vitest]] running [[Storybook]] stories as component tests ([[Stories as Tests]]) + [[Playwright]] + [[Chromatic]], with MSW seed data shared across them
- **Mocking**: [[MSW]] + `@msw/data` for tests, Storybook, and dev
- **Storybook** v10 with links, i18n, dark mode, Vitest and a11y addons; MSW seed data comes from the shared `@msw/data` collections rather than a Storybook MSW addon
- **Quality**: 20+ ESLint plugins, Prettier, Stylelint, [[Pre-commit Hooks]] with [[lint-staged]]
- **Claude Code**: [[Claude Integration]] with commands, rules, hooks, agents

## Top-Level Architecture

```
frontend/app/
├── assets/           images, svgs
├── components/       shared UI (button, form/*, toast, layout, ...)
├── hooks/            use-breakpoint, use-component-rect, use-debounce, use-theme, use-timeout
├── languages/        TS-based i18n (en by default)
├── middleware/       i18next middleware
├── pages/            page-specific UI
├── routes/           thin route files (loader/action only)
├── services/         api wrapper (Ky) + gaia/* domain services
├── sessions.server/  server-only signed cookie (language)
├── state/            React Context providers
├── styles/           tailwind.css
├── types/            global TS types
├── utils/            pure helpers (date, dom, http, string, ...)
├── root.tsx          root layout, i18n hookup, theme, toast
├── routes.ts         fs-routes route config
└── env.server.ts     Zod-validated env vars
```

See [[Folder Structure]] for the full breakdown.

## Routes

Route files are flat, dot-delimited, and grouped by name prefix. See [[Routing]].

## Quality Gate

Every change passes through [[Quality Gate]]: typecheck → lint → unit test → E2E → dev smoke → build. Pre-commit hooks enforce a subset on every commit; Claude runs the full pipeline before any source-touching commit. Zero tolerance for warnings.

## Knowledge Hygiene

`/gaia-audit` runs a two-stage Sonnet audit (research → mechanical apply, gated by sha256 + verbatim drift checks) over memory, wiki, auto-loaded `CLAUDE.md` files, and `.claude/rules/`. Flags duplication, stale entries, conflicting instructions, and auto-load bloat, with wiki as the source of truth (broken wikilinks are repaired by `/gaia-wiki lint`). See [[GAIA Audit]].

## See also

[[GAIA Philosophy]], [[Folder Structure]], [[Quality Gate]], [[Claude Integration]], [[Form Components]]
