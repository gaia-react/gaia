---
type: meta
title: Log
status: active
created: 2026-04-20
updated: 2026-04-27
tags: [meta, log]
---

# Log

Append-only. New entries at the TOP.

## [2026-04-27] feat | @msw/data migration + ESLint overhaul

- Replaced `@mswjs/data@0.16.2` with `@msw/data@1.1.5`. Rewrote `test/mocks/database.ts` as a `Collection` re-export barrel; `resetTestData()` is now async (`await` required in `beforeEach`). Read operations (`findFirst`, `findMany`) remain sync; mutations (`create`, `update`, `delete`, `deleteMany`) are async.
- Inlined two unmaintained ESLint plugins as local configs: `eslint-plugin-typescript-enum` → `noEnumPlugin`, `eslint-plugin-no-switch-statements` → `noSwitchPlugin`. Removed from `package.json`.
- Replaced `eslint-plugin-eslint-comments` with `@eslint-community/eslint-plugin-eslint-comments` (actively maintained, drop-in replacement).
- Dropped `eslint-plugin-jest-formatting` (never wired, Vitest project — was dead weight).
- Wired `eslint-plugin-testing-library` (`flat/react` config, 22 rules) on all test files. Wired `eslint-plugin-jest-dom` (`flat/recommended`, 11 rules) on all test files.
- Enabled `eslint-plugin-you-dont-need-lodash-underscore` compatible config (73 rules) across the codebase.
- Added fix patterns for all three new active rule groups to `.claude/rules/eslint-fixes.md` and [[ESLint Fixes]].
- Restored `block-eslint-config-edit.sh` hook registration in `settings.json` (had been dropped during a prior merge).
- Wired statusline cache-bust into `/update-deps` and `/gaia-update` commands.
- Updated: [[MSW Handlers]], [[MSW]], [[Storybook Stories]], [[Testing]], [[ESLint Fixes]], [[API Service Pattern]], `.claude/rules/api-service.md`, `.claude/skills/tdd/references/tests-react.md`.
- Quality gate ✅ typecheck, lint, vitest all green.

## [2026-04-26] feat | dark mode rewrite — cookie + client hints (Epic Stack pattern)

- Replaced the 2022-era `ThemeProvider` + `localStorage` + inline-script implementation with the Epic Stack pattern: cookie-as-truth + `@epic-web/client-hints` + optimistic `useFetchers()` UI. Net: −272 LOC removed across 4 files, +180 LOC added across 4 new files.
- Added `app/utils/theme.server.ts` (plain `cookie` parse/serialize on `__theme`), `app/utils/client-hints.tsx` (wraps `@epic-web/client-hints` with `getHints` + `<ClientHintCheck/>` that subscribes to scheme changes via `useRevalidator`), `app/utils/request-info.ts` (`useOptionalRequestInfo` reads `useRouteLoaderData('root')`), `app/routes/resources+/theme-switch.tsx` (action + `ThemeFormSchema` Zod + `useOptionalTheme`/`useOptimisticThemeMode` + `ThemeSwitch` UI).
- Removed `app/state/theme.tsx`, `app/sessions.server/theme.ts`, `app/routes/actions+/set-theme.ts`, `app/components/ThemeSwitcher/` — `app/state/index.tsx` becomes a passthrough.
- Cycle is 3-state (`system → light → dark → system`) with distinct desktop / sun / moon icons. Added `theme.useSystemTheme` i18n key (en + ja).
- Cookie name `__theme` preserved so existing user preferences survive deploy.
- Browser smoke test (Playwright): toggle flips `<html className>` optimistically, reload SSRs `class="dark"` from cookie, OS scheme flip via `emulateMedia` revalidates loader without manual reload, no console errors.
- New ADR: [[Dark Mode Modernization]]. Updated: [[Theme Flow]], [[Styles]], [[Sessions]], [[State]], [[Components]], [[index]], [[hot]]. New deps: `@epic-web/client-hints@1.3.9`, `cookie@1.1.1`.
- PR #34 open. Bugs the migration fixes: toggle-not-persisted (mount-only `useEffect`), state-sync drift (4 sources of truth), inline blocking script for FOUC.
- Key insight: with the cookie as truth and SSR rendering `<html class={theme}>` directly, the inline blocking `clientThemeCode` script becomes unnecessary — and React state for theme becomes pure overhead. The Epic Stack pattern eliminates an entire class of state-sync bugs by construction.

## [2026-04-26] feat | npm → pnpm migration + autonomous /update-deps command

- Switched package manager from npm to pnpm. `package.json` adds `"packageManager": "pnpm@10.33.0"` and moves `overrides` → `pnpm.overrides` using parent-child syntax (`remix-i18next>i18next`). `.npmrc` becomes `strict-peer-dependencies=false` + `minimumReleaseAge=10080` (7-day supply-chain quarantine). `package-lock.json` deleted; `pnpm-lock.yaml` committed (9.7k lines). Scripts: `npm run X` → `pnpm X`, `npx <bin>` → `pnpm exec <bin>`.
- CI updated. `.github/workflows/tests.yml` + `chromatic.yml` add `pnpm/action-setup@v4` (reads `packageManager`), switch `cache: 'npm'` → `cache: 'pnpm'`, `npm ci` → `pnpm install --frozen-lockfile`, and re-script invocations.
- `/gaia-init` Step 0 added: `corepack enable pnpm` (with `npm install -g pnpm` fallback) before Step 1 install.
- `/update-deps` rewritten as autonomous Dependabot. Phases: 0 override audit → 1 discover (`pnpm outdated --json`) → 2 companion-group resolve → 3 wave classify → 4 Wave A batch (minor/patch) → 5 Wave B per-group with WebFetch migration guides (storybook uses `pnpm dlx storybook@latest upgrade`) → 6 post-update override re-audit → 7 quality gate → 8 final report. ESLint 9.x cap retained inside the new flow.
- `block-bare-npm-test.sh` renamed `block-bare-test.sh`; matches both `pnpm *` and `npm *`. `.claude/settings.json` permissions rewired to `pnpm` shapes; `corepack enable pnpm` allow-listed.
- New ADR: [[pnpm]]. Updated: [[Quality Gate]], [[Husky]], [[Chromatic]], [[Playwright]], [[Vitest]], [[Test Runner]], [[Claude Hooks]], [[Claude Integration]] (commands + hooks tables), [[remix-i18next]], [[i18next]], [[MSW Handlers]], [[Testing]], [[Release Workflow]] (`create-gaia` step 5), [[index]], [[hot]].
- Quality gate ✅ typecheck, lint, vitest 46/46, build all green on the new lockfile.
- Key insight: `minimumReleaseAge=10080` is one config line that closes the dominant npm-supply-chain attack window (publish → detection/yank). No infra. No subscription.

## [2026-04-22] feat | release infrastructure — /gaia-release, /gaia-update, create-gaia, tarball scrubbing

- Added tag-triggered `.github/workflows/release.yml` (extracts CHANGELOG section, builds scrubbed tarball via `git ls-files` + `.gaia/release-exclude`, `gh release create`). Seeded `CHANGELOG.md` with v1.0.0 entry from the 109 commits since `v1.0.0-beta`.
- Added `.gaia/` directory: `VERSION` (adopter baseline marker), `manifest.json` (349 files classified as `owned`/`shared`/`wiki-owned`), `release-exclude` (tar-exclude list of maintainer-only paths), `scripts/generate-manifest.mjs` (classifier).
- Added `/gaia-release` — maintainer-only (stripped from tarball via release-exclude). 12-step orchestrator: verify clean, bump, audit, graduate CHANGELOG, scrub `wiki/hot.md` + `wiki/log.md`, regenerate manifest, commit, tag, confirm, push.
- Added `/gaia-update` — adopter-facing. GSD-inspired three-way diff per file; drifted `owned` prompts, drifted `shared`/`wiki-owned` emits `.gaia-merge/<path>.patch`, atomic version-marker bump.
- Separate `create-gaia` npm package scaffolded at `../create-gaia/` — zero-dep Node CLI that downloads the release tarball from GitHub, extracts, `git init`, `npm install`. Replaces `npx create-react-router --template gaia-react/gaia` in the README quick-start (old command preserved under an "Alternative" fold).
- CI made fork-safe: `tests.yml` + `chromatic.yml` fall back secrets to placeholders so forks pass lint/typecheck/unit. Chromatic split into a `has-chromatic-token` check job so it skips cleanly when the token is absent.
- PR/issue templates added (`.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/{bug_report,feature_request,config}.yml`).
- Pages created: [[Release Workflow]], [[Update Workflow]].
- Pages updated: [[Claude Integration]] (commands table), [[index]], [[hot]].
- Key insight: the manifest's implicit-adopter-owned category (anything NOT listed) is what makes `/gaia-update` drift-safe — adopter-created wiki pages, `wiki/hot.md`, `wiki/log.md`, `CHANGELOG.md`, and any file outside GAIA's shipped surface are invisible to the update walk. Sentinel sentinels can't be accidentally re-added by the classifier regenerating the manifest.

## [2026-04-21] chore | Claude hooks governance — rules migrated to machine-enforced hooks

- Added 4 PreToolUse `Bash` hooks: `block-bare-npm-test.sh`, `block-main-destructive-git.sh` (blocking) and `pr-merge-audit-check.sh`, `wiki-maintenance-check.sh` (advisory). Each uses an `if:` pattern for command-shape matching.
- Deleted `.claude/rules/test-runner.md` (now enforced by `block-bare-npm-test.sh`) and `.claude/rules/wiki-maintenance.md` (checklist moved into the `wiki-maintenance-check.sh` heredoc).
- Added `.claude/rules/git-workflow.md` (referenced by `block-main-destructive-git.sh`) and `.claude/rules/task-orchestration.md`.
- Added `paths:` frontmatter to `storybook.md` and `tailwind.md` for scope-based auto-loading, matching the other scoped rules.
- `settings.json`: `PreToolUse Edit|Write` → `Edit|Write|MultiEdit`; `UserPromptSubmit` matcher normalized `"All"` → `""`.
- Wiki: rewrote [[Claude Hooks]] and [[Claude Integration]] to reflect the new hook set + matcher changes; updated [[Test Runner]] to point at the hook; added [[Git Workflow]] and [[Task Orchestration]] concept pages.

## [2026-04-21] feat | Claude Integration Conventions concept page + skill references convention + TDD skill restructure

- Added [[Claude Integration Conventions]] concept page (opt-in, not auto-loaded) + formalized skill `references/` convention on [[Claude Skills]] + registered in index (GAP.md Phase 3).
- Renamed from `concepts/Claude Integration.md` → `concepts/Claude Integration Conventions.md` to resolve wikilink collision with the pre-existing `modules/Claude Integration.md` (same disambiguation pattern used for MSW/Storybook).
- TDD skill restructured: `SKILL.md` is now stack-agnostic; React/Vitest/MSW content moved to `.claude/skills/tdd/references/tests-react.md`. `tests.md` and `mocking.md` deleted (content migrated).

## [2026-04-21] update | disambiguate duplicate-name wiki pages

Renamed `modules/MSW.md` → `modules/MSW Handlers.md` and `modules/Storybook.md` → `modules/Storybook Stories.md`. Obsidian's bare-filename wikilink resolution collapsed the two "MSW" and two "Storybook" pages onto one target each, leaving the other as a graph orphan. Updated all module-intent wikilinks (sources/Initial Ingest, dependencies/MSW, dependencies/Storybook, modules/Services, modules/Testing, concepts/API Service Pattern, flows/Theme Flow, index). Dependency-intent `[[MSW]]` / `[[Storybook]]` references still point to `dependencies/` pages. Added a `## Meta` section to `wiki/index.md` so `lint-report-2026-04-21` is no longer an orphan.

## [2026-04-20] update | docs reframe — manager/IC voice + surface wiki Q&A

- README tagline extended with "grounded enough in the stack to answer how-do-I questions without re-reading the codebase" — surfaces the wiki Q&A use case alongside code-task capability.
- Expanded wiki bullet with concrete ask-Claude examples ("how do I add a new route?", "how does dark mode wire through?", "what's the testing layer setup?").
- Swept DIY-user framings across README + wiki: [[GAIA Philosophy]] "remove it / swap them" → "ask Claude to rip it out / swap them in"; [[Chromatic Opt-Out]] leads with "ask Claude", keeps steps as a review reference; [[Claude Hooks]] "Adding hooks" section, [[Middleware]], [[Pages]], [[Services]] all reframed to "ask Claude" (flags `/new-route`, `/new-service` where applicable). README FontAwesome "you're free to change" → "ask Claude to swap it for Heroicons, Lucide…".
- Commit: `86bf0e4`

## [2026-04-20] refactor | code-review-audit agent rewrite + quality gate scoping

- `.claude/agents/code-review-audit.md`: split labor between main agent (cross-cutting security / architecture / performance / a11y / edge cases) and subagents (line-level rule compliance) to stop duplicating work. Dispatch 3 subagents + `react-doctor` in a single parallel tool call. Gate each subagent on file scope (no `.tsx` → skip Subagent 1, etc.). Added accessibility as a review dimension. Stripped Supabase heritage (RLS, service keys, `_auth+/`, PKCE, `useDebounce`) left over from the template's prior project. Relabeled subagent rule sources to point at current skills (react-code, typescript, tailwind) + rules (new-route, i18n, accessibility, tailwind). Tightened mission preamble (dropped elite-persona framing); made "What's Done Well" optional to avoid filler.
- `.claude/rules/quality-gate.md`: skip the gate entirely when no staged file is source (`*.ts|tsx|js|jsx|mjs|cjs|css`) or a gate-affecting config (`package.json`, `tsconfig*`, `vite.config.*`, `vitest.config.*`, `playwright.config.*`, `eslint.config.*`). Markdown-only, `.claude/**`, `wiki/**`, or image-only commits now skip straight to commit.
- Commit: `f85b2f2`

## [2026-04-20] feat | integrate tdd + playwright-cli + React Doctor into trust stack

- README reframe: tagline "Claude as your lead engineer"; two pillars "How GAIA makes Claude trustworthy" + "How GAIA keeps Claude token-efficient". Rules count 11→15. `/gaia-init` Step 8 split into "Install tools" (`@playwright/cli` binary + React Doctor curl) and "Install plugins" (typescript-lsp, claude-obsidian). Bundled skills 4→6 in comparison table.
- TDD skill tailored for GAIA: `SKILL.md` gained a "GAIA testing layers" table (hook/component/service/E2E); `tests.md` rewritten with `composeStory`, `renderHook`, MSW-backed service examples; `mocking.md` rewritten around MSW-first boundaries (`database` factory + `resetTestData()`). Generic design files (`interface-design.md` / `deep-modules.md` / `refactoring.md`) left untouched. Matt Pocock credit in README only — `SKILL.md` stays lean since it auto-loads.
- `code-review-audit.md`: React Doctor invocation now uses `--verbose --diff` (scans only modified files) so the pre-merge pass stays cheap.
- Commit: `d20f46a`

## [2026-04-20] delete | Phase D — remove entire auth stack

Deleted all auth code: `app/routes/_auth+/`, `app/routes/_session+/profile+/`, `app/routes/actions+/logout.ts`, `app/services/gaia/auth/`, `app/services/gaia/user/`, `app/sessions.server/auth.ts`, `app/pages/Auth/`, `app/pages/Session/`, `app/state/user.tsx`, `app/languages/{en,ja}/auth.ts`, `app/languages/{en,ja}/pages/profile/`, `test/mocks/auth/`, `test/mocks/user/`, `wiki/flows/Auth Flow.md`, `wiki/dependencies/remix-auth.md`. Dropped deps: `remix-auth`, `remix-auth-form`, `spark-md5` (+ `@types/spark-md5`). `app/routes/_session+/_layout.tsx` rewritten as minimal stub preserving the folder as a hook point for consumer auth guards. `app/state/index.tsx` trimmed to `ThemeProvider` only; `UserProvider` and `User` type removed. Form components `InputEmail`/`InputPassword` migrated default label namespace from `auth` → `common`; `email`, `emailPlaceholder`, `password` keys added to both `en/common.ts` and `ja/common.ts`. `database.user` factory and `resetTestData` deleted from `test/mocks/database.ts` (orphaned after auth removal). `SESSION_SECRET` retained in env — still used by `remix-toast`, theme cookie, and language cookie. Wiki updated: [[Sessions]] rewritten for theme/language only, [[Routing]] documents `_session+/` hook point, [[State]]/[[Services]]/[[Pages]]/[[overview]]/[[GAIA Philosophy]]/[[Folder Structure]]/[[React Router 7]] surgically cleaned.

## [2026-04-20] delete | Phase C — remove all non-auth example/teaching code

Deleted the `things` service and all associated example code: `app/services/gaia/things/`, `app/components/ExampleConsumer/`, `app/state/example.tsx`, `app/pages/Public/Things/`, `app/pages/Public/IndexPage/Examples/`, `app/pages/Public/IndexPage/TechStack/`, `app/routes/_public+/things+/`, `app/languages/{en,ja}/pages/things.ts`, `test/mocks/things/`, `.playwright/e2e/things.spec.ts`, `.react-router/`. Rewired all dependents: `app/state/index.tsx` (ExampleProvider removed), `app/services/gaia/index.server.ts` (things export removed), `app/services/gaia/urls.ts` (things/thingsId removed), `app/languages/{en,ja}/pages/index.ts` (things removed), `app/languages/{en,ja}/pages/_index.ts` (serviceExample + techStack keys removed), `test/mocks/index.ts` + `database.ts` (things handlers/factory removed), `test/stubs/state-stub.tsx` (simplified to `() => (Story) => <State><Story /></State>`), `app/pages/Session/Profile/ProfilePage/UserCard/index.tsx` (ExampleConsumer import+usage removed), `app/pages/Public/IndexPage/index.tsx` (reduced to minimal `<section><h1>{t('title')}</h1></section>` placeholder). Wiki updated: [[Services]], [[Pages]], [[Components]], [[Testing]], [[i18n]], [[remix-flat-routes]].

## [2026-04-20] update | Phase A — rules + wiki pattern synthesis (pre-deletion gap-fill)

Prepared the template to delete example code and VitePress docs without losing the lessons they teach. 6 parallel Sonnet agents synthesized patterns from existing code into durable rules + self-contained wiki pages.

- New rules: `state-pattern.md`, `tailwind.md`, `storybook.md`, `playwright.md` — all auto-apply via path globs
- Updated rule: `api-service.md` — generalized `things`→`resources`, dropped `auth` from barrel example, added optional `state.tsx` to checklist (inconsistency flagged by agent vs real code)
- Wiki rewrites (fully self-contained, no example-code refs): [[API Service Pattern]], [[MSW]], [[State]], [[Storybook]], [[Playwright]]
- Service↔MSW contract explicitly documented — `url()` helper, snake_case-on-wire vs camelCase-after-ky-hooks, dev/test/CI init paths
- `/new-service` command — replaced "following the things pattern" strings with `[[API Service Pattern]]` / `[[MSW]]` wikilinks; removed `login` from URL example

## [2026-04-20] update | wiki-coherence hooks + /init interceptor

- Added `intercept-init.sh` (UserPromptSubmit) — blocks built-in `/init`, auto-invokes `/gaia-init`. Self-removes on `/gaia-init` completion.
- Added `wiki-session-start.sh` + `wiki-session-stop.sh` — compensate for a claude-obsidian plugin gap where `PostToolUse` auto-commits wiki changes, leaving the plugin's own Stop diff-check empty and its `wiki/hot.md` refresh prompt never firing. Our Stop hook checks commits between a session-start SHA marker and HEAD, covering the auto-commit case. Plugin's Stop still catches working-tree (uncommitted) changes — the two complement each other.
- Added `wiki-maintenance.md` rule — judgment-based wiki update check that fires pre-commit alongside `quality-gate`.
- Pages updated: [[Claude Integration]] (Hooks section restructured by event type, 3 new hooks documented)

## [2026-04-20] update | /audit-knowledge command added

- Adapted `.claude/commands/audit-knowledge.md` from another project; portable path resolution (no hardcoded user paths); `.claude/audit/` gitignored
- Pages created: [[Audit-Knowledge Command]]
- Pages updated: [[Claude Integration]] (commands table), [[overview]] (Knowledge Hygiene section), [[index]]

## [2026-04-20] ingest | Form components deep dive + things service

- Sources: `app/components/Form/*` (all 15 components + Field subparts + YearMonthDay utils), `app/services/gaia/things/*`
- Pages created: [[Form Field]], [[Form Text Inputs]], [[Form Select]], [[Form YearMonthDay]], [[Form Choices]], [[Form Layout]], `things Service` (deleted Phase C)
- Pages updated: [[Form Components]] (deep-dive column), [[Services]] (things cross-link), [[API Service Pattern]] (things cross-link), [[index]], [[hot]]
- Key insight: YearMonthDay's Conform integration requires two non-obvious workarounds — native `input` event stop-propagation at the container div (React's synthetic delegation routes through `document`, same node as Conform's listener, so React-level `stopPropagation` is a no-op) and DOM-level hidden input value sync before `onChange` fires so Conform's FormData read returns the new value.

## [2026-04-20] ingest | Claude commands handoff + pickup

- Sources: `.claude/commands/handoff.md`, `.claude/commands/pickup.md`
- Pages created: [[Handoff Command]], [[Pickup Command]]
- Pages updated: [[Claude Integration]] (commands table), [[index]], [[hot]]
- Key insight: Session continuity loop — `/handoff` writes a synthesized end-of-session doc to `.claude/handoff/`, `/pickup` reads the latest one at session start, archives it once work resumes. `wiki/hot.md` is the fallback.

## [2026-04-20] ingest | Initial Ingest of GAIA React

- Source: project codebase + docs + .claude/
- Summary: [[Initial Ingest]]
- Pages created:
  - Top-level: [[overview]], [[index]], [[hot]], CLAUDE (later renamed to [[README]])
  - Modules: [[Folder Structure]], [[Routing]], [[Pages]], [[Components]], [[Form Components]], [[Services]], [[Sessions]], [[State]], [[Middleware]], [[Hooks]], [[Utils]], [[Styles]], [[i18n]], [[Testing]], [[Storybook]], [[MSW]], [[Claude Integration]]
  - Flows: `Auth Flow` (deleted Phase D), [[Theme Flow]], [[Language Flow]], [[Form Submit Flow]]
  - Entities: [[GAIA]], [[Steven Sacks]]
  - Dependencies: [[React Router 7]], [[remix-flat-routes]], `remix-auth` (deleted Phase D), [[remix-i18next]], [[remix-toast]], [[Conform]], [[Zod]], [[Ky]], [[i18next]], [[Tailwind]], [[FontAwesome]], [[Vitest]], [[React Testing Library]], [[Playwright]], [[Chromatic]], [[Storybook]], [[MSW]], [[Husky]], `VitePress` (deleted Phase D)
  - Decisions: [[No Component Library]], [[TypeScript Language Files]], [[Thin Routes]], [[Co-located Tests Folder]], [[composeStory Pattern]], [[Quality Gate]]
  - Concepts: [[GAIA Philosophy]], [[Coding Guidelines]], [[Component Testing]], [[API Service Pattern]], [[Accessibility]], [[ESLint Fixes]], [[Test Runner]], [[Pre-commit Hooks]], [[PR Merge Workflow]], [[Code Review Audit Agent]], [[Claude Hooks]], [[Claude Skills]], [[Chromatic Opt-Out]]
- Pages updated: n/a (vault was empty)
- Key insight: GAIA's value is the **integration**, not any single tool — 20+ ESLint plugins, pre-commit hooks, four-layer testing, MSW everywhere, Storybook + Chromatic, end-to-end dark mode + i18n + auth, plus Claude Code tooling, all wired together and working out of the box.
