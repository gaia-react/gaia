# Whole-Wiki Staleness + Completeness Audit

> Artifact. Method: 35 source-locality batches covering every non-meta wiki page, each audited against shipped `app/`, `.claude/`, `.github/`, `.gaia/`, `.specify/`, and `package.json`. Every stale finding passed an adversarial refute pass before inclusion. Raw: 147 verified stale + 68 missing, deduped below to the actionable set. `hot.md`, `log.md`, and `wiki/meta/` excluded by design.

**Summary:** 95 stale findings (39 high, 35 medium, 21 low) + 38 missing-info gaps (5 high, 18 medium, 15 low). Two structural themes dominate and account for most high-severity drift: (1) the **theme/ThemeSwitch split** — wiki repeatedly claims the resource route holds the component and hooks when they live in `app/components/ThemeSwitch/` and `app/hooks/useTheme.ts`; (2) the **service/MSW URL contract** — wiki teaches a single shared `GAIA_URLS` constant that is an empty stub; the real contract is per-domain `{NAME}_URLS`. Three more high-impact clusters: the dead **`/gaia` router** referenced across six pages, **scaffolder/CLI** path and flag errors, and **dependency version frontmatter** drift across ~12 pages.

---

## Modules (high-sev count: 9)

### Stale
- **CLI Scaffolding.md** — Service path documented as `app/services/<name>/`; actual is `app/services/gaia/<name>/`. Fix the path and list emitted files (`requests.ts`, `parsers.ts`, `urls.ts`, `index.ts`).
- **CLI Scaffolding.md** — Component: test/story optionality is backwards. `tests/index.test.tsx` is always written; the story is the optional file (dropped by `--no-story`) at `tests/index.stories.tsx`.
- **CLI Scaffolding.md** — Hook: no JSDoc is emitted; the Vitest test is always written (no skip flag) at `app/hooks/tests/<name>.test.ts`.
- **CLI Scaffolding.md** — "Route flows do not edit barrels" is false: `--i18n` inserts into `app/languages/en/pages/index.ts`.
- **CLI Scaffolding.md** — "Templates include i18n-key stubs" is overbroad: only route templates carry i18n, gated on `--i18n`.
- **Services.md** — `GAIA_URLS` single-shared-constant claim is wrong; root `app/services/gaia/urls.ts` is an empty `{}` stub with no consumers. Each domain owns `{NAME}_URLS` in its own `urls.ts`, imported by both requests and handlers.
- **Services.md** — Per-domain `api.ts`/`index.server.ts` and `auth/`/`users/` subfolders do not exist; domains emit `parsers/types/requests/urls/index.ts` and share the root `api.ts`.
- **MSW Handlers.md** — Handlers import per-domain `{NAME}_URLS`, not root `GAIA_URLS`.
- **MSW Handlers.md** — `resetTestData()` runs in an `afterEach` in `test/rtl.tsx`, not "on module load" or in a `beforeEach`. Drop the "always call it manually in beforeEach" guidance.
- **Styles.md** — `theme-switch.tsx` holds only the action + schema; ThemeSwitch UI lives in `app/components/ThemeSwitch/`, hooks in `app/hooks/useTheme.ts`.
- **Styles.md** — `useTheme.ts` derives optimistic theme from `useFetchers()`, not "from the loader"; loader cookie is read separately via request-info.
- **Components.md** — ThemeSwitch lives at `app/components/ThemeSwitch/`, not the route. Reverse the bullet.
- **Pages.md** — "Legal pages live as static JSX in the route, no `pages/Legal/` folder" is false: `app/pages/Legal/{Privacy,Terms}Page/` exist; routes render them.
- **Folder Structure.md** — `sessions.server/` Concern says "(language, theme)"; theme is not stored there (`app/utils/theme.server.ts` owns `__theme`). Drop "theme".
- **i18n.md** — Loader example casts `getInstance(context as RouterContextProvider)`; shipped loaders use `getInstance(context)` with no cast.
- **Routing.md** — Actions claim `parseWithZod(formData, {schema})`; shipped route actions use plain Zod `safeParse`. (Same drift on Conform.md, Thin Routes.md, Form Components.md, Form Submit Flow.md.)
- **State.md** — `app/state/index.tsx` is not a barrel and composes nothing; it's a single passthrough `<State>`. Page self-corrects one line later.
- **Utils.md** — `purpose`/body say "pure utility functions"; `app/utils/` also ships hooks and a context provider (nonce, request-info).
- **Form Components.md** — `TimePicker` cited as a shipped stateful Form component; it doesn't exist. Keep only `YearMonthDay`.

### Missing
- **Routing.md / overview.md** — `resources+` route group is absent from the convention list though it ships `theme-switch.tsx`. Add it; clarify `actions+` vs `resources+` for no-UI form endpoints.
- **CLI Scaffolding.md** — Per-subcommand flags are entirely undocumented (`--endpoints`/`--schema` required for service; `--group` required for route; `--no-story`, `--props`, `--params`, etc.). High: the CLI errors out without required flags. Also: idempotency/collision behavior (`writeFileIfAbsent`), and template src-of-truth (`src/scaffold/templates/` vs build artifact `.gaia/cli/templates/`).
- **Pages.md** — Page components can take loader-derived `{title, description}` props and render their own `<title>`/`<meta>`; co-located tests/stories are aspirational (only IndexPage ships a story).
- **i18n.md** — `app/i18n.ts` config knobs (`defaultNS`, `lowerCaseLng`, `returnNull: false`, `react.useSuspense: false`, custom number `format`).
- **Utils.md / Hooks.md** — Enumerated helper list omits `nonce`, `request-info`, `theme.server`; some hooks live under `app/utils/`, not only `app/hooks/`.
- **MSW Handlers.md** — Two entry points: browser worker `test/worker.ts` (prepends a `ping` passthrough) vs Node SSR `test/msw.server.ts` (`startApiMocks`, `globalThis.__MSW_SERVER`, HMR-surviving).
- **Testing.md** — Playwright a11y surface (`.playwright/a11y.ts`, `fixtures.ts`, critical/serious fail threshold); `globalSetup` warm-up + `retries: 0` local self-heal design.

---

## Concepts (high-sev count: 12)

### Stale
- **API Service Pattern.md** — `requests.server.ts` (`.server.ts` server-only enforcement) is wrong: scaffolder emits `requests.ts`.
- **API Service Pattern.md** — Per-domain `index.server.ts` barrel claim is false; the domain `index.ts` re-exports only parsers/types/urls; requests are imported directly.
- **API Service Pattern.md** — `GAIA_URLS` single-constant claim + example are wrong; use per-domain `{NAME}_URLS`.
- **Claude Integration.md (modules)** — `wiki-update-evaluator.sh` / `claude -p` hook does not exist; design is convergent (`wiki-commit-nudge.sh` + user `/gaia-wiki sync`).
- **Claude Integration.md (modules)** — `intercept-init.sh` is `UserPromptExpansion` (matcher `init`), overrides (does not block), and does not remove itself.
- **Claude Integration.md (modules)** — settings.json summary is wrong on many counts: no `Bash(git commit:*)` matcher, PostToolUse uses Bash+Task matchers, Serena MCP is user-global not in settings, omits UserPromptSubmit/PostCompact/WorktreeCreate/env/statusLine.
- **Claude Integration.md (modules)** — Blocking-hooks list omits `block-no-verify.sh`.
- **Claude Integration.md (modules)** — `/gaia router` and `/gaia <subcommand>` dispatch do not exist; workflows are standalone commands/skills reading `references/`.
- **Claude Integration.md (modules)** — Context-triggered skill list omits `a11y-fixes`; `release-notes` (maintainer) unlisted.
- **GAIA Audit.md / GAIA Handoff.md / GAIA Pickup.md / GAIA Plan.md / GAIA Spec.md** — All five say "dispatched by the `/gaia` router skill"; the router was split into discrete `/gaia-*` commands/skills. Replace per-page with the real dispatcher.
- **GAIA Plan.md** — Clipboard-copy behavior (pbcopy/wl-copy/xclip probing, "Prompt copied to clipboard") was removed; it only prints a fenced block + "Type /clear and paste the prompt above." Also: model choice is an `AskUserQuestion` ("Use Opus (Recommended)"), not a `(Y/n)` prompt.
- **GAIA Init Workflow.md** — `finalize` does not commit; it deletes the init interceptor hook, prunes the settings entry, and deletes `gaia-init.md`.
- **GAIA Init Workflow.md** — `configure-i18n` does not write `.gaia/local/i18n.json`; it edits `app/languages/index.ts` and `app/i18n.ts`.
- **GAIA Init Workflow.md** — `wire-statusline` surfaces setup gate + update-gaia/update-deps/gaia-harden/gaia-audit nudges (not drift count/mentorship), and writes a `statusLine` block, not a hook.
- **Task Orchestration.md** — Clipboard auto-copy/probing is fabricated; plan prints a fenced block for manual copy.
- **Telemetry.md** — Envelope: no `install_id` field; schema is `EnvelopeSchema`/`Envelope` (not `UniversalEnvelope`); real fields add `agent_type`, `session_hash`, `schema_version`.
- **Telemetry.md** — PostToolUse Task hook does not emit `engineer_return`; it emits `code_review_audit_finding`, `uat_pass`, `needs_context_returned`, `blocked_returned`. (Same on the "Pairs with" bullet.)
- **Telemetry.md** — `pnpm bundle` emits two binaries; `gaia` is ~1.1MB not ~630KB.
- **Test Runner.md** — `block-bare-test.sh` matcher is plain `Bash`, not `Bash(pnpm *)`/`Bash(npm *)`; command anchoring is in the script.
- **Claude Hooks.md (Agentic Design.md)** — Per-shape `Bash(pnpm *)`/`Bash(git *)`/`Bash(gh pr merge:*)` matchers do not exist; a single `Bash` matcher fans out, scripts route by command word.
- **Code Review Audit CI.md** — `.gaia/local/plans/code-review-audit-ci/trailer-format.md` frozen-contract pointer is dead (gitignored, never exists). Point to `.github/audit/check-trailer.sh` and `.claude/hooks/audit-stamp-trailer.sh`.
- **Update Workflow.md** — `gaia-session-update-prompt.sh` SessionStart hook does not exist; updates surface via the statusline (`gaia-statusline.sh` + `check-updates.sh`).
- **Release Workflow.md** — CHANGELOG headings carry no `v` prefix (`## [X.Y.Z]`); a `v`-prefixed heading breaks extraction. `pnpm bundle` at root fails; use `pnpm --filter @gaia-react/cli bundle`. `health-audit.md` line citation (line 20 → 26) is brittle; drop it.
- **Git Workflow.md** — Hook described as `if: Bash(git *)`; actual matcher is `Bash`, git filtering is in-script.
- **Wiki Management.md** — `gaia wiki state` field is `head_short`, not `head_sha`.
- **Wiki Sync.md** — Sync branch is `wiki-sync/<date>-<short_sha>`, not `wiki/sync-YYYY-MM-DD`.
- **Policy-Memory Loop.md** — Statusline segment is `Run /gaia-harden (N recurring patterns)`, not `Run /gaia-harden review (N)`.
- **GAIA Spec.md** — Steps 3/5 use dotted `/speckit.specify` / `/speckit.clarify`; invocation is hyphenated `/speckit-specify` / `/speckit-clarify`.
- **GAIA Audit.md** — `[[GAIA Wiki]]` is a dead wikilink; use `[[Wiki Management]]`.
- **Claude Skills.md** — `/gaia router` four-refs table is wrong (nine refs, no router). (Note: the audit flow IS still `Sonnet + Sonnet`; only fix the router framing and add the research-then-gate description.)
- **Claude Integration Conventions.md** — §11 example folders `wiki/app/`, `wiki/brand/`, `wiki/business/` don't exist; use `wiki/modules/`, `wiki/concepts/`, etc. §1 skills cell propagates the `/gaia router` fiction.
- **Claude Integration Fitness.md** — Canonical hook-event list omits `PostCompact` (the event the repo uses) and lists unused `PreCompact`.

### Missing
- **Claude Hooks.md** — `worthiness-presence-check.sh` (PreToolUse Bash deny on `gh pr merge`) is a real, undocumented merge gate. Also `telemetry-task-postuse.sh` (PostToolUse Task matcher).
- **GAIA Audit.md** — Clean-audit (0-action) auto-apply bypasses the Apply/Discuss/Decline gate.
- **GAIA Init Workflow.md** — `bootstrap-env` and `configure-automation` subcommands undocumented; resume `--from-step` index depends on them.
- **GAIA Spec.md** — GitHub-issue mirror is gated by a default-off opt-in `AskUserQuestion` at session start.
- **Code Review Audit CI.md** — Per-author audit mode (local vs ci) with stand-down + `pending` GAIA-Audit status; knobs `default_mode`, `override_label`, `audit_authors`; fail-closed to `ci`. Major shipped feature absent everywhere. Also: `max_turns` shipped 60 vs documented fallback 30. (Incremental CI Skipping.md needs the `pending`-status terminal state too.)
- **Wiki Sync.md** — `wiki-session-start.sh` SessionStart marker hook (the Stop safety net's marker source; hook count is 7, not 4); GAIA CI deferral mode (`wiki.mode == "ci"` stands hooks down).
- **Telemetry.md** — Full 8-type mentorship event set; the `gaia-maintainer` binary + tarball exclusion.
- **Accessibility.md** — Runtime axe-core layer (`test/a11y.ts` Vitest, `.playwright/a11y.ts` Playwright) entirely undocumented; jsdom-only requirement for the Vitest helper (happy-dom incompatible); cross-ref the `a11y-fixes` skill.
- **Forensics.md** — Second write surface `.gaia/local/telemetry/` reconciles the "read-only" framing.
- **Policy-Memory Loop.md** — Fourth `/gaia-harden review` action `redirect`.

---

## Decisions (high-sev count: 9)

### Stale
- **Thin Routes.md** — Actions use plain Zod `safeParse`, not `parseWithZod`. Route-group list omits `resources+`. Meta pattern is one of two real patterns (route-renders-meta vs page-renders-meta).
- **Dark Mode Modernization.md** — `<ClientHintCheck/>` is not rendered; Document renders an inline `THEME_SCRIPT` (matchMedia). `@epic-web/client-hints` is not a dependency. Switcher shows three icons keyed to preference (incl. desktop for system), not just sun/moon resolved-theme. `theme-switch.tsx` holds only action+schema (hooks/component are elsewhere).
- **Bundle-time Scrub.md** — THREE transform types now (marker-strip, **json-strip**, leak-check), not two — repeated in 3 spots on the page. Second marker-strip targets `.prettierignore` with `#`-comment markers. `wikilink-to-excluded` slug list is incomplete (adds `Release-Notes`, `CLI-Binary-Split`, `Forensics Triage Workflow`, `consolidate-report-*`, `lint-report-*`).
- **CLI-Binary-Split.md** — Byte counts stale AND inverted (adopter is now larger). `category: 4` field does not exist in `.gaia/release-exclude` (prose section headers). No `bin/` directory; `bin` field points at `.gaia/cli/gaia`. `gaia-cli/` exception no longer applies. Maintainer≠adopter+release: adopter carries CI/harden subcommands maintainer omits.
- **Forensics Triage Workflow.md** — `gaia-forensics` label IS in `bootstrap-labels.sh` (first LABELS entry), contradicting "not part of the inventory". Fix-application tools are `Edit,Write` only (no `Read`). Claude auth secret is `CLAUDE_CODE_OAUTH_TOKEN` not `ANTHROPIC_API_KEY`; permissions include `id-token: write`.
- **Co-located Tests Folder.md** — Placement enforced by `check-file/folder-match-with-fex`, not `filename-naming-convention`.
- **spec-kit Extension Strategy.md** — Extension owns five hook-target commands (not three): + `uat-write` (before_implement), `wiki-promote` (after_implement), plus unhooked `spec-close`. Lifecycle covers `before_implement`/`after_implement` too. Canonical artifact path is folderized `.gaia/local/specs/SPEC-NNN/SPEC.md`, not flat.

### Missing
- **TDD RED Verification.md** — `[[tdd]]` wikilink is dead; `tdd` is a skill (`.claude/skills/tdd/SKILL.md`), reference without a wikilink.
- **TypeScript 7 Readiness.md** — `typescript-eslint` is transitive via `@gaia-react/lint`, not a direct dep.
- **Bundle-time Scrub.md** — `json-strip` primitive (strips `bin` + `scripts.test:forensics` from package.json; dot-path `\.` escaping; missing keys skipped silently). High: a load-bearing distribution-boundary primitive with zero coverage.
- **spec-kit Extension Strategy.md / spec-kit.md** — Implement-stage hooks (uat-write, wiki-promote) and `spec-close`; folderized SPEC layout + `spec-folderize.sh` legacy migration.
- **CLI-Binary-Split.md** — Concrete `/gaia-release` invocation (`.gaia/cli/gaia-maintainer release ...` + `pnpm --filter @gaia-react/cli bundle`).
- **Release Workflow.md** — `forensics-triage.yml` is a maintainer-only excluded workflow absent from §9; `[[CLI Binary Split]]` (spaces) dangles vs `CLI-Binary-Split.md`.

### Index
- **index.md** — `CLI-Binary-Split.md` (maintainer-tagged) is not cataloged; add `- [[CLI-Binary-Split]]` inside a `gaia:maintainer-only` block in Decisions.

---

## Dependencies (high-sev count: 5)

### Stale — version frontmatter (apply mechanically)
- **Chromatic.md** `^16.3.0` → `17.4.1` (major behind, high). **Tailwind.md** `4.2.2` → `4.3.1`. **Storybook.md** `10.3.5` → `10.4.6`. **Playwright.md** `1.59.1` → `1.61.0`. **react-icons.md** `5.5.0` → `5.6.0`. **Zod.md** `4.3.6` → `4.4.3`. **Husky.md** lint-staged `17.0.0` → `17.0.7`. **i18next.md** `^26.0.6` → `26.3.1`. **knip.md** `^6.11.0` → `6.17.1`. **Ky.md** `^2.0.1` → `2.0.2`. **MSW.md** `^2.13.4` → `2.14.6`. **React Router 7.md** `^7.14.1` → `7.18.0`. **Vitest.md** `^4.1.4` → `4.1.9`. **remix-i18next.md** companions → `i18next 26.3.1`, `react-i18next 17.0.8`.

### Stale — content
- **Husky.md** — `.lintstagedrc.json` runs only eslint/prettier/stylelint; typecheck + `vitest --run --changed --passWithNoTests --bail 1` are pre-commit-hook steps (`pnpm test:lint-staged`), not lint-staged. Update the key-insight.
- **i18next.md / remix-i18next.md** — No `package.json` `pnpm.overrides`; overrides live in `pnpm-workspace.yaml` (only `qs`); no `remix-i18next>i18next` override. Alignment comes from single direct deps consumed as peers.
- **Chromatic Opt-Out.md** — `@chromatic-com/storybook` is not a dependency; opt-out should name only `chromatic`.
- **gaia-lint.md** — Override example accesses `gaiaLint.base` etc. on the default export; it's a factory — call `const lint = gaiaLint();` first. Custom plugins list omits `no-jsx-iife`. Package is no longer ESLint-only (ships `/prettier`, `/stylelint` subpaths).
- **spec-kit.md** — Bare-command install is destructive (`extension add --dev` consumes its source dir); real install pins via `uvx --from ...@v0.8.5` and stages a throwaway copy. Extension declares seven commands / five hook-target commands (not "three hook-target"). Hooks not limited to three events (+ before_implement/after_implement).
- **Storybook.md** — `eslint-plugin-storybook` is transitive via `@gaia-react/lint`, not a direct companion. **Tailwind.md** — `prettier-plugin-tailwindcss`, `eslint-plugin-better-tailwindcss`, `stylelint-config-tailwindcss` are not installed. **Vitest.md** — `@vitest/eslint-plugin` is transitive. **Playwright.md** — `eslint-plugin-playwright` is transitive.
- **React Testing Library.md** — `test/rtl.tsx` does not render with an i18n provider; it re-exports plain `render` and does a side-effect i18next init via `.storybook/i18next`.
- **Ky.md** — Path-param interpolation is `:token` string replacement (`setPathParams`), not `query-string`; only search-params use query-string.

### Stale — pnpm/Docker
- **pnpm.md** — "Every Docker stage needs all three files" contradicts the Dockerfile (prod-deps + runtime stages copy only `package.json`+`pnpm-lock.yaml`). Reconcile.

### Missing
- **gaia-lint.md** — No `version:` frontmatter (pinned `1.5.1`); Prettier/Stylelint subpath exports; factory `sourceDir` option (default `'app'`).
- **MSW.md** — Two entry points (`test/worker.ts` browser, `test/msw.server.ts` Node), `ping` handler prepended in worker.
- **Chromatic.md** — CI paths-filter + `chore(deps):` skip (not every push); full `pnpm chromatic` flag set (`--skip`, `--exit-once-uploaded`, `--storybook-build-dir`).
- **Vitest.md** — Setup file/env config (`setupFiles`, `happy-dom`, coverage exclude, `test/setup.ts` env fallbacks).
- **remix-i18next.md** — Client wiring is separate (`i18next-browser-languagedetector` in `entry.client.tsx`).
- **Husky.md** — Pre-commit gates on changed paths (`app/`/`test/`/`.storybook/`), guards duplicate react-doctor config; `pnpm prepare` also installs Playwright browsers.
- **knip.md** — Entry-glob list omits `app/languages/index.ts`, `app/middleware/**`, `.playwright/**`, `.storybook/**`, `test/**`.
- **spec-kit.md** — Implement-stage hooks + version-pin drift caching/failure behavior.
- **Tailwind.md** — Class sorting/CSS lint come from prettier + stylelint, not tailwind-specific plugins.

---

## Components (high-sev count: 4)

### Stale
- **Form Choices.md** — `required` error-gating: `Checkbox` forwards `required` unconditionally; only `InputRadio` (and `Checkboxes` per-option) gate on error. Callout names the wrong component. `BaseRadioButtons` keys by `option.value`, not `md5(option)` (md5 unused in Form).
- **Form Field.md** — `FieldStatus` has no `role`; error announces live via `FieldError`'s `role="alert"`. Description changes are not in a live region.
- **Form Layout.md** — `FormError` resurfaces on new action-data object identity, not on a new error string.
- **Form Text Inputs.md** — InputText/TextArea reimport `InputProps`/`SharedInputProps` from `~/components/Form/types` (not raw `ComponentProps` directly); `Select` extends `ComponentProps<'select'>` directly. `aria-label` cascade: a labelled field sets `aria-label={undefined}` and relies on the visible `<label>` (the "string label" rung is wrong).

### Missing
- **Form Field.md** — Field root `<div role="presentation">` (deliberate a11y); `hideMaxLength` prop suppresses the counter without dropping `maxLength`.

---

## Flows (high-sev count: 2)

### Stale
- **Theme Flow.md** — Steps 5/6: `useSystemTheme`, `useOptionalTheme`, `useOptimisticThemeMode`, and `ThemeSwitch` are NOT exported from `theme-switch.tsx` (route exports only `ThemeFormSchema` + `action`); hooks live in `app/hooks/useTheme.ts`, component in `app/components/ThemeSwitch/`. No-JS path: switcher Form posts only `theme` (no `redirectTo`), so the action returns `data()` — the `redirect()` branch is dead for the shipped switcher.
- **Language Flow.md** — Detection order is searchParams → cookie → session → header (remix-i18next default; `?lng=` overrides the cookie), not cookie-first. Step 4: action returns a `replace()` redirect with Set-Cookie, it does not "revalidate".
- **Form Submit Flow.md** — `notify[toast.type](toast)` is called by `App` in `root.tsx` (useEffect), not inside `<Toast />` (which renders only the Sonner `<Toaster>`).

### Missing
- **Form Submit Flow.md** — `parseWithZod` must import from `@conform-to/zod/v4` (root selects Zod-v3 behavior); no shipped route action implements this flow (live examples are Storybook stories). Link `[[Conform]]`.
- **Theme Flow.md** — `'system'` is a cookie deletion (`maxAge: -1`); explicit theme uses 1-year maxAge.
- **Language Flow.md** — Client i18next bootstrap in `entry.client.tsx` (reads `<html lang>`); cookie is named `lng`, httpOnly, 1-year, sameSite lax, `secure` only in production.

---

## Root (high-sev count: 3)

### Stale
- **overview.md** — `actions+` does not hold `set-theme` (only `set-language`); theme action is in `resources+`. Tech Stack overstates Storybook addons (only links, i18n, dark-mode; no React Router/MSW addon). Knowledge Hygiene: broken-wikilink repair is `/gaia-wiki lint`, not `/gaia-audit`. Hooks tree omits `useDebounce`/`useTheme` (add ellipsis or the missing entries).

### Missing
- **GAIA.md (entities)** — Package name is `gaia` and version `1.6.1` (not `gaia-react`/`1.0.0`) — appears at "What it is" and "Naming convention". Scaffolding is `npx create-gaia@latest my-app`, not `create-react-router --template`; cloning/forking is unsupported.
- **GAIA Philosophy.md (concepts)** — "i18n in 2 languages" overstates the template, which ships English only; a second locale requires `/gaia-init` opt-in.

---

## Dropped as weak
- **ESLint Fixes.md** "Rules now live in" (partial) — evades the wiki-style banned-pattern grep; stylistic-only, not worth a line.
- **Code Review Audit CI.md** `show_full_output: false` phrasing (partial) — accurate to the action default; downstream conclusions hold.
- **Telemetry.md** intro "single binary" (partial) — adopter-facing framing is defensible; covered by the maintainer/adopter missing-info note instead.

