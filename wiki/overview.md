---
type: overview
title: GAIA React Overview
status: mature
created: 2026-04-20
updated: 2026-06-24
tags: [overview, gaia]
---

# GAIA React

GAIA React eliminates the multi-day setup tax on new projects: linting, testing, i18n, CI, pre-commit hooks, dark mode, Storybook, MSW, and Claude Code integration are all wired together and working, not just installed.

## Philosophy

GAIA deliberately ships **no component library**; you choose what fits. Every tool is pre-configured but **removable**.

See [[GAIA Philosophy]] for the long version.

## Tech Stack at a Glance

- **Framework**: [[React Router 7]] (SSR, file-based routing via [[remix-flat-routes]])
- **Forms**: [[Conform]] + [[Zod]], see [[Form Components]]
- **Styling**: [[Tailwind]] v4 with `tailwind-merge`, plus [[react-icons]] icons
- **i18n**: [[remix-i18next]] with TypeScript language files (not JSON)
- **State**: minimal; `app/state/index.tsx` is a passthrough; theme is cookie-based (no React state for theme)
- **Testing**: [[Vitest]] + [[React Testing Library]] + [[Playwright]] + [[Chromatic]], all sharing one MSW mocking layer
- **Mocking**: [[MSW]] + `@msw/data` for tests, Storybook, and dev
- **Storybook** v10 with links, i18n, and dark mode addons; MSW seed data comes from the shared `@msw/data` collections rather than a Storybook MSW addon
- **Quality**: 20+ ESLint plugins, Prettier, Stylelint, [[Husky]] pre-commit hooks
- **Claude Code**: [[Claude Integration]] with commands, rules, hooks, agents

## Top-Level Architecture

```
app/
├── assets/           images, svgs
├── components/       shared UI (Button, Form/*, Toast, Layout, ...)
├── hooks/            useBreakpoint, useComponentRect, useDebounce, useTheme, useTimeout
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
├── routes.ts         flat-routes adapter
└── env.server.ts     Zod-validated env vars
```

See [[Folder Structure]] for the full breakdown.

## Route Groups (remix-flat-routes)

- `_public+`: unauthenticated pages
- `_session+`: hook point for auth-guarded pages (empty stub; add your own auth guard)
- `_legal+`: terms, privacy, etc.
- `actions+`: root-level form actions (set-language)
- `resources+`: resource routes (theme-switch, the action `useTheme` posts to)

See [[Routing]].

## Quality Gate

Every change passes through [[Quality Gate]]: typecheck → lint → unit test → E2E → dev smoke → build. Pre-commit hooks enforce a subset on every commit; Claude runs the full pipeline before any source-touching commit. Zero tolerance for warnings.

## Knowledge Hygiene

`/gaia-audit` runs a two-stage Sonnet audit (research → mechanical apply, gated by sha256 + verbatim drift checks) over memory, wiki, auto-loaded `CLAUDE.md` files, and `.claude/rules/`. Flags duplication, stale entries, conflicting instructions, and auto-load bloat, with wiki as the source of truth (broken wikilinks are repaired by `/gaia-wiki lint`). See [[GAIA Audit]].

## See also

[[GAIA Philosophy]], [[Folder Structure]], [[Quality Gate]], [[Claude Integration]], [[Form Components]]
