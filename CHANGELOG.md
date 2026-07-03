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

- a Serena code-search enforcement guard (`.claude/hooks/serena-code-search-guard.sh`): a PreToolUse hook that blocks a bare-identifier `Grep` over `app/**` or `test/**` TS/TSX and routes it to Serena's LSP-backed symbol tools, closing the gap where the edit-scoped routing rule was absent from context during exploration. Re-running the identical grep passes for a genuine string or comment search, and the guard no-ops unless Serena is a registered MCP server with a `tsconfig.json` present, so adopters without Serena are unaffected (#511)
- `gaia.updateDepsHold`, a committed per-package version hold for `/update-deps`: a `{ package: ceiling }` map in `package.json` that caps a package to a version-prefix line (`"8.0"` holds the highest `8.0.x`, `"8.0.16"` freezes exactly). Unlike the CI-ignored local snooze ledger, the hold is committed, so it applies in interactive and CI runs until the maintainer lifts it, and fails closed when the ceiling matches no published version. The `/update-deps` preview surfaces active holds (#500)
- output-verification hardening for three GAIA self-audit workflows, so a single-pass judgment can no longer drive an edit or a clean verdict unchecked. `/gaia-audit` gains an optional classification-verification round before its Apply / Discuss / Decline gate (biased toward keeping any flagged memory delete it cannot confirm, since those deletes are irreversible); `/health-audit` (maintainer-only) gains a false-clean challenger that can revoke a clean exit; and `/gaia-fitness`'s final verify cycle now re-runs all seven categories, so a regression in a zero-finding lane is caught before it reports A+. All rounds are recommended-but-optional and never block (#472)
- a SessionStart janitor (`.claude/hooks/local-janitor.sh`) that garbage-collects dead working-state residue under the gitignored `.gaia/local/` on every startup/resume. It removes only residue whose death is provable, orphaned merge-gate markers, completed-but-unswept plan dirs, stray empty dirs, and local `wiki-sync/*` landing branches whose upstream is gone, so it is a backstop, not an owner; any unprovable death is skipped and the hook always exits 0 so it can never block a session from starting. Adds the `Local Working State` wiki concept page (#468, #506)
- a forced-disposition gate on out-of-scope `code-review-audit` findings, plus the `/gaia-debt` drain skill. Debt the audit opens within its review radius but the PR did not change no longer slips through, non-security findings file as deduped, severity-labeled `tech-debt` GitHub issues, while security-class findings are fail-safe classified and diverted off every public or enterprise-readable channel (a private issue only on a confirmed private repo). The gate is the audit's fourth marker precondition, and `/gaia-debt` drains one `tech-debt` issue per invocation (deterministic severity-then-age ordering, a fresh branch through the normal audit gate), surfaced by a `Run /gaia-debt (N issues)` statusline indicator. Adds the `Audit Disposition and Debt Drain` wiki concept page (#465, #475, #495, #496)
- a maintainer-only CHANGELOG gate in the PR merge workflow: before any `gh pr merge`, evaluate whether the change warrants a `## [Unreleased]` entry and, if so, land it on the PR branch before merging, re-checked on every merge (including PRs resumed across sessions) so an entry promised at authoring time can't be lost. Lives in the `PR Merge Workflow` wiki page and the always-loaded `pr-merge` rule, both maintainer-only (#446)
- `/gaia-react-perf`, a measure-only React render-performance diagnostic: it drives a micro-interaction, captures per-render attribution through a committed bippy Playwright harness, and presents a ranked `memoDefeated` diagnosis with a react-doctor cross-reference and a structural-first fix. v1 is measure-only, the human applies the fix in conversation. Adds the React Perf Diagnostic wiki concept page and registers the skill so `/update-gaia` ships it (#442, #443)
- a React 19 idiom gate in the `react-code` skill (Gate 4): ref-as-prop over `forwardRef`, boolean-guarded `&&` over the numeric-0 leak (coercion mandatory, with react-doctor's `rendering-conditional-render` rule as the pre-merge backstop), `use()` and the `<Context>` shorthand over `useContext`/`Context.Provider`, never `null` in render, and staying in React Router's lane for forms. `references/hook-patterns.md` gains `useEffectEvent` and ref-callback cleanup, and the `typescript` skill prefers `!!` over `Boolean()` for inline coercion (#441)
- a `remix-utils` awareness map (`wiki/dependencies/remix-utils.md`): a curated, risk-sorted decision map (hydration-safe client render, SSE, CSRF, honeypot, safe-redirect, debounced fetcher) reachable from the surfaces Claude loads before hand-rolling a primitive. `MetaHydrated` now derives its hydration signal from remix-utils' `useHydrated()`, so `remix-utils` becomes a genuine import and drops out of knip's `ignoreDependencies` (SPEC-007) (#427)
- a canonical-status guard on the SPEC ledger: writes rejecting any `.gaia/specs.json` row whose `status` is off the canonical vocabulary (`draft → specified → merged`, plus terminal `archived`), and a reconcile pass that normalizes known-misnamed statuses rather than guessing. It ships, so the protection reaches adopters authoring their own SPECs; the `GAIA Spec` wiki page documents the vocabulary (#425)
- `/gaia-spec` auto-archives merged SPECs through a fail-open sweep on every run: any SPEC folder whose ledger row reads `merged` but still sits in the active specs dir moves into `.gaia/local/specs/archived/` with `status: archived` stamped on the artifact. This is the safety net for a PR merged out-of-band (the GitHub button, another session), so the active dir no longer accumulates landed SPECs; it is silent-but-logged and reversible (#426)
- an adversarial multi-agent SPEC-audit in `/gaia-spec`, offered once before the final gate (recommended by default, opt-in, never blocking save): low-overlap lenses verify the draft's checkable claims against the repo and `node_modules` rather than on faith, a refutation pass keeps severity honest, and each surviving finding becomes either a plan-time directive (recorded in a sibling `AUDIT.md`) or a contract fix folded into the draft pre-save. It runs as a parallel `general-purpose` Agent fan-out so it works headless, and keeps the main thread lean by holding finding bodies in a per-spec on-disk cache while a delegated applier folds the fixes (SPEC-011) (#423, #483)
- a lightweight adversarial decomposition audit in `/gaia-plan`, offered once after the plan is generated (recommended for non-trivial plans, opt-in, never blocking the handoff): three parallel lenses verify the decomposition itself, the one artifact neither the upstream SPEC-audit nor the downstream pre-merge `code-review-audit` can see, checking task-graph soundness, that every file, export, type, and signature named in a task contract resolves against the real repo and `node_modules`, and SPEC coverage. It is deliberately narrower than the SPEC-audit (no refutation pass, since the findings are checkable); localized findings fold into the task docs, a structural finding re-spawns the planner (#424)
- an adopter-action CHANGELOG convention: a `### Removed` / `### Changed` entry carrying an **Action required:** line and/or a literal `pnpm` command, which `/update-gaia` reads to surface documented, opt-in cleanups during a merge (never acting on your behalf) and the maintainer-only `release-notes` skill keys on to reframe or drop agent-automated cleanups while keeping genuine migrations. `/update-gaia`'s confirm gate now shows the full baseline-to-latest CHANGELOG range, so an adopter several versions behind sees every intervening entry
- `react-code` skill leads with a platform-first ladder (existing GAIA code → web platform like `Intl`/`URL`/`crypto.randomUUID` → already-installed dep → new dep → custom code) to walk before adding a dependency or hand-rolling a primitive
- `/gaia-harden` weighs an efficacy lens (Axis 3) before recommending a form: a recurring finding proves the problem, not the fix, so when the recommended form is prose and no cheap before/after evidence shows it would change behavior, that surfaces as a defer/decline signal for the human, never an auto-decline
- point Zod schema work at Zod's official LLM docs and treat them as authoritative over training memory, so valid Zod 4 forms are not rejected from stale v3 recollection
- a TDD testing-strategy foundation (SPEC-006): an AST determinism classifier scopes the hard RED commit gate to deterministic tests, so affirmatively-emergent test files are no longer forced to show a natural RED; a second `gh pr merge` gate proves the worthiness extractor ran over changed emergent tests; an advisory two-axis (honesty and worthiness) audit surfaces keep/fix/delete proposals with every delete human-gated; and `new-component` scaffolds a non-degenerate a11y test that can actually fail. Adds the Determinism Classifier, Worthiness Audit, and Worthiness Presence Gate wiki pages (#408)
- per-author `code-review-audit` mode (local vs CI): the pre-merge audit gate keys on a `GAIA-Audit` commit status resolved per PR author, so a developer in local mode runs the audit on their machine while CI stands down, the branch stays protected, and the gate fails closed to CI whenever a local run cannot confirm the required check. `gaia-init` and `setup-gaia` gain audit-mode prompts, and `/update-gaia` field-merges `.gaia/audit-ci.yml` so a committed `audit_authors` entry never forces a whole-file conflict (#407)
- restore the wiki hot cache after a context compaction through two GAIA-owned hooks (a `PostCompact` sentinel writer plus a `UserPromptSubmit` re-injector), so the "where we left off" cache survives compaction without depending on a claude-obsidian hook that some Claude Code builds reject (#386)

### Changed

- `/update-deps` completes the flow on a `main`/`master` run: it now writes the update commit with a load-bearing `chore(deps)` subject (previously Phase 8 referenced "the update commit" but never wrote one), opens the PR, and merges it once the required checks are green (`--auto` under branch protection), then verifies the terminal `MERGED` state and cleans up the local checkout. A run on any other branch (or in CI) is unchanged: it pushes and leaves the PR to the branch owner. The `chore(deps)` subject clears the merge gate's dep-bump bypass, so the PR stays turnkey-mergeable without a code-review-audit marker (#534)
- GAIA's Serena code-search routing guidance is now language-agnostic: the advisory `code-search` rule nudges toward Serena's LSP-backed symbol tools for symbol queries in any language Serena indexes for the project (not only TypeScript, and no longer scoped to `app/`/`test/`), so an adopter who configures another language server gets the same routing. The enforcement guard stays deliberately TypeScript-conservative and tsconfig-gated, since a wrong hard-block on a non-TS search is worse than a miss while the rule only nudges (#533)
- `/gaia-debt` drives its fix PR through the standard PR Merge Workflow to completion instead of stopping after `gh pr create` for a human to merge by hand: it confirms intent (open-only or merge, defaulting to merge), then resolves the marker handshake, the maintainer-only CHANGELOG gate, the merge (`--auto` under branch protection, never `--admin`), and the post-merge verify-and-cleanup itself. The `code-review-audit` marker gate is unchanged, the skill drives the merge and never bypasses, fakes, or pre-empts it (#523)
- `gaia setup finalize` refuses to stamp per-machine setup complete while the mentorship decision artifact `.gaia/local/mentorship.json` is absent, and that refusal holds even under `--force`, so the completion marker can no longer claim success when the opt-in decision was never persisted. It emits a structured error whose `code` is `mentorship_decision_missing`, and `/gaia-init` Step 12 self-heals on that code by re-applying the safe default and retrying finalize once, so an automated init that dropped the opt-in still completes without human input. The gate keys on file existence only, leaving `/setup-gaia`'s recovery net the owner of upgrading a lingering `enabled:null` decision (#520)
- `/gaia-spec`'s closing handoff now prints a single copy-pasteable block: the `/gaia-plan` command and its SPEC argument together, prefaced by a `/clear`-and-paste instruction, instead of a bare argument the user had to prefix with the command by hand (#519)
- catch the README up with shipped changes: correct the tech stack to React Router 8 and the Node engine floor to `>=22.22.0` (both moved with the React Router 8 major), and document `/gaia-debt` in the commands table and the tech-debt section (#517)
- `/setup-gaia` gates the Claude GitHub App install before its CI verification run: because every GAIA CI workflow authenticates as that app, the command now walks you through installing it (skipping the prompt when it detects the app already present on your org) and waits for confirmation, instead of dispatching a run that fails with a 401 and only then telling you what was missing. You can also skip verification and finish setup, then trigger a run from the Actions tab once the app is installed (#516)
- `/setup-gaia` finalizes greenfield CI setup by committing GAIA's own CI-install workflows directly to the default branch (no PR and no audit, since that commit has nothing to review), so first setup no longer waits on or wedges behind an audit run; the direct push accounts for repository rulesets and recovers cleanly when one blocks it, and the block-main guard stands down only for that single commit via a self-healing, gitignored sentinel. Its audit-mode onboarding now opens with a solo-or-team choice: solo engineers run audits locally by default (CI kept as a failsafe), and teams get a single Local-recommended-or-CI choice (#515)
- `/setup-gaia` now asks where a new GitHub repo should live, your personal account or one of your organizations, instead of silently creating it under your personal namespace; organizations are offered ranked by your own recent commit activity, and the prompt is skipped entirely when you belong to none. `/gaia-init`'s closing message drops the stale "create your GitHub repo, then run /setup-gaia" step now that repo creation lives inside `/setup-gaia` (#512)
- onboarding is now a single `/setup-gaia` command, replacing `/setup-gaia-ci` and `/setup-cloned-gaia-project`. It detects your situation (fresh clone, first adopter, partial run, or fully provisioned), runs only the phases still owed, provisions the GitHub repository (private by default), and is safe for any teammate to re-run after cloning. CI-token setup is out-of-band and never asks you to paste a secret into the chat: it reuses a `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` the repo or org already exposes when present (by name only, never by value), otherwise you set the secret yourself and the command only verifies it exists. **Action required:** run `/setup-gaia` instead of the two retired commands; `/update-gaia` surfaces the removal of the old command files with a per-file confirm prompt on your next update (#478, #480, #509)
- `/gaia-init` setup-flow polish. It auto-detects the user's GitHub handle for `.github/CODEOWNERS` via `gh api user` instead of always writing the `REPLACE-WITH-YOUR-GITHUB-HANDLE` placeholder (on failure it keeps the placeholder and the required-follow-up warning). The i18n and CI prompts are polished, and `/gaia-init` and `/setup-cloned-gaia-project` strip React Doctor's bundled extras after install (standalone Actions workflow, commit hook, `doctor` package script, pinned devDependency), since GAIA already triggers react-doctor via the skill and the `code-review-audit` agent at `@latest` (#454, #507)
- `/gaia-fitness` (and `/health-audit`'s shared fitness bucket) now dispatch each judgment-auditor with an explicit coverage directive in its prompt (surface every candidate, including uncertain or low-severity ones; the Orchestrator's adjudication stage is the filter), so recall no longer rides on the auditor's own bar. Documented in `wiki/decisions/Claude Integration Fitness.md` (#486)
- adopt `@gaia-react/lint` 1.8.0 (from 1.5.1), reconciling every lint delta across the repo. The headline behavior change: `no-null-render` now autofixes `return null` to `return undefined` inside render functions only (loaders, actions, and utils untouched; structural `null` left intact), and a report-only selector flags the `.length && <JSX/>` numeric-0 leak. The bundled toolchain (`typescript-eslint`, `eslint-plugin-sonarjs`, unicorn) moves in step and the surfaced findings are resolved (#433, #441, #461)
- the `prepare` lifecycle no longer provisions Playwright browsers: `pnpm exec playwright install --with-deps` moves to a dedicated `pnpm install:browsers` script, so `pnpm install --frozen-lockfile` no longer triggers an `apt-get` that can fail behind a proxy or on a hardened runner. **Action required:** run `pnpm install:browsers` once to provision Playwright browsers locally if you run the e2e suite (`pnpm install` no longer does it for you) (#456)
- the fresh-scaffold visual baseline is now neutral and brand-free (SPEC-008): the `--color-claude-*` terracotta scale is replaced by a zero-chroma `--color-primary-*` scale so re-skinning is a few-value change, Google Fonts are dropped for system stacks, and `Layout` is simplified to a single `<main>` wrapper. A path-scoped `design-baseline.md` guard and a `Design System.md` stub keep Claude from reading the neutral baseline as a chosen design system. **Adopters who customized owned files** (`Header`, `Footer`, `GaiaLogo`, or the bundle) will see a migration impact in `/update-gaia`; those files are removed upstream (#455)
- routine dependency refresh across several waves: `@types/node` to 26.0.0 (types-only, runtime stays on Node 22), plus the `storybook` group, `@playwright/test`, `tailwindcss`, `vitest`, `@faker-js/faker`, `chromatic`, `happy-dom`, `nanoid`, and further minor/patch bumps. Transitive `undici`, the nested `vite` 7.x copy, and the `qs` security-floor override reached their patched floors or became redundant through the bumps, so those interim overrides were pruned and `pnpm audit` stays clean (#387, #413, #415, #452)
- upgrade React Router 7.18.0 → 8.0.1 across the family (`react-router`, `@react-router/*`), a low-risk "boring major": GAIA already adopted all five v8 future flags on v7 and imports everything from `react-router`, so router runtime behavior is unchanged at cutover and the now-invalid `future` block in `react-router.config.ts` is deleted. It also bumps `remix-utils` to 10.0.0 and `remix-i18next` to 8.0.0 (both peer `react-router` ^8 natively), and the nested `vite` 7.x toolchain copy disappears because `@react-router/dev@8` widens its vite peer to ^7||^8, so the dev-only audit advisory has nothing left to flag (closes #398). **Action required:** raise your local Node to >=22.22.0 (the v8 engine floor; `.nvmrc`/`.node-version` pin 22.23.1 on the 22.x LTS line) (#444, #450)
- catch the README up for the next release: add `/gaia-react-perf` and `/gaia-harden` to the commands table, add `a11y-fixes` to the bundled-skills lists, and refresh the lint-rule count (#449)
- replace the handoff archive lifecycle with delete-on-done. `/gaia-handoff` enforces a single-handoff invariant (it deletes any existing handoff before writing, carrying forward anything unfinished), and `/gaia-pickup` resolves it in place, self-deleting on the happy path and leaving outstanding work untouched so an interruption stays recoverable, instead of moving consumed handoffs into an `archive/` directory. Deletion is the only terminal state; nothing is archived. **Action required:** remove any orphaned archive directory left by the prior workflow with `rm -rf .gaia/local/handoff/archive` (gitignored local scratch, safe to delete) (#448)
- split the spec-session lifecycle from the SPEC artifact's status: `.gaia/specs.json` tracks the authoring session (`draft → specified → merged → archived`) while `SPEC.md` frontmatter keeps its own (`in-progress | reopened | closed`). `/gaia-spec` resume only offers a still-`draft` session, so a finalized SPEC is never re-surfaced as resumable, and a fail-open reconcile pass derives the `merged` transition from a merged PR on git ground truth (#423)
- route GAIA workflow-misfire reports (hooks, skills, commands, quality gate, scaffold failures) through `/gaia-forensics` before filing by hand, and document an issue-claiming policy in `CONTRIBUTING.md`: only issues labeled `help wanted` are open for outside PRs (#404)

### Removed

- the orphaned `setup-ci set-secret` CLI verb, superseded by #478's out-of-band token provisioning: dead-but-advertised surface and a latent paste-reintroduction vector (invoking it required an agent to hold the CI bot token on stdin). Deleted outright; maintainer CLI surface, so release-excluded (#479)
- `app/components/Header/`, `app/components/Footer/`, `app/components/GaiaLogo/`, and `app/assets/images/gaia-logo.svg` from the template: these GAIA-branded surfaces are removed from the scaffold rather than shipped and stripped at init, with the neutral index + `Layout` in their place. Adopters who customized any of these owned files will be offered a migration note by `/update-gaia`; the maintainer logo the README references was relocated to `docs/assets/gaia-logo.svg`, outside `app/` so it never enters the app build or the distributable (#455, #458)
- the vestigial `react-router-dom` dependency, a v6/v7 re-export shim that React Router 8 drops entirely; GAIA runs framework mode and imports everything from `react-router` (`HydratedRouter` comes from `react-router/dom`), so it was already dead weight. `/update-gaia` leaves an existing `react-router-dom` in your `package.json` by design (adopter-owned dependencies are never auto-removed); `pnpm knip` also flags it as unused (#419)
  - **Action required:** run `pnpm remove react-router-dom` to drop it
- the `/gaia-spec` GitHub-issue mirror and the inline `/gaia-plan` chain (SPEC-012). The mirror is gone end to end (the opt-in question, auto-mode force-on, resume re-ask, mirror step, PR-body-closure, frontmatter stamping, and the `gh-mirror.sh` script). The chain is replaced by a handoff: after the canonical save `/gaia-spec` prints a copy-pasteable `/gaia-plan` handoff prompt and stops, so the human runs `/gaia-plan` in a fresh session with a clean context budget (#484)

### Fixed

- correct GAIA's Serena registration so Opus actually reaches for Serena's symbol tools instead of its own built-in search. Both setup surfaces now register the MCP server in the `claude-code` context with `--project-from-cwd` auto-activation and pair it with Serena's system-prompt override (the `--append-system-prompt` launch form plus an always-loaded fallback rule), replacing a desktop-app-context registration with no project activation and no override that left symbol queries almost never routed to Serena. The code-search guard now also catches a single bare-identifier symbol `grep`/`rg`/`ag` issued through `Bash`, not just the structured `Grep` tool, staying conservative so pipelines, compound commands, quoted or regex patterns, and searches outside `app`/`test` TS/TSX pass through untouched; the Serena usage scan counts shell greps too, so its search-volume denominator is honest. Adopters without Serena registered are unaffected (#531)
- extend the bundle-time scrub's `maintainer-paths` check to the maintainer-only CLI binary `.gaia/cli/gaia-maintainer`, the one observation the `.github/forensics/` closure above left out of scope. It is release-excluded like `.gaia/cli/src/` and `.gaia/cli/health/` (already guarded) but was not a tripwire, so a future reference to it from a shipped surface would not fail the release build. There is no live leak: the sole shipped occurrence (architecture prose in `wiki/concepts/Telemetry.md`) is already allowlisted, and the widely-referenced adopter binary `.gaia/cli/gaia` cannot match the literal `gaia-maintainer`. Config only, no CLI rebundle (#529)
- close a distribution-boundary leak in the `code-review-audit` workflow template that `/setup-gaia` renders onto adopters: a comment cross-referenced the maintainer-only `forensics-triage.yml` workflow, which never ships, so the installed workflow carried a dangling pointer to a file adopters don't have. Neutralized to a generic pinned-SHA note, and hardened the bundle-time scrub with a check that derives the never-installed workflow set from `.gaia/release-exclude` at scan time and flags any shipped-surface reference to one, so the class cannot recur. Surfaced by the `/health-audit` false-clean challenger (#527)
- close the remaining shipped-surface references to the release-excluded `.github/forensics/` directory, the same distribution-boundary class as the `code-review-audit` template leak above but in descriptive docs rather than a rendered pointer. A `/gaia-harden` routing example that sent adopters to a maintainer-only script they don't have is genericized to route knip enforcement to the audit agent or CI; the three legitimate references (the forensics parse contract, the Quality Gate CI-gate description, and a guarded label-bootstrap hint) are kept and allowlisted. The bundle-time scrub's `maintainer-paths` check now covers `.github/forensics/`, so any future reference to that wholesale-excluded directory fails the release build. Config and docs only, no CLI rebundle (#528)
- the finalize mentorship-decision gate no longer strands a linked worktree: `.gaia/local/mentorship.json` joins the worktree shared-state symlink set alongside `setup-state.json`, so a decision persisted from a linked worktree (resolved from the linked root) satisfies the gate (resolved from the main-worktree root) instead of a first-ever `/setup-gaia` there refusing with `mentorship_decision_missing` it can never self-heal. The main checkout, where the two roots coincide, is unaffected (#522)
- restore GAIA's mentorship layer across three defects that left it silently off or noisy. A `/gaia-init` mentorship opt-in dropped mid-flow (an interrupted Step 10 prompt left no `mentorship.json`, and finalize never verified one) is now recoverable: `/setup-gaia` re-surfaces the decision whenever the config is absent or still undecided, even after per-machine setup is finalized, instead of leaving mentorship stuck at the pre-decision default. The auto-mode `/gaia-spec` timing emit stops silently failing (it passed `--agent-type auto`, which the CLI rejects, so the `time_to_resolved_spec` signal was dropped under the `|| true` guard) and now marks auto runs with a dedicated `--auto` flag that partitions them out of the human pacing baseline. And `gaia mentorship enable` no longer prints a spurious `mentorship_dir_mode_unexpected` warning for the Claude-owned project directory it neither owns nor should re-permission. The CLI binary was rebuilt (#518)
- `/gaia-wiki` now lands its maintenance PR like any other merge: `gaia wiki chain finish` (and standalone `sync`'s protected-branch path) waits for the PR to merge, then pulls the base and deletes the local `wiki-sync/*` branch, instead of enabling auto-merge and returning immediately, which left local `main` un-pulled and the branch lingering until the session-start janitor swept it. If the merge does not land within the bounded wait, auto-merge stays queued and cleanup falls back to the janitor, so the command never hard-fails (#514)
- harden `/gaia-init` (and its `/setup-gaia` successor) across real init runs: one AskUserQuestion timeout no longer cascades into unattended auto-defaulting of every downstream identity gate (each gate evaluates independently, and an unknown CODEOWNERS handle ships a loud placeholder rather than a fabricated value), and init no longer git-mv's or advertises the release-excluded CI workflows that are absent from the scrubbed tarball. Real-run defects are fixed, `pnpm install` survives `--no-tty`, spec-kit registration stages in-project instead of a sandbox-forbidden `/tmp` path, and the Serena verify probe anchors correctly; and react-doctor v0.5.8's changed install layout is handled end to end (the non-Claude `.agents/skills/` copy is stripped, the verify probe repoints to `.claude/skills/react-doctor`, and `/setup-gaia`'s `pnpm pkg delete` uses the bracket-quote form) (#417, #439, #504, #509)
- the `code-review-audit` CI workflow now stamps the durable `GAIA-Audit` commit status on a clean audit whose only tree delta is an off-limits self-heal surface (`.claude/**`, `.specify/**`, `wiki/**`, or a >10-file sprawl). Such a PR previously set `refused=true`, skipped every success-stamp step, and blocked the merge despite a clean audit (recurring on every `.claude/**`-touching PR); the gating condition is dropped and the proven-clean marker check stays the sole guard (#501)
- `/update-deps` preview and override handling are correct: a snoozed group is now marked `[snoozed until DATE]` and default-skipped (with an explicit "update everything incl. snoozed" override) instead of being silently re-offered every run, and the override audit re-resolves with `pnpm dedupe` instead of `pnpm install` (which short-circuits on an overrides-only change), asserting the lockfile `overrides` block matches `pnpm-workspace.yaml` before finishing (#388, #500)
- close a series of distribution-boundary and manifest-tracking gaps, mostly surfaced by `/health-audit`, so maintainer-only surfaces cannot leak into an adopter bundle and the boundary greps stop mis-triaging shipped files. The leak-check greps are tightened, the release-scrub excluded-slug set is derived from `.gaia/release-exclude` at scan time instead of a drifting hand-maintained regex, two shipped skill docs that named maintainer paths are scrub-wrapped, and the manifest is regenerated fresh against the exclusion list. All maintainer-only and config-driven, so no CLI rebundle (#430, #434, #497, #499)
- the statusline `Run /gaia-harden` nudge no longer silently disappears during a `gh`/network outage: the refresher read only `candidate_count` and ignored the `gh_ok` boolean, so a failed window read (which exits 0 emitting count 0) was treated as a genuine all-clear and dropped the nudge for the duration of the outage. It now parses `gh_ok` and keeps the previous cached count whenever the read failed (#494)
- make hardcoded machine-specific absolute paths repo-relative, so a maintainer who forks `gaia-react/gaia` (and any adopter scaffolding from the template) is never pinned to the original author's checkout: the `.gaia/cli` storage-slug example becomes a neutral placeholder and the `.specify` runbook derives `GAIA_ROOT` from `git rev-parse --show-toplevel`. Codifies the standing policy in a new `.claude/rules/repo-relative-paths.md` (a portable `git grep "$HOME"` audit plus two documented exceptions) (#490)
- close 25 defects found in an adversarial audit of `/gaia-forensics` (the end-user bug-report skill and its maintainer-only triage CI). Adopter-facing: the redaction pass that runs before a report is filed to a public issue now catches secret and identity shapes it previously missed (fine-grained GitHub PATs, JWTs, `Bearer` tokens, Slack app tokens, connection-string credentials, and bare `/Users`/`/home`/`/root` paths), and the skill verifies the `gaia-forensics` label actually attached instead of reporting a false success. Maintainer-only and release-excluded: the triage workflow is hardened against prompt-injection and no longer strands an issue as triaged-but-unhandled (#487)
- `/gaia-plan` no longer fires a delete-permission prompt on every run: the post-planner verify step confirms the required artifacts exist and warns if planner scratch survived, instead of force-deleting `.work/`. The planner already removes its own scratch, so the `rm -rf` backstop only cost an interactive prompt each run (#460)
- `LanguageSelect` renders nothing when only one language is configured: a single configured locale gave the switcher a pointless one-item dropdown, so the guard returns `undefined` when `LANGUAGES.length <= 1` and self-activates once a second locale is added via the add-locale runbook. The IndexPage test and language-switch a11y E2E are split to keep both single-language and multi-locale projects green, and the `remove-i18n` runbook gains a step to drop the dangling `LanguageSelect` import (#457)
- the `/gaia-wiki lint` and `/gaia-wiki consolidate` playbooks `mkdir -p wiki/meta/` before their first report write: `wiki/meta/` is release-excluded, so a freshly scaffolded adopter clone had no such directory and the first run failed with `No such file or directory` (#447)
- close the numeric-0 `&&` leak in shipped `Form` components and `ErrorStack`: `Checkbox`, `Field`, and `FieldLabel` boolean-coerce their `ReactNode` `&&` operands so a falsy operand can no longer render a literal `0`, and render returns move from `return null` to `return undefined` (`MetaHydrated`, `FormError`, `ErrorStack`) (#441)
- correct two `/gaia-spec` finalize/close defects: the documented manual close handle changes from `/gaia-spec close` (an unimplemented router branch that instead started a new SPEC) to the real `/speckit-gaia-spec-close`, and `gaia telemetry emit --abandoned` becomes a valued boolean (`--abandoned true|false`) so the success-path spec-timing signal is no longer silently dropped (#422, #438)
- reconcile shipped check definitions that contradicted GAIA design decisions and drove auditor variance or false flags: the `code-review-audit` bundle-size "named imports over namespace imports" check gains the documented-barrel carve-out its react-doctor sibling already had, the Claude Integration Fitness checks stop flagging a quoted counter-example path, and the worthiness presence gate retires an inert double-gating cross-check. Page-folder naming standardizes on `{PascalName}Page` across the affected skills and decision pages (#431)
- Playwright e2e self-heals the cold dev-server hydration race: `hydration()` probes for the hydrated meta then reloads once onto the now-optimized Vite bundle, and a global-setup `/` warm-up front-loads the first dep-optimize, so a cold `pnpm pw` passes without the local retry mask (#400)
- `/gaia-audit` auto-applies a clean, zero-action audit instead of parking it at the decision gate, closing the path where a `draft` report dangled and the statusline nudged "resume draft" indefinitely; every Stage 2 apply path busts the statusline cache so the nudge clears immediately (#416)
- the `gaia scaffold` generators handle real inputs: `scaffold route` resolves output paths from `cwd`, emits a flat locale file, names page folders `<Pascal>Page`, fails loudly when the locale barrel is missing, and gains a `--dry-run` flag; and `scaffold component --props` accepts comma-bearing prop types (`Record<string, unknown>`, multi-arg function props, tuples) by splitting only on depth-0 commas (#397, #411)
- consolidate the react-doctor config to `doctor.config.ts` (matching the repo's `*.config.ts` convention), with a pre-commit hook and CI check guarding against a duplicate config silently shadowing it; and `app/root.tsx` now escapes `<` in the inlined `window.process` env JSON so an env value containing `</script>` cannot break out of the inline script (#394)
- the `code-review-audit` self-heal step resets `claude-code-action`'s untrusted-PR file restore (`.husky`, `.mcp.json`, `CLAUDE.md`, and siblings) to HEAD before staging, so it no longer emits a spurious self-heal commit that silently reverts legitimate PR changes to those paths (#395)
- clear named toolchain security advisories across the app and the maintainer CLI: bump `@babel/core` (GHSA-4x5r-pxfx-6jf8), `js-yaml` (GHSA-h67p-54hq-rp68), and `esbuild` (GHSA-g7r4-m6w7-qqqr), and pin the `.gaia/cli` `vite` devDep (GHSA-fx2h-pf6j-xcff); `js-yaml` is bundled into the `gaia` CLI binary, which was rebuilt. In the same workspace the `tsx` devDependency is bumped to clear its transitive `esbuild` off the vulnerable floor, resolving Dependabot alert #116 (#413, #453)

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

- CI audit progress breadcrumbs: the `code-review-audit` workflow prints a curated per-phase timeline (scope resolved, oracles done, holistic review done, adversarial verify done, report stamped) into the GitHub Actions step summary, giving the otherwise-silent CI run a public-safe signal of progress with no raw tool output or secrets, and a breadcrumb write never blocks the audit (#350)
- `/gaia-harden`, a human-gated Policy-Memory Loop: when `code-review-audit` flags the same finding class across three or more distinct PRs within a rolling 90-day window, the statusline nudges, and running `/gaia-harden` judges the lightest durable enforcement form (a path-scoped rule, a deterministic check, or a skill) and drafts it for approval, committing nothing without your say-so (#321)
- `/update-deps` interactive preview and snooze: updates are grouped (major, minor, patch, non-semver) and you can defer any group before applying; snoozes persist and resurface after 14 days or when a newer version ships, and `CI=true` or `--scope` runs skip the preview (#347)
- a React Router local-docs rule: a path-scoped rule points framework-mode work at the version-exact docs React Router ships as markdown under `node_modules/react-router/docs`, falling back to the online docs only when the local copy is absent

### Changed

- pnpm upgraded from 10.33.0 to 11.5.2, with `packageManager` pinned to `pnpm@11.5.2`; workspace settings (`overrides`, `allowBuilds`, `publicHoistPattern`, `savePrefix`, `strictPeerDependencies`) move from `package.json` and `.npmrc` to `pnpm-workspace.yaml` (#333)
- `/update-gaia` merges `pnpm-workspace.yaml` field by field, keeping adopter-only overrides and build approvals while applying the release delta (#335)
- `/gaia-audit` researches first and presents a single Apply, Discuss, or Decline gate before changing any file, adding a CONFLICT finding class, a resumable report lifecycle with a 72-hour re-apply grace window, post-apply verification, an optional scope-hint argument, and a statusline nudge from drift/budget/draft signals; the apply stage runs on Sonnet (#326)
- `/gaia-fitness` renders its report as a deterministic width-aware ASCII card (#320)
- TypeScript 7 readiness: `tsconfig.json` adopts `stableTypeOrdering` and `noUncheckedSideEffectImports` while still on TypeScript 6 (#331)
- `code-review-audit` runs its holistic review on Opus with a coverage-first pass that surfaces every candidate (tagged with severity and confidence) before adversarial verification filters them (#353, #354)
- `/gaia-plan` and `/gaia-spec` dispatch every subagent from a single depth-1 orchestrator, with per-bucket Haiku and Sonnet model pinning (#363)
- the `/gaia-wiki` maintenance chain moves to the same single depth-1 orchestrator topology (#364)
- skeleton-loaders: static translatable text (labels, headings, button text) must use `t()` or `<Trans>`, and skeleton containers require `role="status" aria-busy="true"` (#360)
- statusline: `/update-gaia` now precedes `/update-deps`, and the harden nudge reads `Run /gaia-harden (N recurring patterns)` (#328)
- dependency refresh: react and react-dom 19.2.7, storybook 10.4.2, axe-core 4.12.0, chromatic 17.2.0, happy-dom 20.10.1, i18next 26.3.1; the `brace-expansion` and `ws` CVE overrides are dropped (resolved natively) and the `qs` override is retained (#332, #348)
- the `react-router` group is bumped to 7.17.0 (`react-router`, `react-router-dom`, and the `@react-router/*` packages), which ships its official docs as markdown under `node_modules/react-router/docs` for local lookup
- `/update-deps` and `/update-gaia` repoint dependency-override management to `pnpm-workspace.yaml` for pnpm 11 (#334)
- react-doctor reads a single `doctor.config.jsonc`; the legacy `react-doctor.config.json` is removed from the template (#327)
- the project `CLAUDE.md` response-style guidance is scoped to conversation, with a coverage carve-out for audits, reviews, plans, and specs, and a coaching register (#358)
- `coding-guidelines` clarifies that the impossible-scenario test ban does not cover real failure modes such as non-zero exits, loop non-convergence, and network errors (#359)
- CLI internals cleanup: several dead or unwired maintainer subcommands are retired, a subcommand reachability guard rejects calls to commands the binary no longer exposes, and the CI audit gains a `--verbose` log mode (#336, #337, #338, #339, #340, #341)
- `/gaia-release` (maintainer-only) wires the `release-notes` skill into the website lockstep, overwrites the GitHub release body with the generated adopter-facing notes, and adds a docs-site version lockstep step (#318, #319)
- load-bearing wiki fetches in the instruction files are marked imperative (must-read) and deep-dive pages are tagged, tightening how the assistant pulls wiki context during a task (#361)

### Fixed

- the bare-test guard no longer false-positives on quoted prose: detection anchors to command position, so a `pnpm test` phrase inside a commit message or a `--body` string is no longer blocked, and the sibling RED-observation gate is anchored the same way (#345)
- type-only tests no longer hit an unsatisfiable TDD RED-verification gate: the signal helper classifies each test runtime vs type-only and the commit check exempts type-only tests, delegating their correctness to the `tsc` quality gate (#344)
- `/update-gaia` defers the VERSION-file bump until after the run summary prints, so an interrupted run resumes at the baseline version instead of dead-ending as already up to date (#362)
- `/update-deps` and `/update-gaia` bound their retry and heal loops to one remediation pass plus a single gate re-run, then revert and log, instead of iterating open-ended (#355)
- the autonomous `/gaia-audit` and `/gaia-fitness` re-run paths require a fresh subagent on every stateful re-run, so a resumed cycle can't silently reuse a stale in-context report (#356)
- `/update-deps` override audit adds a security-floor pin test so a CVE-pinned override is never dropped as obsolete while a live advisory remains (#348)
- maintainer-only source paths no longer leak into adopter-facing surfaces and a stale manifest is regenerated; the `/update-deps` skill drops a maintainer-only path reference absent on adopter clones (#367)
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

- replace the `/gaia <subcommand>` router with discrete `/gaia-*` slash commands (`/gaia-plan`, `/gaia-spec`, `/gaia-audit`, `/gaia-fitness`, `/gaia-forensics`, `/gaia-wiki`, `/gaia-handoff`, `/gaia-pickup`) so every workflow surfaces in autocomplete; the old space-form `/gaia <sub>` is removed, and sub-arguments are unchanged (#277)
- add /gaia-fitness to commands table (#281)

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
- `/update-gaia` merges `package.json` field-aware instead of as one opaque blob: it never touches adopter identity fields, applies only the real upstream dependency/script delta, and never re-adds a dependency the adopter removed, so a version-only release stops emitting a full-file conflict patch (#275) (#279)
- inline literal sibling-repo paths in gaia-release pushes
- add repo-scope.sh to audit-ci-tests paths filter
- the repo-scope guard strips surrounding quotes from `git -C "<path>"` and `cd '<path>'` captures, so a quoted sibling-repo push is recognized as foreign and allowed instead of denied as a home-repo push to main

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
- Serena MCP server registered by `/gaia-init` for LSP-backed code intelligence (pinned, requires `uv`); a `code-search` rule routes Claude to Serena for TS/TSX symbol queries (#82)
- dead-code detection via [knip](https://knip.dev): run `pnpm knip` after refactors or before release-candidate PRs, with a template-aware config that marks GAIA's library surface as entries so intentional exports aren't flagged (#80)

### Changed

- **BREAKING:** `/wiki-sync`, `/wiki-consolidate`, `/wiki-lint` slash commands are removed. Use `/gaia wiki sync`, `/gaia wiki consolidate`, `/gaia wiki lint` instead, or `/gaia wiki` for the full chain. Motivation: `/wiki-lint` collided with the `claude-obsidian` plugin's skill of the same name. Moving everything under the `/gaia` router namespace eliminates the collision and groups wiki maintenance with the other GAIA workflows. Hooks (`wiki-drift-check`, `wiki-commit-nudge`, `wiki-session-stop`) and statusline now point at the new names. Smoke tests under `.gaia/tests/smoke/wiki-sync/` updated. The playbooks moved from `.claude/commands/wiki-{sync,consolidate,lint}.md` to `.claude/skills/gaia/references/wiki/{sync,consolidate,lint}.md`.
- `/gaia audit` no longer covers intra-wiki duplication or broken-wikilink checks; those overlapped with `/gaia wiki consolidate` and `/gaia wiki lint`. Run `/gaia wiki` separately for wiki-internal audits.
- codify post-merge state verification + --auto vs --admin (#155)
- tighten adopter README template (#138)
- pre-launch gap fixes (CI opt-in, rollback, WSL stance) (#137)
- add manual smoke procedure for before_implement hook
- scrub fictional on_save references from smoke.md

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

[Unreleased]: https://github.com/gaia-react/gaia/compare/v1.6.1...HEAD
[1.6.1]: https://github.com/gaia-react/gaia/releases/tag/v1.6.1
[1.6.0]: https://github.com/gaia-react/gaia/releases/tag/v1.6.0
[1.5.0]: https://github.com/gaia-react/gaia/releases/tag/v1.5.0
[1.4.0]: https://github.com/gaia-react/gaia/releases/tag/v1.4.0
[1.3.5]: https://github.com/gaia-react/gaia/releases/tag/v1.3.5
[1.3.4]: https://github.com/gaia-react/gaia/releases/tag/v1.3.4
[1.3.3]: https://github.com/gaia-react/gaia/releases/tag/v1.3.3
[1.3.2]: https://github.com/gaia-react/gaia/releases/tag/v1.3.2
[1.3.1]: https://github.com/gaia-react/gaia/releases/tag/v1.3.1
[1.3.0]: https://github.com/gaia-react/gaia/releases/tag/v1.3.0
[1.2.3]: https://github.com/gaia-react/gaia/releases/tag/v1.2.3
[1.2.2]: https://github.com/gaia-react/gaia/releases/tag/v1.2.2
[1.2.1]: https://github.com/gaia-react/gaia/releases/tag/v1.2.1
[1.2.0]: https://github.com/gaia-react/gaia/releases/tag/v1.2.0
[1.1.1]: https://github.com/gaia-react/gaia/releases/tag/v1.1.1
[1.1.0]: https://github.com/gaia-react/gaia/releases/tag/v1.1.0
[1.0.5]: https://github.com/gaia-react/gaia/releases/tag/v1.0.5
[1.0.4]: https://github.com/gaia-react/gaia/releases/tag/v1.0.4
[1.0.3]: https://github.com/gaia-react/gaia/releases/tag/v1.0.3
[1.0.2]: https://github.com/gaia-react/gaia/releases/tag/v1.0.2
[1.0.1]: https://github.com/gaia-react/gaia/releases/tag/v1.0.1
[1.0.0]: https://github.com/gaia-react/gaia/releases/tag/v1.0.0
