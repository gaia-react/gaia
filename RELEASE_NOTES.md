# GAIA v1.0.0 — Initial Release

GAIA is a Claude-native React workflow. It ships a curated React Router 7 application skeleton plus the agent harness — skills, commands, hooks, a knowledge wiki, and a quality gate — wired so Claude Code is a first-class collaborator from the first commit. v1.0.0 is the inaugural public release.

## Highlights

- **Claude-native, framework-neutral.** `.claude/` ships with rules, settings, hooks, an agent skills bundle, and an agent commands catalog. The wiki under `wiki/` is a structured knowledge base for both humans and the agent.
- **GAIA workflows.** `/gaia plan` (task orchestration), `/gaia handoff` + `/gaia pickup` (session continuity), `/gaia audit` (knowledge-store hygiene), `/gaia-init` (bootstrap new projects), `/update-deps` (autonomous dep upgrades).
- **Modern app stack.** React Router 7 · React 19 · TypeScript 6 · Tailwind v4 · ESLint 9 · Vite 8 · Vitest 4 · pnpm 10 · MSW 2 + `@msw/data` 1.x.
- **Form system.** Conform + Zod for type-safe forms with reusable field components.
- **i18n.** `remix-i18next` middleware, English + Japanese language scaffolding, `LanguageSelect` component, Storybook locale switcher.
- **Dark mode.** Cookie-as-truth with `@epic-web/client-hints` and optimistic `useFetchers()` UI.
- **Quality gate.** Mandatory pre-commit pipeline: simplify, localization check, typecheck, lint, unit tests, E2E, dev smoke test, build. Zero warnings tolerated.

## Get started

```bash
npx create-gaia my-app
cd my-app
# Then run /gaia-init in Claude Code to scaffold your project.
```

## What's next

The `## [Unreleased]` section in `CHANGELOG.md` is reintroduced on the first post-v1 release. See `CHANGELOG.md` for the full v1.0.0 entry.
