# Changelog

All notable changes to GAIA React are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

- **Major**: breaking changes to skill/command API, Node/React/React Router major bumps.
- **Minor**: new skills, commands, or wiki concept pages; opt-in features, removed or renamed `.claude/` paths.
- **Patch**: bugfixes, docs, and in-range dependency bumps.

## Adopter-action convention

A release change that requires the adopter to act, run a command or hand-migrate, is authored as a `### Removed` or `### Changed` entry carrying an explicit **Action required:** line and/or a literal command to run (for example, `pnpm remove <pkg>`). That exact phrasing is the deterministic anchor GAIA's two CHANGELOG consumers key on: `/update-gaia` cross-references it during a merge to surface a documented, opt-in cleanup suggestion (it never auto-removes a dependency or deletes a file, the adopter decides), and the maintainer-only `release-notes` skill keys on it to tell an agent-automated cleanup (reframe as a benefit or drop) from a human-must-act migration (keep, plainly framed, with a pointer to the steps). Keep the marker and command literal so both consumers match the anchor instead of free-parsing prose. The `react-router-dom` removal below is the worked example.

## [Unreleased]

### Added

- `gaia.updateDepsHold`, a committed per-package version hold for `/update-deps`: a `{ package: ceiling }` map in `package.json`, read during discovery, that caps a held package to its ceiling line (a version prefix, `"8.0"` holds the highest `8.0.x`, `"8.0.16"` freezes exactly) and drops it (`reason: "held"`) when nothing on that line beats the installed version. Unlike the local snooze ledger (version-specific, 14-day, CI-ignored), the hold is committed, so it holds in interactive AND CI runs until the maintainer lifts it, and it fails closed when the ceiling matches no published version (held at current, never bumped above the ceiling). Generalizes the hardcoded ESLint-9.x cap and reuses the same memoized `pnpm view <name> versions` fetch; the `/update-deps` preview surfaces active holds on an informational line so they stay visible (#500)
- output-verification hardening for three GAIA self-audit workflows, so a single-pass judgment can no longer drive an edit or a clean verdict before something checks it. `/gaia-audit` gains a recommended-but-optional **classification-verification round** that runs in the main conversation between Stage 1 and the Apply / Discuss / Decline decision gate: three low-overlap `general-purpose` lenses (classification grounding, conflict adjudication, and edit safety) verify Stage 1's DUPLICATE / STALE / CONFLICT / PROMOTE / shrink classifications against the actual stores, wiki, and repo before they drive edits, biased toward DROPPING a flagged memory delete it cannot confirm because those deletes are irreversible (machine-local, no git undo, so a wrongly-kept entry is cheap clutter while a wrongly-executed delete is permanent), with CONFLICT-only deep re-adjudication and an `audit_hardened` frontmatter stamp the gate and `--apply` inherit; it is skipped on a clean 0-action report and never blocks. `/health-audit` (maintainer-only) gains a false-clean CHALLENGER pass the Orchestrator spawns at the clean-exit boundary, after a clean `findings.json` but before the `c*/` artifact deletion and the A+ report: parallel `general-purpose` lenses (blind-spot, misclassification, grade-honesty, and an optional deep fix-verification) attack the terminal clean verdict, and a substantiated finding revokes the clean exit by injecting an `action: real-fix` finding into `findings.json` and continuing the existing Fixer → next-cycle machinery, or, when the challenged clean cycle is cycle 3, escalates with the new reason `false-clean-refuted` and preserves all `c*/` dirs; it runs at most once per run, has no interactive gate, and never blocks. `/gaia-fitness`'s final verify cycle, the one whose recomputed grade it reports, now re-runs all seven fitness categories rather than only the categories that had a finding addressed, so a heal in one lane that regresses a check in a zero-finding category (a `claude-surface` edit pushing `CLAUDE.md` past its size budget, a `settings` edit breaking `settings.json`) is caught before the loop reports A+ instead of escaping. The gaia-audit round is mirrored into `wiki/concepts/GAIA Audit.md` and the fitness widening into `wiki/decisions/Claude Integration Fitness.md` (#472)
- a SessionStart janitor (`.claude/hooks/local-janitor.sh`, invoked from `wiki-session-start.sh`) that garbage-collects dead working-state residue under the gitignored `.gaia/local/` on every `startup`/`resume`. It is the side-effect form of a SessionStart hook (it deletes files and injects nothing into context) and a backstop, not an owner, so each subsystem still self-prunes its own residue; the janitor removes only residue whose death is provable: orphaned `audit/<sha>.ok` and `<sha>.dispositions.json` merge-gate markers (a `<sha>` that is neither HEAD nor reachable from a local branch, i.e. a squash-merge orphan), completed-but-unswept `plans/<slug>/` dirs (a `RUNNING` sentinel naming a branch that no longer exists and is not marked `DEFERRED`/`PAUSED`/`PARKED`), and stray empty dirs (via `rmdir`, which cannot touch a non-empty dir, excluding the structural drop zones tooling expects). Fail-safe end to end: any death it cannot prove is skipped and the hook always exits 0 so it can never block a session from starting. Adds the `Local Working State` wiki concept page documenting the `.gaia/local/` layout and per-path retention (#468)
- a forced-disposition gate on out-of-scope `code-review-audit` findings: debt the audit opens within its review radius but the PR did not change no longer routes through the gating Critical/Important/Suggestions sections, it gets a disposition of its own before the marker clears. Non-security out-of-scope findings file as deduped, severity-labeled `tech-debt` GitHub issues carrying a frozen versioned dedup key (`<!-- gaia-debt-key: v1 class=… path=… line=… -->`), a self-contained body passed via `--body-file` (never a `--body` argv that CI's `--verbose` would echo into the public Actions log), and a `Handler: prompt|plan` advisory class; filing is idempotent (exact-local key dedup, re-checked immediately before create) and the `tech-debt`/`severity:*`/`wontfix` labels are created on first use. Security-class findings are fail-safe classified (any Critical, any classless, secret-shaped, or from the security review dimension) and divert off every public or enterprise-readable channel: a redacted operator surface locally and a count-only PR signal in CI on PUBLIC/INTERNAL repos, filing as a private issue only on a confirmed PRIVATE repo. The disposition gate is the audit's fourth marker precondition (the existing three are re-scoped to in-scope findings), verified by re-querying open issues before the marker writes, and backed deterministically at merge time by a new `audit-disposition-check.sh` PreToolUse hook that denies `gh pr merge` only on a present-backend inconsistency and fails open otherwise (the system fails open end to end: a definitively-absent backend makes the feature inert, a transient failure never drops a finding or blocks the merge). Adds the `/gaia-debt` drain skill (one `tech-debt` issue per invocation, deterministic severity-then-age ordering with no LLM evaluator, a fresh branch through the normal audit gate with `Closes #N`, and a drain-time security re-screen), a `Run /gaia-debt (N issues)` statusline indicator fed by an independent debt-count refresher and a staleness sentinel set on the two first-party events (the audit filing an issue; a `/gaia-debt` PR merging via a `debt-sentinel-touch.sh` PostToolUse hook), and a `OUT_OF_SCOPE_FALLBACK_FINDING_CLASS` (`holistic/unclassified`) dedup-key fallback in `.gaia/cli/src/schemas/finding-class.ts` (kept out of the closed telemetry vocabulary, so the bundled `gaia` binary needs no rebuild). The CI workflow grants the audit job `issues: write` and adds `Bash(gh:*)` to its `--allowedTools` so the same filing path runs from CI. Adds the `Audit Disposition and Debt Drain` wiki concept page. Deferred for v1: line-drift-tolerant dedup, a CI security-advisory credential mechanism, durable drain for diverted PUBLIC/INTERNAL security findings, and cross-band drain fairness (#465)
- a maintainer-only CHANGELOG gate in the PR merge workflow: before any `gh pr merge`, evaluate whether the change warrants a `## [Unreleased]` entry and, if so, land it on the PR branch before merging, re-checked on every merge (including PRs resumed across sessions) so an entry promised at authoring time can't be lost. Lives in the `PR Merge Workflow` wiki page and the always-loaded `pr-merge` rule, both wrapped in maintainer-only scrub markers so they never reach adopter bundles (#446)
- `/gaia-react-perf`, a measure-only React render-performance diagnostic: it drives a micro-interaction, captures per-render attribution through a committed bippy Playwright harness injected before React initializes, then reduces the raw dump deterministically via a new `gaia react-perf reduce` CLI command (framework-noise filtered, ranked by blast-radius x cost, gated on a 16ms frame budget) so the raw capture never enters model context, and presents a ranked `memoDefeated` diagnosis with a react-doctor cross-reference and a structural-first fix before re-capturing to confirm the targeted finding count drops to zero. v1 is measure-only (no autonomous fixing); the human applies the fix in conversation. Adds the React Perf Diagnostic wiki concept page, and registers the skill, runbook, capture helper, and concept page in `.gaia/manifest.json` so `/update-gaia` ships them (the bippy version-bump smoke canary and CLI maintainer source stay release-excluded) (#442, #443)
- a React 19 idiom gate in the `react-code` skill (Gate 4): ref-as-prop over `forwardRef`, boolean-guarded `&&` over the numeric-0 leak, `use()` and the `<Context>` shorthand over `useContext`/`Context.Provider`, never `null` in render, and staying in React Router's lane for forms; `references/hook-patterns.md` gains `useEffectEvent` and ref-callback cleanup, and the `typescript` skill prefers `!!` over `Boolean()` for inline coercion (#441)
- a `remix-utils` awareness map (`wiki/dependencies/remix-utils.md`): a curated, risk-sorted decision map (hydration-safe client render, SSE, CSRF, honeypot, safe-redirect, debounced fetcher) reachable from the two surfaces Claude already loads before hand-rolling a primitive, the `react-code` skill's platform-first ladder and the `react-router-docs` rule (now also scoped to `app/middleware/**`); it cites `node_modules/remix-utils/README.md` by section as the source of truth and copies no API prose. `MetaHydrated` now derives its hydration signal from remix-utils' `useHydrated()` (the `hydrated` meta tag stays byte-identical), so `remix-utils` is a genuine import and drops out of knip's `ignoreDependencies` (SPEC-007) (#427)
- a canonical-status guard on the SPEC ledger: `ledger-update.sh` (the single ledger-write chokepoint) rejects any `.gaia/specs.json` row whose `status` is off the canonical vocabulary (`draft → specified → merged`, plus terminal `archived` and tolerated-legacy `in-progress`) with `exit 6`, and `spec-reconcile.sh` (the housekeeping pass on every `/gaia-spec`) normalizes known-misnamed statuses through the guarded chokepoint while logging an unrecognized status rather than guessing its lifecycle position. Both surfaces ship, so the protection reaches adopters authoring their own SPECs; the `GAIA Spec` wiki page documents the vocabulary as the source of truth (#425)
- `/gaia-spec` auto-archives merged SPECs through a fail-open `lib/spec-archive-merged.sh` sweep that runs after `spec-reconcile.sh` on every run: any SPEC folder whose ledger row reads `merged`, that still sits in the active specs dir, and that has no pending wiki-promote drain cache moves into `.gaia/local/specs/archived/`, with `status: archived` + `archived_at` stamped onto the artifact frontmatter (the ledger row stays `merged`; disposition lives on the artifact). This is the safety net for a PR merged out-of-band (the GitHub button, another session) or a `Keep in place` disposition that left the folder active, so the active specs dir no longer accumulates landed SPECs. Silent-but-logged and reversible: it prints one `Archived N merged SPEC(s): …` line, emits a `spec_closed` telemetry event per folder moved, never overwrites an existing `archived/` folder, and is undone by moving the folder back out (#426)
- an adversarial multi-agent SPEC-audit in `/gaia-spec`, offered once before the final gate (recommended by default, opt-in via an in-flow prompt and never blocking save): low-overlap lenses verify the draft's checkable claims against the repo and `node_modules` rather than on faith, a refutation pass keeps severity honest, and each surviving finding becomes either a plan-time directive (recorded in a sibling `AUDIT.md` the planner reads) or a contract fix folded into the draft pre-save with no reopen ceremony. Two rigor tiers (Standard, Deep) plus content-gauged specialist lenses; runs as a parallel `general-purpose` Agent fan-out so it works in headless and auto-mode contexts (#423)
- a lightweight adversarial decomposition audit in `/gaia-plan`, offered once after the plan is generated (recommended for a non-trivial plan, opt-in via an in-flow prompt and never blocking the handoff): three parallel lenses verify the *decomposition itself*, the one artifact neither the upstream SPEC-audit nor the downstream pre-merge `code-review-audit` can see. Decomposition and dependency soundness attacks the task graph (same-phase tasks that actually share state, phase order that ignores a real dependency, a shared contract two tasks read inconsistently); contract grounding checks every file, export, type, and signature named in a task contract resolves against the real repo and `node_modules`; and SPEC coverage (only when the plan derives from a SPEC) builds the success-criteria-and-UAT-to-task matrix. Deliberately narrower than the SPEC-audit, no refutation pass since the findings are checkable rather than severity-debatable; localized findings fold into the task docs, a structural finding re-spawns the planner. Runs as a parallel `general-purpose` Agent fan-out so it works in headless and auto-mode contexts (#424)
- an adopter-action CHANGELOG convention (a `### Removed` / `### Changed` entry carrying an **Action required:** line and/or a literal `pnpm` command) that `/update-gaia` reads to surface documented, opt-in cleanups during a merge (when GAIA drops a dependency you still have, it suggests the exact `pnpm remove` command instead of leaving a silent no-op, never acting on your behalf), and that the maintainer-only `release-notes` skill keys on to reframe or drop agent-automated cleanups while keeping genuine migrations. `/update-gaia`'s confirm gate now shows the full baseline-to-latest CHANGELOG range, so an adopter several versions behind sees every intervening entry, not just the latest tag's notes
- `react-code` skill leads with a platform-first ladder (existing GAIA code → web platform like `Intl`/`URL`/`crypto.randomUUID` → already-installed dep → new dep → custom code) to walk before adding a dependency or hand-rolling a primitive
- `/gaia-harden` weighs an efficacy lens (Axis 3) before recommending a form: a recurring finding proves the problem, not the fix, so when the recommended form is prose and no cheap before/after evidence shows it would change behavior, that surfaces as a defer/decline signal for the human, never an auto-decline
- point Zod schema work at Zod's official LLM docs, auto-discovered from `node_modules/zod/package.json` (`llmsFull`/`llms`), and treat them as authoritative over training memory so valid Zod 4 forms are not rejected from stale v3 recollection
- a TDD testing-strategy foundation (SPEC-006): an AST determinism classifier scopes the hard RED commit gate to deterministic tests, so affirmatively-emergent test files are no longer forced to show a natural RED (fail-open preserved); a second `gh pr merge` gate proves the worthiness extractor ran over changed emergent tests; an advisory two-axis (honesty and worthiness) audit via the `worthiness-evaluator` agent surfaces keep/fix/delete proposals with every delete human-gated; and `new-component` scaffolds a non-degenerate a11y test (representative `--props` threaded through the render site) that can actually fail. Adds the Determinism Classifier, Worthiness Audit, and Worthiness Presence Gate wiki pages (#408)
- per-author `code-review-audit` mode (local vs CI): the pre-merge audit gate keys on a `GAIA-Audit` commit status resolved per PR author, so a developer in local mode runs the audit on their machine while CI stands down, the branch stays protected, and the gate fails closed to CI whenever a local run cannot confirm `GAIA-Audit` is a registered required check. `gaia-init`, `setup-gaia-ci`, and `setup-cloned-gaia-project` gain audit-mode prompts, and `/update-gaia` field-merges `.gaia/audit-ci.yml` so a committed `audit_authors` entry never forces a whole-file conflict (#407)
- restore the wiki hot cache after a context compaction through two GAIA-owned hooks (a `PostCompact` sentinel writer plus a `UserPromptSubmit` re-injector), so the "where we left off" cache survives compaction without depending on claude-obsidian's prompt-type `PostCompact` hook that some Claude Code builds reject (#386)

### Changed

- `/gaia-init` auto-detects the user's GitHub handle for `.github/CODEOWNERS` via `gh api user` (a single call that both verifies auth and returns the login) instead of always writing the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder. On success it writes `* @<handle>` and emits no follow-up warning; on failure (gh absent, unauthenticated, or empty) it keeps the placeholder and the required-follow-up warning exactly as before. Interactive mode offers the detected handle as the recommended, overridable default and HARD-BLOCKs only when detection fails; automatic mode uses the detected handle when available, placeholder otherwise. A gh-detected handle is the user's own authenticated identity rather than a guess, so the "never fabricate identity values" policy is updated to carve it out; there is no `git config` or remote-URL fallback (#507)
- `/gaia-fitness` (and `/health-audit`'s shared fitness bucket) now dispatch each Sonnet judgment-auditor with an explicit coverage directive in its prompt (surface every candidate including uncertain or low-severity ones; do not self-filter for importance or confidence, the Orchestrator's adjudication stage is the filter), so recall no longer rides on the auditor's own bar. The recall-orientation the harness depends on was stated only in orchestrator-facing prose; folding it into the dispatched prompt keeps a literal instruction-follower from under-reporting the borderline frontmatter / rule-hygiene / `CLAUDE.md` judgment calls the adjudication stage exists to sift. Documented in `wiki/decisions/Claude Integration Fitness.md` Triage phase (#486)
- lean the `/gaia-spec` main thread through the adversarial-audit and fold phases (SPEC-011): audit finding bodies, verdicts, and refuter prompts now live in a per-spec **audit cache** on disk (`.gaia/local/cache/audit-<spec_id>/`, holding `findings/<lens>.json`, `findings/self-review.json`, `findings/completeness.json`, and `verdicts/<finding-id>.json`), and the fold's read-compose-Write moves into a **delegated applier subagent** that reads the full on-disk record, folds the surviving fixes in a single Write, and authors the sibling `AUDIT.md` itself. Main-thread context through the audit and fold phases now grows with the finding **count** in thin lines (id, severity, title, verdict, disposition) plus a few applier summaries, not the body size of every finding, verdict, refuter prompt, and draft per fold; only two bounded interactive carve-outs reach main (high-severity self-review findings at gate 6b, material spec-defect survivors at gate 7c) and auto-mode reads no finding body. The audit's lens set, refuter counts, tier gauge, and dispositions are preserved exactly; only where bodies live and how they flow back changes. The `after_clarify` self-review hook (`self-review.md`) now writes its findings to the cache and self-applies its low- and medium-severity fixes instead of deferring every fix to the wrapper (#483)
- onboarding is now a single `/setup-gaia` command, replacing `/setup-gaia-ci` and `/setup-cloned-gaia-project`. It detects your situation (fresh clone, first adopter, partial run, or fully provisioned), runs only the phases still owed, provisions the GitHub repository (create / adopt / manual, private by default), and is safe for any teammate to re-run after cloning. **Action required:** run `/setup-gaia` instead of the two retired commands; `/update-gaia` surfaces the removal of the old command files with a per-file confirm prompt on your next update (#480)
- harden the release boundary around the debt-drain feature: maintainer-only path references (`.gaia/cli/src/…`) that had leaked into adopter-shipped surfaces (the `code-review-audit` agent, the `Audit Disposition and Debt Drain` wiki page, and the rendered workflow-template comments) are wrapped in `gaia:maintainer-only` scrub markers or rephrased so they never reach an adopter bundle, and the bundle-time scrub's `maintainer-paths` scope now covers `.gaia/cli/templates/**` so a future template comment citing a maintainer path fails the release leak-check instead of shipping. The `release runtime-deps` walk extends to `.github/actions`, closing a coverage gap where the three shipped composite-action scripts under `.github/actions/gaia-ci-merge-and-watch/lib/` were never scanned for references resolving to release-excluded paths. All maintainer-only; nothing here changes adopter runtime behavior (#475)
- the `react-code` skill's numeric-0 `&&` guidance now frames operand coercion as mandatory rather than optional and names react-doctor's type-aware `rendering-conditional-render` rule as the pre-merge backstop for the general `count && <JSX/>` case (real-time lint catches only the `.length` form), so Claude coerces while authoring instead of deferring the fix
- adopt `@gaia-react/lint` 1.8.0 (from 1.7.0): the new `no-null-render` autofix rule rewrites a `return null` to `return undefined` inside render functions only (loaders, actions, and plain utils are never touched), so GAIA standardizes on `undefined` for the empty render, a consistency convention since `null` and `undefined` are identical to React's reconciler. The release also flags the most common numeric-0 leak, `.length && <JSX/>`, through a report-only `no-restricted-syntax` selector. The now-redundant "never `null`" render mandate is removed from the `react-code` skill, since the linter enforces it token-free. The 1.8.0 bump also refreshes the bundled toolchain (`eslint-plugin-sonarjs` 4.0.3 to 4.1.0, `typescript-eslint` 8.61.1 to 8.62.0); the newer SonarJS rules surface a few existing findings, resolved here (redundant optional-type annotations, more-specific test assertions, and a renamed `super-linear-regex` disable directive) (#461)

- the `prepare` lifecycle no longer provisions Playwright browsers: `prepare` is now `is-ci || husky`, and `pnpm exec playwright install --with-deps` moves to a dedicated `pnpm install:browsers` script. CI installs browsers in its own workflow step, so `pnpm install --frozen-lockfile` no longer triggers an `apt-get` that can fail behind a proxy or on a hardened runner. **Action required:** run `pnpm install:browsers` once to provision Playwright browsers locally if you run the e2e suite (`pnpm install` no longer does it for you) (#456)

- the fresh-scaffold visual baseline is now neutral and brand-free (SPEC-008): `--color-claude-*` terracotta scale removed; `--color-primary-*` replaces it with a zero-chroma (grayscale) 11-step scale so re-skinning is a few-value change. Google Fonts `@import` and the Inter `<link>` removed; `--font-sans`/`--font-mono` default to system stacks. All `blue-*` literals in Button, Toast info, form focus/checked rings, `::selection`, and link-hover collapsed to `primary-*` with per-theme dark-mode variants. `Layout` simplified to a single `<main>` wrapper (no `Header` or `Footer`); the index renders only the site-name `<h1>`, `ThemeSwitch`, and `LanguageSelect`. A path-scoped `.claude/rules/design-baseline.md` guard and a `wiki/concepts/Design System.md` declaring stub (sentinel `established: false`) prevent Claude from reading the neutral baseline as a chosen design system; one always-loaded `CLAUDE.md` pointer covers the pre-edit case. Dark mode, i18n, and WCAG-AA text and non-text contrast stay green across every route group; the Vitest, Storybook, Playwright, and distribution suites are extended for dark-mode contrast, landmark/heading best-practice, and legal-page bare render. `gaia init strip-branding` drops its now-moot GaiaLogo/Header/brandImage steps while keeping README, FUNDING, and Storybook `brandTitle` personalization. **Adopters who customized owned files** (`Header`, `Footer`, `GaiaLogo`, or the bundle) will see a migration impact in `/update-gaia`; those files are removed upstream (#455)

- bump the maintainer CLI's `tsx` devDependency (`.gaia/cli`) 4.21.0 → 4.22.4 to clear its transitive `esbuild` off the `GHSA-g7r4-m6w7-qqqr` floor (dev-server arbitrary file read on Windows; low severity, dev-only). `.gaia/cli` already pins `esbuild@0.28.1` directly, but `tsx@4.21.0` pulled a transitive `esbuild@0.27.7` (vulnerable range `>=0.27.3 <0.28.1`); tsx 4.22 widens its esbuild range to `~0.28.0`, so the `0.27.7` copy drops out and `.gaia/cli/pnpm-lock.yaml` resolves a single `esbuild@0.28.1` (`vite`/`vitest` already used it). `.gaia/cli` is a separate pnpm workspace `/update-deps` doesn't reach (root-scope only), so this is hand-applied. Resolves Dependabot alert #116 (#453)
- routine dependency refresh: `@types/node` 25.9.3 → 26.0.0 (its major tracks the Node 26 type line; runtime stays pinned to Node 22.23.1 and the types are a superset, so no code changes), plus `@faker-js/faker` 10.5.0, `chromatic` 17.5.0, `happy-dom` 20.10.6, and `nanoid` 5.1.14. Prunes the now-obsolete `qs` security-floor override (`'qs': '>=6.15.2'`): `express` resolves `qs@6.15.2` on its own, so the pin is redundant and `pnpm audit` stays clean without it (#452)
- upgrade React Router 7.18.0 → 8.0.1 across the family (`react-router`, `@react-router/{node,serve,dev,fs-routes,remix-routes-option-adapter}`), a low-risk "boring major": GAIA already adopted all five v8 future flags on v7 and imports everything from `react-router`, so router runtime behavior is unchanged at cutover and the now-invalid `future` block in `react-router.config.ts` is deleted (middleware, route-module splitting, and the Vite Environment API are built-in defaults in v8). Also bumps `remix-utils` 9.3.1 → 10.0.0 and `remix-i18next` 7.5.0 → 8.0.0, which peers `react-router` ^8 natively (no pnpm override needed); v8 collapsed remix-i18next's subpath exports, so the middleware and client imports repoint to the bare `remix-i18next` and `entry.client.tsx` derives its hydration namespaces from the bundled resources (`getInitialNamespaces` is dropped in v8). The nested `vite` 7.x toolchain copy disappears because `@react-router/dev@8` drops its `vite-node` dependency and widens its vite peer to ^7||^8, so the dev toolchain uses the app's own vite 8.x and dev-only audit advisory 1120790 has nothing left to flag (closes #398). **Action required:** raise your local Node to >=22.22.0 (the v8 engine floor; `.nvmrc`/`.node-version` pin 22.23.1 on the 22.x LTS line) (#450)
- catch the README up for the next release: add `/gaia-react-perf` and `/gaia-harden` to the commands table, add `a11y-fixes` to the bundled-skills lists, and refresh the lint-rule count to 1,450 (the `eslint --print-config` resolved total after the lint 1.7.0 bump) (#449)
- replace the handoff archive lifecycle with delete-on-done. `/gaia-handoff` enforces a single-handoff invariant (it deletes any existing handoff before writing, so only one ever exists and a new one supersedes the old, carrying forward anything unfinished), and every handoff carries a self-Teardown instruction that deletes the file once its Next Actions are verified complete. `/gaia-pickup` no longer moves a consumed handoff into an `archive/` directory; it resolves in place (self-delete on the happy path, delete a stale handoff whose work has fully landed and resume from `wiki/hot.md`, or leave outstanding work untouched so an interruption stays recoverable) and runs a defensive sweep that keeps only the newest when more than one handoff exists. Deletion is the only terminal state; nothing is archived. **Action required:** remove any orphaned archive directory left by the prior workflow with `rm -rf .gaia/local/handoff/archive` (gitignored local scratch, safe to delete) (#448)
- adopt `@gaia-react/lint` 1.7.0 (from 1.6.0) to enforce the never-`null`-in-render idiom: new `gaia/no-restricted-syntax` selectors flag `cond ? <JSX/> : null` and `cond ? null : <JSX/>` and point to the boolean-guarded `&&` form (flag-only, no autofix). Extends never-null beyond render to GAIA-controlled types and state, the theme chain (`getTheme`, `RequestInfo.userPrefs.theme`, `ThemeSwitch.userPreference`, the `Document` guard) and `useComponentRect`'s timeout ref move from `null` to `undefined`; structural `null` is left intact (DOM refs, ref-callback params, `data(null)`, `Response.json(null)`, Zod `.nullable()`) (#441)
- adopt `@gaia-react/lint` 1.6.0 (from 1.5.1), reconciling the lint deltas it surfaces across the repo for the first time: the `resources+`/`actions+` `no-restricted-paths` UI-layer carve-out (retires the inline disable in `ThemeSwitch`), the D-8 test-honesty rules (`vitest/prefer-called-with`, plus `no-restricted-imports` on `*.server` / `**/internals/**` from consumer tests), and the unicorn 65 batch (#433)
- split the spec-session lifecycle from the SPEC artifact's status: `.gaia/specs.json` tracks the authoring session (`draft → specified → merged → archived`) while `SPEC.md` frontmatter keeps its own (`in-progress | reopened | closed`). `/gaia-spec` resume only offers a still-`draft` session, so a finalized SPEC is never re-surfaced as resumable, and a fail-open, idempotent `spec-reconcile.sh` derives the `merged` transition from a merged `spec-NNN-*` PR on git ground truth (#423)
- route GAIA workflow-misfire reports (hooks, skills, commands, quality gate, scaffold failures) through `/gaia-forensics` before filing by hand, and document an issue-claiming policy in `CONTRIBUTING.md`: only issues labeled `help wanted` are open for outside PRs, and contributors comment to be assigned before starting (#404)
- routine dependency refresh across two waves: `react-router` group to 7.18.0, the `storybook` group to 10.4.6, `@playwright/test` to 1.61.0, `tailwindcss` to 4.3.1, `vitest` to 4.1.9, plus further minor/patch bumps; transitive `undici` and the nested `vite` 7.x copy reached their patched security floors through the bumps, so their interim overrides were pruned (#387, #413, #415)

### Removed

- the orphaned `setup-ci set-secret` CLI verb, superseded by #478's out-of-band token provisioning: with `/setup-gaia-ci` Step 7 no longer shelling out to it, the verb was dead-but-advertised surface (listed in `--help` and the top-level verb list with no caller) and a latent paste-reintroduction vector, invoking it required an agent to hold the CI bot token on stdin, the exact exposure #478 eliminated. Deleted outright (handler, tests, dispatch, and help entries); the shared `gh` wrapper stays since `check-admin` / `enable-delete-branch` / `verify-run` still use it, and the `gaia` bundle is rebuilt (the `gaia-maintainer` bundle omits the `setup-ci` router, so it is byte-identical). Maintainer CLI surface, so release-excluded (#479)

- `app/components/Header/`, `app/components/Footer/`, `app/components/GaiaLogo/`, and `app/assets/images/gaia-logo.svg` from the template: these GAIA-branded surfaces are owned by the manifest and removed from the scaffold directly rather than shipped and stripped at init. Adopters who customized any of these owned files will be offered a migration note by `/update-gaia`; the change is intentional and the neutral index + Layout ship in their place (#455)

- the vestigial `react-router-dom` dependency, a v6/v7 re-export shim that React Router 8 drops entirely; GAIA runs framework mode and imports everything from `react-router` (`HydratedRouter` comes from `react-router/dom`), so it was already dead weight on v7. `/update-gaia` leaves an existing `react-router-dom` in your `package.json` by design (adopter-owned dependencies are never auto-removed); `pnpm knip` also flags it as unused after this release (#419)
  - **Action required:** run `pnpm remove react-router-dom` to drop it

- the `/gaia-spec` GitHub-issue mirror and the inline `/gaia-plan` chain (SPEC-012). The mirror is gone end to end: the step-1 opt-in question, the auto-mode force-on rule, the step-2 resume re-ask, the mirror step, the PR-body-closure step, and the `gh_issue_url` frontmatter stamping, along with the `.specify/extensions/gaia/lib/gh-mirror.sh` script, its `.gaia/manifest.json` entry, and the `spec-renumber.sh` re-title hint. The chain is replaced by a handoff: in both interactive and auto mode, after the canonical save `/gaia-spec` prints a copy-pasteable `/gaia-plan` handoff prompt (naming the repo-absolute `SPEC.md` path, and the sibling `AUDIT.md` path when the adversarial audit ran) and stops, so the human runs `/gaia-plan` in a fresh session with a clean context budget; the retired `plan_dispatched` telemetry event is not replaced. Every other `/gaia-spec` behavior is unchanged (two-gate ceremony, clarify loop, self-review, adversarial audit + `AUDIT.md`, canonical save, ledger finalize, immutability lint) (#484)

### Fixed

- wiki-sync landing branches are cleaned up after they merge instead of piling up as local orphans. The wiki landing CLI (`gaia wiki chain finish` / `wiki sync land`) lands a throwaway `wiki-sync/<date>-<sha>` branch with `gh pr merge --squash --auto`, which returns before the merge completes, so the local branch was never deleted inline and nothing reconciled it once the PR squash-merged (normal PR branches are deleted by the Claude-driven PR merge workflow; these had no equivalent). The `local-janitor.sh` SessionStart hook gains a git-scoped sweep, ordered ahead of its `.gaia/local` guard so a fresh clone with no `.gaia/local` yet is still swept, that hard-deletes any local `wiki-sync/*` branch whose upstream is `[gone]` (the provable-death signal left once GitHub deletes the merged remote head and a `git fetch --prune` drops the tracking ref); it never touches the current branch or one with a live upstream. Both landing paths add `--delete-branch` to the auto-merge so the remote head is removed even on repos without GitHub's auto-delete-head-branches setting, and `wiki sync land` returns to the base branch after landing (mirroring `chain finish`) so the janitor is not blocked by the branch being checked out. Adds a `local-janitor` bats suite and rebuilds the committed `gaia` / `gaia-maintainer` bundles (#506)
- `/gaia-init` no longer cascades a single AskUserQuestion timeout into unattended auto-defaulting of every remaining setup gate. One 60s non-response on the first gate previously led it to infer "the user is away" and answer all downstream identity/consequential gates (primary/additional language, project title, kebab slug, CODEOWNERS handle, CI intent, mentorship) from defaults, narrating "since you're away" while the user was present, and produced two concrete bugs in its improvised summary: a git-inferred CODEOWNERS handle (a wrong owner would ship in `.github/CODEOWNERS`) and a duplicated Mentorship row. A top-level non-response policy now overrides the harness away-from-keyboard note: each gate is evaluated independently (no carried-forward absence inference), gates split into a fixed HARD-BLOCK tier (run mode, pnpm consent, language, i18n teardown, CODEOWNERS, title, slug, CI intent) that re-asks rather than auto-answers and a SAFE-DEFAULT tier (Step 9 tool modes, mentorship) that re-asks once then applies the stated default without asserting absence, and free-text identity values are never fabricated (an unknown CODEOWNERS handle ships as a loud `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder surfaced as a required follow-up). The first gate now asks Interactive (recommended) vs Automatic; Automatic prints a corrected defaults table (one Mentorship row covering `mentorship.enabled` + `analytics.enabled`, CODEOWNERS shows the placeholder rather than a guessed handle) then applies defaults without stopping (#504)
- the `code-review-audit` CI workflow now stamps the durable `GAIA-Audit` commit status on a clean audit whose only tree delta is an off-limits self-heal surface (`.claude/**`, `.specify/**`, `wiki/**`, or a >10-file sprawl). The clean-no-push status step gated on push-fixes' `refused != 'true'`, so such a PR set `refused=true`, skipped all three success-stamp steps, and left `pr-merge-audit-check.sh` with no signal, blocking the merge despite a clean audit (recurring on every `.claude/**`-touching PR). The condition is dropped; the `.gaia/local/audit/<HEAD>.ok` marker check already in the step body stays the sole proven-clean guard, a dirty audit has no marker so nothing is stamped (no false pass), and `marker_only`/`pushed` are both false in the refused case so the sibling stamp step still skips (no double-stamp). The byte-identical template copies are synced (the `.gaia/cli/src/automation/templates/workflows/code-review-audit.yml.tmpl` source of truth plus its generated `.gaia/cli/templates/workflows/code-review-audit.yml.tmpl` build artifact) so the merge hook's self-mod bypass keeps proving blob identity. Also documents in the `/update-deps` SKILL that a `gaia.updateDepsHold` entry caps only the named package, so a peer-coupled companion-group sibling must be held explicitly (#501)
- `/update-deps` no longer re-offers an already-snoozed group as if it were fresh. The emitted payload gains a per-group `snoozed[]` (`group`, `targets`, `snoozed_at`, `resurfaces_at`) reusing the existing suppression logic, which the CLI previously computed only as the aggregate `actionable_count` and discarded before emit, leaving the preview blind to it. The preview now marks snoozed groups `[snoozed until DATE]` and default-skips them (with an explicit "update everything incl. snoozed" override), so a group snoozed at the exact offered version is no longer silently presented for update every run (#500)
- close the last `/health-audit` distribution-boundary gap (Class-9): the maintainer-only `workflow-denylist` leak-check in `.gaia/release-scrub.yml` is line-based regex and matched only the block-list inverted form (`- "!*.md"`) and the `paths-ignore:` key, so an inverted entry smuggled into an inline flow array (`paths: ["src/**", "!*.md"]`), which carries the same denylist fail-quiet semantics, slipped past. A quote-anchored third alternation (`\[[^\]]*['"]!`) now flags the inline flow-array form too, keeping block-list handling intact; the quote anchor prevents a stray `[!` in a run-step string from false-positiving, and it matches zero of the current workflows (all allowlist form). Regression tests cover the inline-array hit, the block-list/`paths-ignore` hit, and the pure-allowlist FP guard; the `taxonomy.md` accepted-limitation note is updated to reflect the closed gap. All maintainer-only (`.gaia/cli` is release-excluded); the check is config-driven so no CLI rebundle (#499)
- close a distribution-boundary leak and a manifest-tracking gap surfaced by `/health-audit`: two shipped skill reference docs (`.claude/skills/gaia/references/harden.md`, `forensics/redaction.md`) named maintainer-only source/test paths (`.gaia/cli/src/…`, `.gaia/tests/…`) that reached the adopter bundle, now wrapped in balanced `gaia:maintainer-only` scrub markers so the bundle-time scrub strips them; `.claude/rules/repo-relative-paths.md` shipped but was untracked in `.gaia/manifest.json` (so the boundary greps mis-triaged it as release-excluded), now regenerated into the manifest as `owned` and allowlisted in `.gaia/release-scrub.yml` for the sanctioned `/Users/…` placeholders and `.gaia/tests/forensics/` references it documents as policy (same rationale as the already-allowlisted `wiki-style.md`); the `taxonomy.md` Distribution-boundary runtime-deps class prose is corrected from an unbuilt "codification opportunity" to the present-tense shipped primitive wired into `release.yml`; and `wiki/decisions/Claude Integration Fitness.md` gains a "Decided / not findings" entry so a shared-reference skill bucket with no `SKILL.md` (`.claude/skills/gaia/`) is no longer re-flagged by the frontmatter check (#497)
- the statusline `Run /gaia-debt` nudge no longer lingers (up to the 6h TTL) after a `/gaia-debt` PR merges and empties the backlog. GitHub's issue-list index is eventually consistent: the merge sets the debt-count staleness sentinel, but a recompute fired on the very next statusline tick can still count the just-closed issue (observed: `gh issue list --state open` returned 1 several seconds past the issue's `closedAt`). The refresher cached that stale count and cleared the sentinel, so no further recompute ran until the TTL. `debt-count-refresh.sh` now holds a sentinel younger than a 120s settle grace armed after a recompute (it writes the fresh count but keeps the sentinel), so a later tick re-reads the now-consistent count before the sentinel clears; the sentinel mtime is read GNU-first (`stat -c %Y`, then BSD/macOS `stat -f %m`) with a numeric re-check between attempts, because GNU `stat -f %m` exits 0 printing `?` rather than failing, and it falls back to clear-on-recompute when the mtime is unreadable. TTL/missing-cache recomputes and the backend-absent zero-seed path are unchanged, and a bats suite covers the young-kept / aged-cleared / zero-seed-kept cases (#495, #496)
- the statusline `Run /gaia-harden` nudge no longer silently disappears during a `gh`/network outage: `.gaia/scripts/check-updates.sh` read only `candidate_count` from `harden-tally` and ignored the `gh_ok` boolean, so a failed window read (which exits 0 emitting `candidate_count 0` with `gh_ok false`) was treated as a genuine all-clear and reset the cached `hardenCandidateCount` to 0, dropping the nudge for the duration of the outage. The refresher now parses `gh_ok` and keeps the previous cached count whenever it is `false`, matching the `/gaia-harden` agent path that already honors the flag; the block comment is corrected to describe the real fallback behavior. Also points the `/gaia-harden` playbook's repo-relative-path guidance at the authoritative `.claude/rules/instruction-files.md` rather than `coding-guidelines.md`, which does not govern path portability (#494)
- make hardcoded machine-specific absolute paths repo-relative so a maintainer who forks `gaia-react/gaia` onto their own machine (and any adopter scaffolding from the template) is never pinned to the original author's checkout: the `.gaia/cli` storage-slug JSDoc example and its coupled unit-test input become the neutral placeholder `/Users/you/projects/my-app`, and the `.specify` v2-validation runbook derives `GAIA_ROOT` from `git rev-parse --show-toplevel` once (the `/tmp` subshells inherit the exported value) instead of embedding an absolute path. Codifies the standing repo-wide policy in a new `.claude/rules/repo-relative-paths.md`: a portable `git grep "$HOME"` audit plus two documented exceptions (the forensics redaction fixtures that use home paths as the subject under test, and generic placeholder examples), cross-referenced from the `.claude/`-scoped `instruction-files.md` and an always-loaded `CLAUDE.md` principle (#490)
- close 25 defects found in an adversarial audit of `/gaia-forensics` (the end-user bug-report skill and its maintainer-only triage CI). Adopter-facing: the redaction pass that runs before a report is filed to a PUBLIC upstream issue now catches secret and identity shapes it previously missed, fine-grained GitHub PATs (`github_pat_…`), JWTs, `Bearer` tokens, Slack app-level tokens (`xapp-…`), connection-string credentials (`scheme://user:pass@host` collapses to `scheme://<redacted>@host`), and bare `/Users/<name>` / `/home/<name>` / `/root` paths that leaked the OS username with no trailing path component; every new rule is mirrored into the shell test double and covered by a leak-then-clean fixture, and the nine numbered behavior suites are now actually executed (`pnpm test:forensics` runs the full `run-all.sh`, and a filter-gated CI step guards the forensics surfaces). The skill also verifies the `gaia-forensics` label attached after `gh issue create` and, when GitHub silently drops it for an author without triage access (so the label-gated autonomous triage would never fire), keeps the filed issue and prints a maintainer-remediation warning instead of reporting a false success. The report schema is unified to one canonical `## Capture` rendering across the skill, the capture fragment, and every golden/fixture (byte-asserted, not just header-checked), and the classification taxonomy is reconciled with its shell mirror. Maintainer-only and release-excluded: the triage workflow is hardened against prompt-injection (a per-run random sentinel wraps each untrusted issue section and backtick / verdict-marker breakout bytes are neutralized before substitution), no longer strands an issue as triaged-but-unhandled when the classifier produces no verdict (it routes to needs-human), gives the auto-fix step the `Read` tool it needs to edit existing files, labels `fix-abort` / empty-diff aborts accurately instead of as out-of-scope, makes the deterministic body parser fenced-code-aware and duplicate-header-safe, and rejects `..` path traversal plus an explicit `.github/` denylist; stale `SPEC-00N` attributions are dropped from the maintainer scripts and docs (#487)
- `/setup-gaia-ci` no longer asks you to paste the bot token into the chat: the old Step 7 had you paste the raw `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY` as a message and then inlined it into a shell command, so the secret landed in the conversation transcript (sent to the model API, persisted by the harness) despite a "never echoed, never logged" claim. Step 7 is rewritten to an out-of-band flow: you set the secret yourself via `gh secret set` or the GitHub web UI, and the command only verifies it exists by exact name via `gh secret list --json name`, never touching the value. Adds a repo-admin pre-gate, an in-place retry when the secret is absent, a `--reconfigure`-gated rotation path (an interim rewrite silently skipped rotation), and a safety rule that treats an accidentally-pasted token as compromised and mandates rotation (#478)
- `/gaia-plan` no longer fires a delete-permission prompt on every run: the post-planner verify step confirms the required artifacts exist and warns if planner scratch survived, instead of force-deleting `.work/`. The planner already removes its own `.work/` before returning and `.gaia/local/plans/` is gitignored, so the `rm -rf` backstop was redundant and only cost an interactive prompt each run (#460)
- restore the GAIA logo to the README: the SPEC-008 un-design (#455) deleted `app/assets/images/gaia-logo.svg`, leaving the README `<img>` pointing at a missing file. The logo (recovered from git history) now lives at `docs/assets/gaia-logo.svg`, outside `app/` so it never enters the app build, and `docs/assets` is release-excluded so the maintainer-only logo is never bundled into the `create-gaia` distributable (the root README that references it is already release-excluded) (#458)
- `LanguageSelect` renders nothing when only one language is configured: a single configured locale gives the switcher one option, so the neutral index page showed a pointless one-item dropdown. The post-hooks guard returns `undefined` when `LANGUAGES.length <= 1` and self-activates once a second locale is added via the add-locale runbook; the IndexPage test splits into two `test.runIf` cases keyed on `LANGUAGES.length` and the language-switch a11y E2E skips when the switcher is absent, so single-language and multi-locale projects both stay green. The `remove-i18n` runbook gains an explicit step (with a discovery grep) to drop the `LanguageSelect` import and element from IndexPage, closing a determinism gap where the strip left a dangling import (#457)
- the `/gaia-wiki lint` and `/gaia-wiki consolidate` playbooks `mkdir -p wiki/meta/` before their first report write: `wiki/meta/` is release-excluded, so a freshly scaffolded adopter clone has no such directory, and the first `/gaia-wiki lint` or `/gaia-wiki consolidate` failed with `No such file or directory` when the report write hit the missing path. No CLI primitive owns the report write (`state-init` creates `wiki/` but not `wiki/meta/`), so each reference file now ensures the directory first (#447)
- close the numeric-0 `&&` leak in shipped Form components and `ErrorStack`: `Checkbox`, `Field`, and `FieldLabel` boolean-coerce their `ReactNode` `&&` operands (`!!label`, `!!extra`, `!!(description ?? error)`) so a falsy operand can no longer render a literal `0`, and render returns move from `return null` to `return undefined` (`MetaHydrated`, `FormError`, `ErrorStack`) (#441)
- the React Router entry files no longer carry stale Remix v2 scaffolding header comments: `entry.client.tsx` and `entry.server.tsx` referenced `npx remix reveal` (not a command in a React Router v7 project) and linked to remix.run docs for a framework this app no longer is; React Router 7.18.0 scaffolds these files with no header comment, so removal also realigns with the current upstream default (the functional `eslint-disable` on `entry.server.tsx` is retained) (#444)
- `/gaia-init` stops claiming the CI workflows ship: `code-review-audit.yml` and `forensics-triage.yml` are release-excluded, so neither exists in the scrubbed tarball at init time. The Configure CI block no longer git-mv's absent workflow files on Skip, and on Yes no longer prints a premature token/secret/required-check recipe or creates a `gaia-forensics` label on the adopter's repo; it now records only the enable/decline intent (consumed at Step 9) and the local audit `default_mode` baseline. Adopter CI installs on demand via `/setup-gaia-ci` after first push (#439)
- correct the documented manual handle for closing a SPEC from `/gaia-spec close` (an unimplemented router branch, so `/gaia-spec close SPEC-001` starts a new SPEC titled "close SPEC-001" instead of closing one) to the real registered `/speckit-gaia-spec-close`, across the spec-close and wiki-promote commands, the smoke rule, and the `GAIA Spec` wiki page; automatic closing on the immediate-merge path and the reconcile sweep is unchanged, the manual command stays the deferred-drain backstop (#438)
- the release-scrub wikilink-to-excluded leak check derives its excluded-slug set at scan time from `.gaia/release-exclude` instead of a hand-maintained regex alternation that drifted from the manifest (a dated `wiki/meta/` audit page was excluded but never added to the list, so a shipped wikilink to it slipped past the check): bare-directory excludes (`wiki/entities`, `wiki/meta`) walk for the pages beneath them, matching is case-insensitive and alias/anchor-aware, and a newly excluded page is caught with no config edit (#434)
- reconcile shipped check definitions that contradicted GAIA design decisions and drove auditor variance or false flags: the `code-review-audit` bundle-size "named imports over namespace imports" check gains the documented-barrel carve-out its react-doctor sibling already had, and its phantom `new-route.md` rule reference becomes `routes.md`; the Claude Integration Fitness checks stop flagging a quoted counter-example path, treat a path glob as an activation trigger rather than a confinement claim, and drop an incorrect `block-rm-rf.sh` attribution; and the worthiness presence gate retires an inert D-8 honesty cross-check that double-gated an invariant the Quality Gate and CI lint already enforce. Page-folder naming standardizes on `{PascalName}Page` across the affected skills and decision pages (#431)
- exclude the maintainer-only bats suites `.gaia/scripts/tests` and `.github/audit/tests` from the release tarball (their only runner is itself release-excluded, so they never ran on an adopter clone) and synchronize the three maintainer-paths detection copies; heal health-audit-surfaced distribution drift by adding the runtime-created `.claude/wiki-recompact-pending` sentinel to the runtime-deps markers so the bundle check stops false-flagging it, and regenerating `.gaia/manifest.json` fresh against the exclusion list (#430)
- `gaia telemetry emit --abandoned` becomes a valued boolean (`--abandoned true|false`) instead of presence-only: it was declared presence-only while the `time_to_resolved_spec` schema requires a `boolean` value, so `--abandoned false` was unparseable (the parser set `abandoned=true` then choked on the stray token) and the success-path spec-timing signal emitted at `/gaia-spec` finalize silently never recorded under its `|| true` guard; anything other than `true`/`false` is now a clean `arg_parse_error` (#422)
- `/update-deps` override audit re-resolves with `pnpm dedupe` instead of `pnpm install` (which short-circuits "Already up to date" on an overrides-only change and could leave a security-floor override unapplied), and asserts the lockfile `overrides` block matches `pnpm-workspace.yaml` before finishing (#388)
- Playwright e2e self-heals the cold dev-server hydration race: `hydration()` probes for the hydrated meta then reloads once onto the now-optimized Vite bundle, and a global-setup `/` warm-up front-loads the first dep-optimize, so a cold `pnpm pw` passes without the local retry mask (#400)
- `/gaia-audit` auto-applies a clean, zero-action audit instead of parking it at the decision gate, closing the path where a `draft` report dangled and the statusline nudged "resume draft" indefinitely; every Stage 2 apply path (gated, `--apply`, and the new zero-action auto-apply) busts the statusline cache so the audit nudge clears immediately instead of lingering for its TTL (#416)
- repair `/gaia-init` defects surfaced by a real init run: `pnpm install` no longer aborts under `--no-tty` (`--config.confirm-modules-purge=false`), spec-kit registration stages through an in-project `mktemp -d` instead of a sandbox-forbidden `/tmp` removal, the Serena verify probe anchors to `^serena:` so a healthy install stops reporting `[FAIL]`, `strip-branding` de-brands the Storybook brand and removes the GAIA logo, and the invalid bare-handle `.github/CODEOWNERS` is dropped from the template so init writes a fresh `* @<username>`; `setup-cloned-gaia-project` gets the same spec-kit staging fix (#417)
- `gaia scaffold route` resolves output paths from `cwd` (matching the component and service generators), emits a flat `<kebab>.ts` locale file instead of a `<PageName>/index.ts` subtree, names page folders `<Pascal>Page`, fails loudly when the locale barrel is missing, and gains a `--dry-run` flag that previews writes without touching disk (#397)
- `gaia scaffold component --props` accepts comma-bearing prop types (`Record<string, unknown>`, multi-arg function props, tuples): only depth-0 commas split props, so a single `--props` value can mix plain and complex-typed entries instead of erroring out (#411)
- consolidate the react-doctor config to `doctor.config.ts` (matching the repo's `*.config.ts` convention), with a pre-commit hook and CI check guarding against a duplicate config silently shadowing it; `app/root.tsx` now escapes `<` in the inlined `window.process` env JSON so an env value containing `</script>` cannot break out of the inline script (#394)
- the `code-review-audit` self-heal step resets `claude-code-action`'s untrusted-PR file restore (`.husky`, `.mcp.json`, `.claude.json`, `.gitmodules`, `.ripgreprc`, `CLAUDE.md`, `CLAUDE.local.md`) to HEAD before staging, so it no longer emits a spurious self-heal commit that silently reverts legitimate PR changes to those paths (#395)
- clear named advisories in the toolchain by bumping `@babel/core` to 7.29.7 (GHSA-4x5r-pxfx-6jf8), `js-yaml` to 4.2.0 (GHSA-h67p-54hq-rp68), and `esbuild` to 0.28.1 (GHSA-g7r4-m6w7-qqqr), and pinning the `.gaia/cli` `vite` devDep to 8.0.16 (GHSA-fx2h-pf6j-xcff); `js-yaml` is a runtime dependency bundled into the `gaia` CLI binary, which was rebuilt (#413)
- polish `/gaia-init` i18n + CI prompts and keep GAIA in control of React Doctor: the additional-languages question leads with the resolved primary and promotes "add more languages" to a first-class choice; free-text language entry now uses a plain chat prompt (the prior `AskUserQuestion` "Other" was an inert button with no input field, so codes could not be typed) and accepts freeform names / codes / native script resolved to ISO 639-1 with an echo-back confirmation; and the GAIA CI enable + run-mode questions carry `docs.gaiareact.com/maintenance/gaia-ci/` links. `/gaia-init` and `/setup-cloned-gaia-project` strip React Doctor's bundled extras after install (standalone Actions workflow, commit hook, `doctor` package script, pinned `react-doctor` devDependency), since GAIA already triggers react-doctor via the skill and the `code-review-audit` agent at `@latest`; left alone the installer writes its hook into husky's generated `.husky/_/pre-commit` (GAIA sets `core.hooksPath=.husky/_`), bypassing the canonical `.husky/pre-commit`. The `add-locale` runbook points the LanguageSelect edit at the `LANGUAGE_LABELS` record (not the derived `OPTIONS` array) and asserts the language-switch spec against a translated key (`cta`) instead of `meta.title`, which `gaia init rename` sets to the project title and is therefore identical across locales (#454)

## [1.6.1] - 2026-06-12

### Added

- land the full chain on one branch and one PR (#379)
- prune prior-run artifacts at the start of a confirmed update (#376)
- accept a verbatim audit-workflow re-render as a no-marker bypass (#375)
- auto-render stale audit workflow on update (#371, #372) (#374)

### Changed

- shrink dep-audit.md to a wiki pointer (#380)
- pnpm-workspace.yaml must be copied into Docker pnpm stages (#373)

### Fixed

- exclude .claude-pr/ from the stamp dirty check (#370)

## [1.6.0] - 2026-06-11

### Added

- point React Router work at version-exact local docs
- public-safe audit progress breadcrumbs (#350)
- preview + snooze step before applying (#347)
- field-aware merge for pnpm-workspace.yaml (Step 7b) (#335)
- optional scope-hint argument
- post-apply verification, counted summary, 72h staleness grace
- decision gate + stateful report lifecycle (status field)
- Run /gaia-audit nudge from drift/budget/draft signals
- /gaia-harden command + /gaia-audit provenance handling + docs
- decline ledger + TTL tally refresher + statusline nudge
- finding-class emission contract + CI machine-readable findings block
- render the report as a width-aware ASCII card

### Changed

- sync wiki orchestration topology to depth-1 (Opus 4.8) (#364)
- make load-bearing wiki fetches imperative, tag deep-dives (#361)
- bound the autonomous + TDD loops, reconcile coding-guidelines (Opus 4.8) (#359)
- align skeleton-loader placeholders with the translation rule (#360)
- scope response style to conversation, add coaching (#358)
- record TypeScript 7 readiness decision
- sync wiki concept page with the decision gate and lifecycle
- set GitHub release body to adopter notes + lockstep docs
- wire release-notes into the website lockstep

### Fixed

- close maintainer-path leaks and stale manifest (Opus 4.8) (#367)
- main-thread orchestrator owns every spawn (depth-1) (Opus 4.8) (#363)
- bound autonomous-loop stops in update-deps/update-gaia (Opus 4.8) (#355)
- require subagents on stateful audit re-runs (Opus 4.8) (#356)
- make .specify dispatch explicit, not prose (Opus 4.8) (#357)
- defer version bump past summary; clarify orchestrator boundary (#362)
- coverage-first finding stage in gaia audit/judge prompts (Opus 4.8) (#354)
- tune for Opus 4.8 recall; bump model to opus (#353)
- retry once locally to absorb the cold-optimize-cache flake (#349)
- anchor bare-test guard to command position (#345)
- exempt type-only tests from the RED-verification gate (#344)
- repoint pnpm-11 override location to pnpm-workspace.yaml (#334)
- remove shadowed legacy react-doctor.config.json
- self-heal ls-loop anti-pattern and wiki action-type inaccuracy
- add CONFLICT class, set Stage 2 to Sonnet, sync wiki concept page
- rename vague `result` variables in tally.ts to `ghResult` and `tallyResult`
- drop the leading "> " from the report card header
- trigger CLI tests on code-review-audit.yml edits

### Added

- CI audit progress breadcrumbs: the `code-review-audit` workflow prints a curated
  per-phase timeline (scope resolved, oracles done, holistic review done, adversarial
  verify done, report stamped) into the GitHub Actions step summary, giving the
  otherwise-silent CI run (the action hides agent output on public repos) a public-safe
  signal of progress. Opt-in observability only: no raw tool output, no secrets, and a
  breadcrumb write never blocks the audit
- `/gaia-harden`: human-gated Policy-Memory Loop. When `code-review-audit` flags the same finding class across three or more distinct PRs at warning or higher within a rolling 90-day window, the statusline nudges; running `/gaia-harden` judges the lightest durable enforcement form (a path-scoped prose rule, a deterministic check, or a skill) and drafts it for your approval. Nothing is committed or activated without your say-so. Adds the `harden-tally` and `harden-ledger` CLI subcommands (#321)
- `/update-deps` interactive preview and snooze: updates are grouped (major, minor, patch, non-semver) and you can defer any group before applying. Snoozes persist in the gitignored `.gaia/local/declined-updates.json` and resurface after 14 days or when a newer version ships. Adds the `update-deps decline` CLI subcommand; `CI=true` and `--scope` runs skip the preview (#347)
- React Router local-docs rule: a path-scoped rule (`app/routes/**`, `app/pages/**`, `app/root.tsx`, `react-router.config.ts`) points React Router framework-mode work at the version-exact docs React Router 7.17.0+ ships as markdown under `node_modules/react-router/docs`, falling back to the online docs only when the local copy is absent

### Changed

- pnpm upgraded from 10.33.0 to 11.5.2; `packageManager` is pinned to `pnpm@11.5.2`. Workspace settings (`overrides`, `allowBuilds`, `publicHoistPattern`, `savePrefix`, `strictPeerDependencies`) move from `package.json` and `.npmrc` to `pnpm-workspace.yaml` (#333)
- `/update-gaia` merges `pnpm-workspace.yaml` field by field through the new `gaia update merge-workspace` primitive, keeping adopter-only overrides and build approvals while applying the release delta (#335)
- `/gaia-audit` researches first and presents a single Apply, Discuss, or Decline gate before changing any file. Adds a CONFLICT finding class, a resumable report lifecycle with a 72-hour re-apply grace window, a post-apply verification step, and an optional scope-hint argument; the apply stage runs on Sonnet (#326)
- `/gaia-fitness` renders its report as a deterministic width-aware ASCII card through the new `gaia fitness render-card` CLI subcommand (#320)
- TypeScript 7 readiness: `tsconfig.json` adopts `stableTypeOrdering` and `noUncheckedSideEffectImports` while still on TypeScript 6 (#331)
- `code-review-audit` runs its holistic review on Opus with a coverage-first pass that surfaces every candidate (tagged with severity and confidence) before adversarial verification filters them (#353, #354)
- `/gaia-plan` and `/gaia-spec` dispatch every subagent from a single depth-1 orchestrator, and per-bucket Haiku and Sonnet model pinning is now applied (#363)
- skeleton-loaders: static translatable text (labels, headings, button text) must use `t()` or `<Trans>`, and skeleton containers require `role="status" aria-busy="true"` (#360)
- statusline: `/update-gaia` now precedes `/update-deps`, and the harden nudge reads `Run /gaia-harden (N recurring patterns)` (#328)
- dependency refresh: react and react-dom 19.2.7, storybook 10.4.2, axe-core 4.12.0, chromatic 17.2.0, happy-dom 20.10.1, i18next 26.3.1; the `brace-expansion` and `ws` CVE overrides are dropped (resolved natively) and the `qs` override is retained (#332, #348)
- the `react-router` group is bumped to 7.17.0 (`react-router`, `react-router-dom`, and the `@react-router/dev`, `@react-router/node`, `@react-router/serve`, `@react-router/fs-routes`, `@react-router/remix-routes-option-adapter` packages); 7.17.0 ships its official docs as markdown under `node_modules/react-router/docs` for local lookup
- `update-deps` and `update-gaia` repoint dependency-override management to `pnpm-workspace.yaml` for pnpm 11 (#334)
- react-doctor reads a single `doctor.config.jsonc`; the legacy `react-doctor.config.json` is removed from the template (#327)
- the project `CLAUDE.md` response-style guidance is scoped to conversation, with a coverage carve-out for audits, reviews, plans, and specs, and a coaching register (#358)
- `coding-guidelines` clarifies that the impossible-scenario test ban does not cover real failure modes such as non-zero exits, loop non-convergence, and network errors (#359)
- CLI internals cleanup: several dead or unwired maintainer subcommands are retired (the generic `gaia update merge`, `automation init-state`, the cost-overage feature and `automation.state` layer, the smart-cron starvation valve, and the dead `state_file` workflow template var), a subcommand reachability guard rejects calls to commands the binary no longer exposes, and the CI audit gains a `--verbose` log mode (#336, #337, #338, #339, #340, #341)
- `/gaia-release` (maintainer-only) wires the `release-notes` skill into the website lockstep, overwrites the GitHub release body with the generated adopter-facing notes, and adds a docs-site version lockstep step (#318, #319)
- load-bearing wiki fetches in the instruction files are marked imperative (must-read) and deep-dive pages are tagged, tightening how the assistant pulls wiki context during a task (#361)

### Fixed

- the bare-test guard no longer false-positives on quoted prose: `block-bare-test.sh` anchors detection to command position (splits on pipeline separators, strips leading env-var prefixes, acts only when `pnpm`/`npm` is the command word and `test` is the script position), so the phrase appearing inside a commit message (`git commit -m "run pnpm test"`) or a `--body` string (`gh pr create --body "...pnpm test --run..."`) is no longer blocked, and the `--run` opt-out is scoped to the matched segment; the sibling `capture-red-observations.sh` gate is anchored the same way so a prose mention no longer triggers a spurious full-suite vitest re-run
- type-only tests no longer hit an unsatisfiable TDD RED-verification gate: the signal helper classifies each test `runtime` vs `type-only`, and the commit check exempts type-only tests (assertions all type-level via `expectTypeOf`/`assertType`/`@ts-expect-error`, no runtime expectation), delegating their correctness to the `tsc` quality gate
- `/update-gaia` defers the VERSION-file bump until after the run summary prints, so an interrupted run resumes at the baseline version instead of dead-ending as already up to date (#362)
- `/update-deps` and `/update-gaia` bound their retry and heal loops to one remediation pass plus a single gate re-run, then revert and log, instead of iterating open-ended (#355)
- the autonomous `/gaia-audit` and `/gaia-fitness` re-run paths require a fresh subagent on every stateful re-run, so a resumed cycle can't silently reuse a stale in-context report (#356)
- `/update-deps` override audit adds a security-floor pin test so a CVE-pinned override is never dropped as obsolete while a live advisory remains (#348)
- `/update-deps` skill no longer references a maintainer-only source path that is absent on adopter clones (#367)
- Playwright retries once on local runs to absorb the cold optimize-cache flake (#349)
- the `.specify` GAIA commands dispatch tools and skills explicitly instead of emitting prose narration (#357)
- the CLI test suite triggers on `code-review-audit.yml` edits, closing a gap where workflow changes shipped without exercising the CLI tests (#317)

## [1.5.0] - 2026-06-05

### Added

- dependency-CVE deterministic-oracle advisory (#299)
- mechanical TDD RED-verification (SPEC-003) (#297)
- decouple from upstream claude-obsidian, add native checks (#289)
- add maintainer-only release-notes skill (#283)

### Changed

- add /gaia-fitness to commands table (#281)
- split /gaia router into discrete /gaia-* commands and migrate all references (#277)

### Fixed

- repair PR-merge audit gate (specialist dispatch + clean no-change marker) (#313)
- exclude self-referential wiki-sync commits from drift count (#311)
- strip git-quoted paths in inspectWorkingTree (#308)
- run sync on Sonnet and add fabrication guard (#307)
- stop runtime-deps flagging prose path tokens as leaks (#304)
- repair flaky wiki-sync release-gate smoke harness (#303)
- repair two pre-existing release-gate failures (#302)
- close distribution-boundary leak failing the smoke suite (#301)
- guard CI-defer source so missing lib doesn't kill wiki hooks (#298)
- anchor git guards to command position (#296)
- exempt non-blocking residuals from the clean-A+ gate (#293)
- alias-proof bare `gaia` CLI calls to repo-relative `.gaia/cli/gaia` (#291)
- regenerate report fresh each run; never reuse a stale #11 (#286)
- out-of-scope bypass for docs/metadata-only PRs (#276) (#280)
- field-aware package.json merge (#275) (#279)
- inline literal sibling-repo paths in gaia-release pushes
- add repo-scope.sh to audit-ci-tests paths filter
- strip surrounding quotes from repo-scope path captures

### Changed

- replace the `/gaia <subcommand>` router with discrete `/gaia-*` entries so every workflow surfaces in slash-command autocomplete: `/gaia-plan`, `/gaia-spec`, `/gaia-audit`, `/gaia-fitness`, `/gaia-forensics` (commands) plus `/gaia-wiki`, `/gaia-handoff`, `/gaia-pickup` (skills, `gaia-wiki` stays a skill so the wiki-CI agent can still invoke it). The old space-form `/gaia <sub>` is removed; sub-arguments are unchanged (`/gaia-wiki sync`, `/gaia-spec auto`, `/gaia-audit --apply`). Workflow logic is untouched; the new entries dispatch into the same `references/*` instructions

### Fixed

- /update-gaia: merge `package.json` field-aware instead of as an opaque `shared` blob; never touch adopter identity (`name`/`version`/`description`/`author`/…), apply only the real upstream dependency/script delta, and never re-add a dependency the adopter intentionally removed. A version-only release now skips `package.json` cleanly instead of emitting a full-file conflict patch on every release (#275)
- repo-scope guard: strip surrounding quotes from literal `git -C "<path>"` and `cd '<path>'` captures so a quoted sibling-repo push is recognized as foreign and allowed, instead of being denied as a home-repo push to main

## [1.4.0] - 2026-06-02

### Changed

- promote machine-local feedback memories into shared wiki (#270)

### Fixed

- derive wiki playbook dates from the shell clock, not the model (#269)
- /update-gaia: scope the three-way merge to the real release delta; respect adopter-deleted files instead of re-injecting them, and skip owned files the release left unchanged instead of emitting spurious conflict patches (#268)

## [1.3.5] - 2026-06-02

### Added

- install code-review-audit on demand; honor both Claude tokens; key merge decision on workflow presence (#262)
- honor pnpm 11 minimumReleaseAge in version selection (#260)
- stamp GAIA-Audit status on out-of-scope skips (#257)
- gate expensive checks on the since-last-green delta (#254)
- enforce Content-Security-Policy for scripts (#253)
- incremental code-review-audit scope (#252)
- pnpm supply-chain hardening: root `pnpm-workspace.yaml` with `minimumReleaseAge` (7-day quarantine) and `trustPolicy: no-downgrade` (#251)

### Changed

- mark CI code-review-audit as opt-in (#263)
- clarify the gate owns formatting; make PR merge marker-first (#261)
- print kickoff prompt instead of copying to clipboard (#259)
- document useDebounce return semantics (#255)
- enable React Router v8 future flags for early v8 readiness: `v8_passThroughRequests`, `v8_splitRouteModules`, `v8_trailingSlashAwareDataRequests`, `v8_viteEnvironmentApi` (#251)
  - **Migration (`v8_passThroughRequests`):** loaders/actions now receive the raw `request`, so `request.url` keeps the `.data` suffix and `?index`/`?_routes` params on data requests. If you customized `app/root.tsx` (or any loader) and call `new URL(request.url)` for normalized routing, switch to the new normalized `url` arg (a `URL` instance), e.g. `({request, url}) => url.pathname`. `/update-gaia` delivers the updated `app/root.tsx` as a conflict patch for customized files, so apply this by hand when resolving it.

### Fixed

- detect orphaned wiki drift in preflight via suggested_base (#258)
- recover the un-evaluated window on sync re-anchor (#256)
- gaia-release updates softwareVersion
- `Form/Chain` composes `className` with `twMerge` instead of `twJoin`, so a consumer's utilities override the component's defaults (#251)

## [1.3.4] - 2026-05-26

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

## [1.3.3] - 2026-05-22

### Added

- `gaia setup-ci check-drift`: primitive that byte-compares rendered `.github/workflows/gaia-ci-*.yml` against a fresh in-memory render. Reports `{drifted, missing, in_sync}` per tool.
- `/setup-gaia-ci` Step 2 calls `check-drift` on configured repos. On drift, prompts for re-render / skip / full reconfigure instead of unconditionally short-circuiting.
- `/setup-gaia-ci` Step 11.5: lightweight drift-fix branch + commit + PR path. Regenerates only the workflow YAML; tool selection and bot token untouched.

## [1.3.2] - 2026-05-22

### Fixed

- dedupe audit issues, scope pre-run-skip per-tool, set git identity (#233)

## [1.3.1] - 2026-05-22

### Fixed

- `create-worktree.sh`: WorktreeCreate hook that creates the worktree and returns its path (#231)
- `update-gaia`: remove phantom `gaia update merge` CLI call from Step 7 (#231)
- `update-gaia`: Step 9 cache-bust writes the new version instead of preserving stale fields (#231)
- `update-gaia`: open a PR at the end of the run instead of stranding the branch (#231)

## [1.3.0] - 2026-05-22

### Added

- allow `/gaia plan` and `/gaia spec` to run concurrently in separate sessions without clashing; collision-proof atomic writes prevent racing writers from corrupting committed state (#198, #207)
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
- audit small fixes: amended_rate, rollback msg, parseKeyPath, generator dup, a11y (#210)
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

## [1.2.3] - 2026-05-20

### Added

- repo-scope main/PR-merge guards + create-gaia release lockstep

### Fixed

- update workflow template snapshots for id-token permission addition
- add json-strip transform to stop maintainer-only package.json keys reaching adopters
- harden block-main against multiple git -C flags
- close multi--C ambiguity in repo-scope; handle --repo= form

## [1.2.2] - 2026-05-19

### Fixed

- drop default id-token: write from pnpm-audit workflow

## [1.2.1] - 2026-05-19

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

## [1.2.0] - 2026-05-12

### Added

- `/gaia fitness`: Claude-integration health check + auto-heal (#169, #171)
- ai shimmer animation on `gaia-logo.svg` (#168)

### Fixed

- `release preflight` tolerates wiki-sync squash-artifact drift (this release)

## [1.1.1] - 2026-05-11

### Fixed

- gaia release reference to maintainer
- bug fixes from live init run (#165)

## [1.1.0] - 2026-05-10

### Added

- robust a11y tooling stack (#156)
- close slice-4 forward-refs (wiki + update-deps) (#153)
- add Phase A configure-automation step (#148)
- spec-001 slice 4: /setup-gaia-ci slash command (Phase B) (#147)
- spec-001 slice 3: GAIA CI workflow YAML generation (#146)
- spec-001 slice 2: auto-merge + auto-revert workflow shape (#145)
- spec-001 slice 1: smart-cron + per-tool state files (#144)
- add probe-after verification pass to Step 8 (#139)
- surface GAIA-Audit trailer invalidation count in summary (#140)
- rename /wiki-{sync,consolidate,lint} → /gaia wiki <sub> to resolve plugin collision (#121)
- /gaia spec auto + branch-default plan isolation
- code-review-audit CI gate + GAIA-Audit trailer skip mechanism (#117)
- autonomous triage workflow for gaia-forensics issues (#104)
- /gaia forensics: end-user bug-report bridge (#105)
- bundle-time scrub + runtime-deps primitives (#98)
- telemetry v1 (SPEC-001): three-stream architecture (#91)
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
- bootstrap-labels.sh: shorten needs-human desc, add gaia-forensics (#113)
- SPEC-003 triage workflow correctness + hardening (#110)
- close SPEC-004 sharp edges (setup-state, pre-merge audit, post-merge cleanup) (#109)
- address pre-merge audit findings (#106)
- enforce exclusive ceiling in spec-kit version-check

### Changed

- **BREAKING:** `/wiki-sync`, `/wiki-consolidate`, `/wiki-lint` slash commands are removed. Use `/gaia wiki sync`, `/gaia wiki consolidate`, `/gaia wiki lint` instead, or `/gaia wiki` for the full chain. Motivation: `/wiki-lint` collided with the `claude-obsidian` plugin's skill of the same name. Moving everything under the `/gaia` router namespace eliminates the collision and groups wiki maintenance with the other GAIA workflows. Hooks (`wiki-drift-check`, `wiki-commit-nudge`, `wiki-session-stop`) and statusline now point at the new names. Smoke tests under `.gaia/tests/smoke/wiki-sync/` updated. The playbooks moved from `.claude/commands/wiki-{sync,consolidate,lint}.md` to `.claude/skills/gaia/references/wiki/{sync,consolidate,lint}.md`.
- `/gaia audit` no longer covers intra-wiki duplication or broken-wikilink checks; those overlapped with `/gaia wiki consolidate` and `/gaia wiki lint`. Run `/gaia wiki` separately for wiki-internal audits.

### Added

- Dead-code detection via [knip](https://knip.dev). Run `pnpm knip` after refactors or before release-candidate PRs. Template-aware config marks GAIA's library surface as entries so intentional exports aren't flagged. `.claude/rules/knip.md` guides Claude on when to suggest it.
- Serena MCP server registered by `/gaia-init` for LSP-backed code intelligence. Pinned at `v1.2.0`. Requires `uv`. New `.claude/rules/code-search.md` routes Claude to Serena for TS/TSX symbol queries; `/gaia wiki sync` no longer marks new component / hook / service files WORTHY (Serena handles inventory freshness). See `wiki/concepts/Serena Integration.md` for the division of labor.

## [1.0.5] - 2026-05-04

### Added

- v1.0.5 wiki sync system: drift-check, commit-nudge, stop-safety-net hooks plus `/wiki-sync` workhorse for a convergent wiki-update model.

### Changed

- `/gaia-init` i18n setup is now language-aware: asks the user's primary language and optional additional locales, with an opt-out path that strips i18n entirely. Per-locale `add-locale` and `remove-i18n` instructions ship as parameterized runbooks under `.claude/instructions/`.
- Pin docs install command to `npx create-gaia@latest`.

### Fixed

- Restore statusline indicators for `/update-deps` and `/update-gaia`. The prior SessionStart hook approach was invisible to users; system-reminders only reach the model, and a 6h snooze locked in regardless of whether the user ever saw a prompt. Statusline indicators are passive and always visible.
- `/gaia-release` Step 2 gate now allows wiki-prefix-only drift, and `/wiki-sync` Step 7 is branch-aware (branch+PR on `main`, in-place commit elsewhere). Together they make the `/wiki-sync` → `/gaia-release` flow self-consistent.
- `/gaia audit` now chains research and apply by default; `--apply` is the retry escape hatch.
- Wiki sync system: smoke test assertions match the frozen interface.
- `/gaia-release` and `/gaia-init` scrub templates for `wiki/hot.md` (and `/gaia-release` Step 9 for `wiki/log.md`) now include the full frontmatter required by `/wiki-lint` (`status`, `created`, `tags`), eliminating a recurring lint regression on every release.

## [1.0.4] - 2026-05-01

### Fixed

- Handle `git -C <path>` in block-main-destructive-git hook

### Changed

- Wiki lint + audit hygiene sweep

## [1.0.3] - 2026-05-01

### Fixed

- Remove if conditionals from PreToolUse/PostToolUse hooks

## [1.0.2] - 2026-05-01

### Fixed

- Added `pnpm.onlyBuiltDependencies` for `core-js-pure`, `esbuild`, `msw`, and `unrs-resolver` to silence the pnpm build-script warning on fresh installs.

## [1.0.1] - 2026-05-01

### Fixed

- `/init` interceptor now reliably redirects to `/gaia-init`. The previous implementation used `UserPromptSubmit` + `exit 2`, which blocked the turn entirely so the model never ran. Switched to `UserPromptExpansion` (matcher: `init`) with `additionalContext` only; the model receives `/init`'s expansion plus a system-reminder override telling it to invoke `/gaia-init` via the Skill tool. The user-visible "blocked by hook" banner is gone.

## [1.0.0] - 2026-04-30

### Initial release

GAIA v1.0.0 is the inaugural public release of the GAIA React workflow, a Claude-native foundation that ships skills, commands, hooks, a wiki, and a curated React Router 7 app skeleton designed for agentic development from day one.

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
