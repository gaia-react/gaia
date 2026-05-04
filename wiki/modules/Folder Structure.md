---
type: module
path: app/
status: active
language: typescript
purpose: Top-level folder layout of the GAIA app
created: 2026-04-20
updated: 2026-05-04
tags: [module, structure]
---

# Folder Structure

`app/` is organized by responsibility, not by feature. Each top-level folder owns one concern:

| Folder             | Concern                                    | Wiki page      |
| ------------------ | ------------------------------------------ | -------------- |
| `assets/`          | Global images / svgs                       | —              |
| `components/`      | Shared UI components                       | [[Components]] |
| `hooks/`           | Global custom hooks                        | [[Hooks]]      |
| `languages/`       | TypeScript-based i18n strings              | [[i18n]]       |
| `middleware/`      | React Router 7 middleware (i18next)        | [[Middleware]] |
| `pages/`           | Page-specific UI, organized by route group | [[Pages]]      |
| `routes/`          | Thin route files (loader/action only)      | [[Routing]]    |
| `services/`        | API wrapper + domain services              | [[Services]]   |
| `sessions.server/` | Cookie session storage (language, theme)   | [[Sessions]]   |
| `state/`           | Context+Provider state                     | [[State]]      |
| `styles/`          | `tailwind.css`                             | [[Styles]]     |
| `types/`           | Global TS types                            | —              |
| `utils/`           | Pure helpers                               | [[Utils]]      |

## Conventions

- The `pages/` vs `components/` split is load-bearing — see [[Thin Routes]] and [[Pages]] for the rationale
- `.server/` suffix excludes a folder from the client bundle (used by `sessions.server/`)
- Top-level files (`entry.client.tsx`, `entry.server.tsx`, `root.tsx`, `i18n.ts`, `routes.ts`, `env.server.ts`) follow React Router 7's required entry-point names — query Serena to read them rather than mirroring their contents here.
