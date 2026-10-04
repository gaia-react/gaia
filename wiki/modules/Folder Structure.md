---
type: module
path: frontend/app/
status: active
language: typescript
purpose: Top-level folder layout of the app
created: 2026-04-20
updated: 2026-10-04
tags: [module, structure]
---

# Folder Structure

The repo is a monorepo. The harness (`.claude/`, `.gaia/`, `.githooks/`, `.github/`, `wiki/`) lives at the root and the React app lives in the `frontend/` package, which holds its own `package.json`, build config, tests, Storybook, and `.claude/` skills and rules. [[Package Descriptor]] describes how the harness finds the package.

`frontend/app/` is organized by responsibility, not by feature. Each top-level folder owns one concern:

| Folder             | Concern                                    | Wiki page      |
| ------------------ | ------------------------------------------ | -------------- |
| `components/`      | Shared UI components                       | [[Components]] |
| `hooks/`           | Global custom hooks                        | [[Hooks]]      |
| `languages/`       | TypeScript-based i18n strings              | [[i18n]]       |
| `middleware/`      | React Router middleware (i18next)        | [[Middleware]] |
| `pages/`           | Page-specific UI, organized by route path  | [[Pages]]      |
| `routes/`          | Thin route files (loader/action only)      | [[Routing]]    |
| `services/`        | API wrapper + domain services              | [[Services]]   |
| `sessions.server/` | Server-only signed cookie for language      | [[Sessions]]   |
| `state/`           | Context+Provider state                     | [[State]]      |
| `styles/`          | `tailwind.css`                             | [[Styles]]     |
| `types/`           | Global TS types                            | -              |
| `utils/`           | Pure helpers                               | [[Utils]]      |

## Conventions

- The `pages/` vs `components/` split is load-bearing; see [[Thin Routes]] and [[Pages]] for the rationale
- `.server/` suffix excludes a folder from the client bundle (used by `sessions.server/`)
- Top-level files (`entry.client.tsx`, `entry.server.tsx`, `root.tsx`, `i18n.ts`, `routes.ts`, `env.server.ts`) follow React Router's required entry-point names; query Serena to read them rather than mirroring their contents here.
