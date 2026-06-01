# Changelog

All notable changes to GAIA React are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- **Major** — breaking changes to skill/command API, Node/React/React Router major bumps.
- **Minor** — new skills, commands, or wiki concept pages; opt-in features, removed or renamed `.claude/` paths.
- **Patch** — bugfixes, docs, and in-range dependency bumps.

## [Unreleased]

### Added

- pnpm supply-chain hardening — root `pnpm-workspace.yaml` with `minimumReleaseAge` (7-day quarantine) and `trustPolicy: no-downgrade` (#251)

### Changed

- skip redundant CI on prose-only commits: `code-review-audit` and `Vitest and Playwright` gate on the delta *since that check last passed green* instead of the full PR diff, so a code commit that passes followed by a wiki/CHANGELOG commit re-runs neither. A new `.github/audit/resolve-check-base.sh` resolves the last-green ancestor for a named check (the audit reuses the version-aware `resolve-audit-base.sh`); both fall back to full scope when no green ancestor exists. `Run Chromatic` stays always-on — TurboSnap already minimizes it and its app-posted statuses stay adopter-safe (#254)
- enable React Router v8 future flags for early v8 readiness: `v8_passThroughRequests`, `v8_splitRouteModules`, `v8_trailingSlashAwareDataRequests`, `v8_viteEnvironmentApi` (#251)
  - **Migration (`v8_passThroughRequests`):** loaders/actions now receive the raw `request`, so `request.url` keeps the `.data` suffix and `?index`/`?_routes` params on data requests. If you customized `app/root.tsx` (or any loader) and call `new URL(request.url)` for normalized routing, switch to the new normalized `url` arg (a `URL` instance) — e.g. `({request, url}) => url.pathname`. `/update-gaia` delivers the updated `app/root.tsx` as a conflict patch for customized files, so apply this by hand when resolving it.
- `code-review-audit` CI reviews only the diff since the last clean audit instead of the full `origin/main...HEAD` diff on every push, cutting wall-clock on multi-push PRs. A new `.github/audit/resolve-audit-base.sh` resolves the most recent ancestor that passed a clean audit under the current `.gaia/VERSION`; it falls back to full scope when none exists, so it never skips uncleared code (#252)

### Fixed

- `Form/Chain` composes `className` with `twMerge` instead of `twJoin`, so a consumer's utilities override the component's defaults (#251)

## [1.3.4] — 2026-05-26

### Added

- bypass audit-marker requirement on chore(deps) PRs (#246)
- skip required workflows on chore(deps) PRs (#245)

### Changed

- reframe dispatched-check rollup ADR around polling architecture

### Fixed

- seed missing files; round-trip GH issues; drop UAT leaks (#247)
- poll dispatched runs and stamp jobs into PR rollup (#243)
- stamp dispatched check runs into PR rollup (#240)
- re-trigger required checks on self-heal HEAD (#238)

## [1.3.3] — 2026-05-22

### Added

- `gaia setup-ci check-drift` — primitive that byte-compares rendered `.github/workflows/gaia-ci-*.yml` against a fresh in-memory render. Reports `{drifted, missing, in_sync}` per tool.
- `/setup-gaia-ci` Step 2 calls `check-drift` on configured repos. On drift, prompts for re-render / skip / full reconfigure instead of unconditionally short-circuiting.
- `/setup-gaia-ci` Step 11.5 — lightweight drift-fix branch + commit + PR path. Regenerates only the workflow YAML; tool selection and bot token untouched.

## [1.3.2] — 2026-05-22

### Fixed

- dedupe audit issues, scope pre-run-skip per-tool, set git identity (#233)

## [1.3.1] — 2026-05-22

### Fixed

- `create-worktree.sh` — WorktreeCreate hook that creates the worktree and returns its path (#231)
- `update-gaia` — remove phantom `gaia update merge` CLI call from Step 7 (#231)
- `update-gaia` — Step 9 cache-bust writes the new version instead of preserving stale fields (#231)
- `update-gaia` — open a PR at the end of the run instead of stranding the branch (#231)

## [1.3.0] — 2026-05-22

### Added

- allow `/gaia plan` and `/gaia spec` to run concurrently in separate sessions without clashing — collision-proof atomic writes prevent racing writers from corrupting committed state (#198, #207)
- add axe-core accessibility testing for Vitest and Playwright (#205)

### Changed

- derive controlled counter from value, document latest-ref pattern (#217)
- thread auth and language per request (#194)
- single-pass deepRemoveNil
- note why the NonceContext default is an empty string
- record the unsafe-inline and no-report-uri trade-offs
- rename `/setup-gaia` command to `/setup-cloned-gaia-project`

### Fixed

- add 15_000ms timeout to per_domain_page_counts test (#225)
- macOS sed portability + +types ignore bucket (#221)
- accept GitHub commit status as merge gate signal (#219)
- skip setLocalLength in controlled mode, move latest-ref comment (#218)
- deferred code-review-audit findings from PRs #190-214 (#216)
- a11y/perf follow-ups for Checkboxes, FieldDescription, TextArea (#213)
- a11y for field descriptions, drop nested live region (#212)
- audit small fixes — amended_rate, rollback msg, parseKeyPath, generator dup, a11y (#210)
- revert-ledger lock per-PR scope + stale recovery (#209)
- robust flag derivation in sync-land (#208)
- atomic-write deferred writers + crypto temp-path (#207)
- cover .playwright/ entry points (#206)
- correctness gaps in init/schemas/storage (#204)
- correctness gaps in release/scaffold (#203)
- correctness gaps in automation/telemetry (#202)
- correctness gaps in intent-clarity-gap (#201)
- correctness gaps in setup-ci/ci/setup (#200)
- correctness gaps in wiki/update/update-deps (#199)
- atomic file writes with fsync (#198)
- close correctness gaps in utils and api helpers (#197)
- close XSS vector and error-handling gaps (#196)
- correct edge cases across form components (#195)
- preserve falsy success values
- reject non-local redirect targets
- add GAIA-Audit commit-status fallback to the skip gate
- write GAIA-Audit commit status instead of pushing an empty marker commit
- replace client-hints reload with pre-paint inline script
- implement per-request nonce Content-Security-Policy

## [1.2.3] — 2026-05-20

### Added

- repo-scope main/PR-merge guards + create-gaia release lockstep

### Fixed

- update workflow template snapshots for id-token permission addition
- add json-strip transform to stop maintainer-only package.json keys reaching adopters
- harden block-main against multiple git -C flags
- close multi--C ambiguity in repo-scope; handle --repo= form

## [1.2.2] — 2026-05-19

### Fixed

- drop default id-token: write from pnpm-audit workflow

## [1.2.1] — 2026-05-19

### Added

- RUNNING sentinel + concurrent orchestrator detection (#180)

### Changed

- drop second inline PR ref in Release Workflow prose
- drop inline PR ref in Release Workflow prose
- correct the release PR merge step

### Fixed

- health-audit distribution-boundary remediation (#182)
- Linux WSL compatibility for husky hook and CI workflow permissions (#181)
- atomic mkdir prevents TOCTOU race on concurrent plan creation (#179)

## [1.2.0] — 2026-05-12

### Added

- `/gaia fitness` — Claude-integration health check + auto-heal (#169, #171)
- ai shimmer animation on `gaia-logo.svg` (#168)

### Fixed

- `release preflight` tolerates wiki-sync squash-artifact drift (this release)

## [1.1.1] — 2026-05-11

### Fixed

- gaia release reference to maintainer
- bug fixes from live init run (#165)

## [1.1.0] — 2026-05-10

### Added

- robust a11y tooling stack (#156)
- close slice-4 forward-refs (wiki + update-deps) (#153)
- add Phase A configure-automation step (#148)
- spec-001 slice 4 — /setup-gaia-ci slash command (Phase B) (#147)
- spec-001 slice 3 — GAIA CI workflow YAML generation (#146)
- spec-001 slice 2 — auto-merge + auto-revert workflow shape (#145)
- spec-001 slice 1 — smart-cron + per-tool state files (#144)
- add probe-after verification pass to Step 8 (#139)
- surface GAIA-Audit trailer invalidation count in summary (#140)
- rename /wiki-{sync,consolidate,lint} → /gaia wiki <sub> to resolve plugin collision (#121)
- /gaia spec auto + branch-default plan isolation
- code-review-audit CI gate + GAIA-Audit trailer skip mechanism (#117)
- autonomous triage workflow for gaia-forensics issues (#104)
- /gaia forensics — end-user bug-report bridge (#105)
- bundle-time scrub + runtime-deps primitives (#98)
- telemetry v1 (SPEC-001) — three-stream architecture (#91)
- tree READMEs + inventory audit appended to SPEC-005
- rule file + port smoke-uat-write + relocate serena
- wire before_implement hook + speckit.gaia.uat-write into manifest
- wiki-sync handoff + revised-contracts §2 amendment
- implement before_implement UAT renderer + templates + slash command
- wiki-promote routing + page render + cross-links
- wiki-promote PR-merge detection + spec-close drain
- add UAT divergence policy rule stub
- manifest entry + wiki-promote command skeleton
- install spec-kit + GAIA extension + GAIA preset during scaffold
- real spec-kit extension + preset for GAIA
- salvage GAIA wrapper scaffold + utilities from PR #84
- integrate Serena MCP (#82)
- add knip for dead code detection (#80)

### Changed

- codify post-merge state verification + --auto vs --admin (#155)
- tighten adopter README template (#138)
- pre-launch gap fixes (CI opt-in, rollback, WSL stance) (#137)
- add manual smoke procedure for before_implement hook
- scrub fictional on_save references from smoke.md
- integrate Serena MCP and document knip dead code detection

### Fixed

- exclude CLI-Binary-Split ADR; add automation.json sentinel (#163)
- replace rm cache-bust with Write tool to avoid hook conflict (#162)
- bust cache immediately on confirmed updates (#161)
- defer stamp push until after marker write (#158)
- split release CLI into maintainer-only binary (#133)
- push GAIA-Audit empty commit to upstream so CI's audit skips (#130)
- skip audit on workflow self-mod, reword abort message (#125)
- surface code-review-audit aborts as red checks (#123)
- CI source-changes gate, knip binaries, instruction-file paths (#122)
- relocate audit-stamp bats + repair latent path bug in 4 existing bats (#119)
- SPEC-005 shared-state symlinks + slash-command worktree guards (#118)
- address remaining audit suggestions from PR #114 (#116)
- audit advisory follow-ups (S-1/S-2/S-3) (#114)
- bootstrap-labels.sh — shorten needs-human desc, add gaia-forensics (#113)
- SPEC-003 triage workflow correctness + hardening (#110)
- close SPEC-004 sharp edges (setup-state, pre-merge audit, post-merge cleanup) (#109)
- address pre-merge audit findings (#106)
- enforce exclusive ceiling in spec-kit version-check

### Changed

- **BREAKING:** `/wiki-sync`, `/wiki-consolidate`, `/wiki-lint` slash commands are removed. Use `/gaia wiki sync`, `/gaia wiki consolidate`, `/gaia wiki lint` instead — or `/gaia wiki` for the full chain. Motivation: `/wiki-lint` collided with the `claude-obsidian` plugin's skill of the same name. Moving everything under the `/gaia` router namespace eliminates the collision and groups wiki maintenance with the other GAIA workflows. Hooks (`wiki-drift-check`, `wiki-commit-nudge`, `wiki-session-stop`) and statusline now point at the new names. Smoke tests under `.gaia/tests/smoke/wiki-sync/` updated. The playbooks moved from `.claude/commands/wiki-{sync,consolidate,lint}.md` to `.claude/skills/gaia/references/wiki/{sync,consolidate,lint}.md`.
- `/gaia audit` no longer covers intra-wiki duplication or broken-wikilink checks — those overlapped with `/gaia wiki consolidate` and `/gaia wiki lint`. Run `/gaia wiki` separately for wiki-internal audits.

### Added

- Dead-code detection via [knip](https://knip.dev). Run `pnpm knip` after refactors or before release-candidate PRs. Template-aware config marks GAIA's library surface as entries so intentional exports aren't flagged. `.claude/rules/knip.md` guides Claude on when to suggest it.
- Serena MCP server registered by `/gaia-init` for LSP-backed code intelligence. Pinned at `v1.2.0`. Requires `uv`. New `.claude/rules/code-search.md` routes Claude to Serena for TS/TSX symbol queries; `/gaia wiki sync` no longer marks new component / hook / service files WORTHY (Serena handles inventory freshness). See `wiki/concepts/Serena Integration.md` for the division of labor.

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

[Unreleased]: https://github.com/gaia-react/gaia/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/gaia-react/gaia/releases/tag/v1.1.0
[1.0.5]: https://github.com/gaia-react/gaia/releases/tag/v1.0.5
[1.0.4]: https://github.com/gaia-react/gaia/releases/tag/v1.0.4
[1.0.3]: https://github.com/gaia-react/gaia/releases/tag/v1.0.3
[1.0.2]: https://github.com/gaia-react/gaia/releases/tag/v1.0.2
[1.0.1]: https://github.com/gaia-react/gaia/releases/tag/v1.0.1
[1.0.0]: https://github.com/gaia-react/gaia/releases/tag/v1.0.0
