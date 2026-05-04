# Changelog

All notable changes to GAIA React are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- **Major** — breaking changes to skill/command API, Node/React/React Router major bumps, removed or renamed `.claude/` paths.
- **Minor** — new skills, commands, or wiki concept pages; opt-in features.
- **Patch** — bugfixes, docs, and in-range dependency bumps.

## [Unreleased]

### Added

- Dead-code detection via [knip](https://knip.dev). Run `pnpm knip` after refactors or before release-candidate PRs. Template-aware config marks GAIA's library surface as entries so intentional exports aren't flagged. `.claude/rules/knip.md` guides Claude on when to suggest it.

## [1.0.5] — 2026-05-04

### Added

- v1.0.5 wiki sync system — drift-check, commit-nudge, stop-safety-net hooks plus `/wiki-sync` workhorse for a convergent wiki-update model.

### Changed

- `/gaia-init` i18n setup is now language-aware: asks the user's primary language and optional additional locales, with an opt-out path that strips i18n entirely. Per-locale `add-locale` and `remove-i18n` instructions ship as parameterized runbooks under `.claude/instructions/`.
- Pin docs install command to `npx create-gaia@latest`.

### Fixed

- Restore statusline indicators for `/update-deps` and `/update-gaia`. The prior SessionStart hook approach was invisible to users — system-reminders only reach the model, and a 6h snooze locked in regardless of whether the user ever saw a prompt. Statusline indicators are passive and always visible.
- `/gaia-release` Step 2 gate now allows wiki-prefix-only drift, and `/wiki-sync` Step 7 is branch-aware (branch+PR on `main`, in-place commit elsewhere). Together they make the `/wiki-sync` → `/gaia-release` flow self-consistent.
- `/gaia audit` now chains research and apply by default; `--apply` is the retry escape hatch.
- Wiki sync system: smoke test assertions match the frozen interface.
- `/gaia-release` and `/gaia-init` scrub templates for `wiki/hot.md` (and `/gaia-release` Step 9 for `wiki/log.md`) now include the full frontmatter required by `/wiki-lint` (`status`, `created`, `tags`), eliminating a recurring lint regression on every release.

## [1.0.4] — 2026-05-01

### Fixed

- Handle `git -C <path>` in block-main-destructive-git hook

### Changed

- Wiki lint + audit hygiene sweep

## [1.0.3] — 2026-05-01

### Fixed

- Remove if conditionals from PreToolUse/PostToolUse hooks

## [1.0.2] — 2026-05-01

### Fixed

- Added `pnpm.onlyBuiltDependencies` for `core-js-pure`, `esbuild`, `msw`, and `unrs-resolver` to silence the pnpm build-script warning on fresh installs.

## [1.0.1] — 2026-05-01

### Fixed

- `/init` interceptor now reliably redirects to `/gaia-init`. The previous implementation used `UserPromptSubmit` + `exit 2`, which blocked the turn entirely so the model never ran. Switched to `UserPromptExpansion` (matcher: `init`) with `additionalContext` only — the model receives `/init`'s expansion plus a system-reminder override telling it to invoke `/gaia-init` via the Skill tool. The user-visible "blocked by hook" banner is gone.

## [1.0.0] — 2026-04-30

### Initial release

GAIA v1.0.0 is the inaugural public release of the GAIA React workflow — a Claude-native foundation that ships skills, commands, hooks, a wiki, and a curated React Router 7 app skeleton designed for agentic development from day one.

#### Highlights

- **Claude integration surface.** `.claude/` ships with rules, settings, hooks, an agent skills bundle (`typescript`, `react-code`, `tailwind`, `tdd`, `skeleton-loaders`, `playwright-cli`, `eslint-fixes`, `update-deps`, scaffolders), and an agent commands catalog. `CLAUDE.md` is curated for context economy.
- **GAIA workflows.** `/gaia plan`, `/gaia handoff`, `/gaia pickup`, `/gaia audit` cover task orchestration, session continuity, and knowledge-store hygiene. `/gaia-init` bootstraps new projects from the template.
- **Wiki vault.** Architecture overview, decisions (Quality Gate, pnpm, Dark Mode Modernization, etc.), modules (Routing, Styling, i18n, Form Components), concepts (Agentic Design, API Service Pattern, Component Testing, Task Orchestration), and a hot/log pair for session continuity.
- **App stack.** React Router 7, React 19, Tailwind v4, ESLint 9, Vite 8, Vitest 4, TypeScript 6, pnpm 10, MSW 2 + `@msw/data` 1.x.
- **Form system.** Conform + Zod for type-safe forms with reusable field components.
- **i18n.** `remix-i18next` middleware, English + Japanese language scaffolding, `LanguageSelect` component, Storybook locale switcher.
- **Dark mode.** Cookie-as-truth + `@epic-web/client-hints` + optimistic `useFetchers()` UI.
- **Quality gate.** Mandatory pre-commit pipeline: simplify, localization check, typecheck, lint, unit tests, E2E tests, dev smoke test, build. Zero warnings tolerated.
- **Release tooling.** Tag-triggered `release.yml` builds a scrubbed tarball; `create-gaia` bootstrapper consumes it via `npx create-gaia@latest my-app`.

[Unreleased]: https://github.com/gaia-react/gaia/compare/v1.0.5...HEAD
[1.0.5]: https://github.com/gaia-react/gaia/releases/tag/v1.0.5
[1.0.4]: https://github.com/gaia-react/gaia/releases/tag/v1.0.4
[1.0.3]: https://github.com/gaia-react/gaia/releases/tag/v1.0.3
[1.0.2]: https://github.com/gaia-react/gaia/releases/tag/v1.0.2
[1.0.1]: https://github.com/gaia-react/gaia/releases/tag/v1.0.1
[1.0.0]: https://github.com/gaia-react/gaia/releases/tag/v1.0.0
