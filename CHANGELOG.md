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

- replace the handoff archive lifecycle with delete-on-done. `/gaia-handoff` enforces a single-handoff invariant (it deletes any existing handoff before writing, so only one ever exists and a new one supersedes the old, carrying forward anything unfinished), and every handoff carries a self-Teardown instruction that deletes the file once its Next Actions are verified complete. `/gaia-pickup` no longer moves a consumed handoff into an `archive/` directory; it resolves in place (self-delete on the happy path, delete a stale handoff whose work has fully landed and resume from `wiki/hot.md`, or leave outstanding work untouched so an interruption stays recoverable) and runs a defensive sweep that keeps only the newest when more than one handoff exists. Deletion is the only terminal state; nothing is archived. **Action required:** remove any orphaned archive directory left by the prior workflow with `rm -rf .gaia/local/handoff/archive` (gitignored local scratch, safe to delete) (#448)
- adopt `@gaia-react/lint` 1.7.0 (from 1.6.0) to enforce the never-`null`-in-render idiom: new `gaia/no-restricted-syntax` selectors flag `cond ? <JSX/> : null` and `cond ? null : <JSX/>` and point to the boolean-guarded `&&` form (flag-only, no autofix). Extends never-null beyond render to GAIA-controlled types and state, the theme chain (`getTheme`, `RequestInfo.userPrefs.theme`, `ThemeSwitch.userPreference`, the `Document` guard) and `useComponentRect`'s timeout ref move from `null` to `undefined`; structural `null` is left intact (DOM refs, ref-callback params, `data(null)`, `Response.json(null)`, Zod `.nullable()`) (#441)
- adopt `@gaia-react/lint` 1.6.0 (from 1.5.1), reconciling the lint deltas it surfaces across the repo for the first time: the `resources+`/`actions+` `no-restricted-paths` UI-layer carve-out (retires the inline disable in `ThemeSwitch`), the D-8 test-honesty rules (`vitest/prefer-called-with`, plus `no-restricted-imports` on `*.server` / `**/internals/**` from consumer tests), and the unicorn 65 batch (#433)
- split the spec-session lifecycle from the SPEC artifact's status: `.gaia/specs.json` tracks the authoring session (`draft → specified → merged → archived`) while `SPEC.md` frontmatter keeps its own (`in-progress | reopened | closed`). `/gaia-spec` resume only offers a still-`draft` session, so a finalized SPEC is never re-surfaced as resumable, and a fail-open, idempotent `spec-reconcile.sh` derives the `merged` transition from a merged `spec-NNN-*` PR on git ground truth (#423)
- route GAIA workflow-misfire reports (hooks, skills, commands, quality gate, scaffold failures) through `/gaia-forensics` before filing by hand, and document an issue-claiming policy in `CONTRIBUTING.md`: only issues labeled `help wanted` are open for outside PRs, and contributors comment to be assigned before starting (#404)
- routine dependency refresh across two waves: `react-router` group to 7.18.0, the `storybook` group to 10.4.6, `@playwright/test` to 1.61.0, `tailwindcss` to 4.3.1, `vitest` to 4.1.9, plus further minor/patch bumps; transitive `undici` and the nested `vite` 7.x copy reached their patched security floors through the bumps, so their interim overrides were pruned (#387, #413, #415)

### Removed

- the vestigial `react-router-dom` dependency, a v6/v7 re-export shim that React Router 8 drops entirely; GAIA runs framework mode and imports everything from `react-router` (`HydratedRouter` comes from `react-router/dom`), so it was already dead weight on v7. `/update-gaia` leaves an existing `react-router-dom` in your `package.json` by design (adopter-owned dependencies are never auto-removed); `pnpm knip` also flags it as unused after this release (#419)
  - **Action required:** run `pnpm remove react-router-dom` to drop it

### Fixed

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
