---
type: source
source_type: codebase-scan
status: archived
ingested: 2026-04-20
created: 2026-04-20
updated: 2026-05-01
tags: [source, initial]
---

# Source: Initial Ingest of GAIA React

## What was read

- `README.md`
- `package.json`
- `app/root.tsx`, `app/routes.ts`
- `app/services/api/index.ts`, `app/sessions.server/auth.ts`, `app/state/index.tsx`
- `docs/general/{about,features,quick-start,claude}.md` (and the `general/CLAUDE.md` partial)
- `docs/architecture/{folder-structure,routes,components,pages,services,sessions,state,middleware,hooks,languages,utils,styles,types,assets}.md`
- `docs/tech-stack/{foundation,code-quality,testing/index,testing/unit-and-integration,testing/visual,testing/e2e}.md`
- `.claude/CLAUDE.md` (project) + `.claude/rules/*.md` (full)
- `.claude/commands/*.md` (`gaia-init`, `gaia-release`)
- `.claude/skills/*/SKILL.md` (router: `gaia`; scaffolders: `new-component`, `new-hook`, `new-route`, `new-service`, `update-deps`, `update-gaia`; context-triggered: `eslint-fixes`, `playwright-cli`, `react-code`, `skeleton-loaders`, `tailwind`, `tdd`, `typescript`) + `.claude/skills/gaia/references/*.md`
- `.claude/hooks/*.sh` (all)
- `.claude/agents/code-review-audit.md`
- `.claude/settings.json`
- Folder listings for `app/`, `test/`, `.storybook/`, `.playwright/e2e/`

## Key takeaways

- **Mode**: B (Codebase) + E (Research) — modules, components, decisions, dependencies, flows; concepts/sources for research-style notes
- **Big ideas**:
  - Pre-configured but removable. No component library. ([[GAIA Philosophy]])
  - Thin routes, fat pages. ([[Thin Routes]])
  - Quality enforced by tooling, zero-warning gate. ([[Quality Gate]])
  - One mocking layer (MSW) across Vitest, Storybook, Playwright. ([[MSW Handlers]])
  - composeStory pattern shares Storybook + Vitest setup. ([[Component Testing]])
  - TypeScript language files instead of JSON. ([[TypeScript Language Files]])
  - Husky runs tests on commit, not just lint. ([[Pre-commit Hooks]])
  - Form components are the headline feature. ([[Form Components]])
- **Claude integration is first-class**: skills (a `/gaia` router + scaffolders + context-triggered guidance), rules, hooks, a review agent + specialists, and two maintainer slash commands — see [[Claude Integration]] for the current inventory.

## Pages created

Original ingest included: 1 overview, 13 modules, 4 flows (Auth Flow since removed), 2 entities, 19 dependencies (VitePress + remix-auth since removed), 6 decisions, 13 concepts, 1 source summary. See [[index]] for the current authoritative list.
