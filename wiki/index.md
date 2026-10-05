---
type: meta
title: Index
status: active
created: 2026-04-20
updated: 2026-10-03
tags: [meta]
---

# Index

Master catalog of every page in the wiki. Newly created pages must be added here.

> **Domain isolation:** Technical work fetches from `wiki/modules/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/components/`, `wiki/flows/`, `wiki/dependencies/`. Only pull from other domains when the task genuinely spans both.

## Top-level

- [[overview]]: executive summary
- [[hot]]: recent context cache (~200 words)
- [[log]]: chronological ingest log
- [[README]]: vault schema, mode declaration, conventions

## Modules (architecture)

- [[Folder Structure]]
- [[Routing]]
- [[Pages]]
- [[Components]]
- [[Form Components]]: the star feature
- [[Services]]
- [[Sessions]]
- [[State]]
- [[Middleware]]
- [[Hooks]]
- [[Utils]]
- [[Styles]]
- [[i18n]]
- [[Testing]]
- [[Storybook Stories]]
- [[MSW Handlers]]
- [[Claude Integration]]
- [[CLI Scaffolding]]: component/hook/route/service generators

## Components


## Flows

- [[Theme Flow]]
- [[Language Flow]]
- [[Form Submit Flow]]

<!-- gaia:maintainer-only:start -->

## Entities

- [[GAIA]]
- [[Steven Sacks]]
<!-- gaia:maintainer-only:end -->

## Dependencies

- [[React Router]]
- [[fs-routes]]
- [[remix-i18next]]
- [[remix-toast]]
- [[remix-utils]]: per-helper adopt-vs-hand-roll decision map.
- [[Serena]]
- [[spec-kit]]
- [[Conform]]
- [[Zod]]
- [[Ky]]
- [[i18next]]
- [[Tailwind]]
- [[lucide-react]]
- [[shadcn]]
- [[gaia-lint]]
- [[knip]]
- [[react-doctor]]: React security/perf/a11y scanner (`npx`); advisory, single canonical `frontend/doctor.config.ts`, duplicate-config guard.
- [[pnpm-audit]]: dependency-CVE advisory oracle (`pnpm audit --json`); read-only, advisory, baseline-scoped.
- [[pnpm-overrides]]: applying `overrides`/security-floor changes needs `pnpm dedupe`; `pnpm install` short-circuits "Already up to date".
- [[Vitest]]
- [[React Testing Library]]: superseded; GAIA ships no React Testing Library, see [[Stories as Tests]].
- [[Playwright]]
- [[playwright-cli]]: global `@playwright/cli` install, the scoped `npx` fallback, the deprecated unscoped package trap, and which invocation wins over the vendored skill's own advice.
- [[Chromatic]]
- [[Storybook]]
- [[MSW]]
- [[lint-staged]]

## Decisions (ADRs)

- [[shadcn Component Layer]]: GAIA's component layer, the vendored-ui policy.
- [[React Compiler]]: React Compiler runs by default in build, dev, Vitest and Storybook from one shared module; thresholds, adopter steps and rollback.
- [[TypeScript Language Files]]
- [[TypeScript 7 Readiness]]: tsconfig pre-adopts the TS7 strict baseline; the 7.1 upgrade is a dep swap gated on typescript-eslint's programmatic API.
- [[Thin Routes]]
- [[Co-located Tests Folder]]
- [[composeStory Pattern]]: superseded by [[Stories as Tests]]; keeps the stub-over-mock reasoning.
- [[Stories as Tests]]: a story with a `play` is the component test, run by Vitest in headless Chromium; the three Vitest projects, what counts as a test to the harness, the CSF shapes and the exit-7 refusal, and the `languages` prop and router stub conventions.
- [[Dark Mode Modernization]]
- [[Content Security Policy]]: per-request nonce CSP; Report-Only pending an upstream React Router fix; documents the `unsafe-inline` and no-`report-uri` trade-offs.
- [[Dispatched-Check Rollup via Polling]]: in-loop pollers stamp dispatched-workflow jobs via the Checks API so they land in `statusCheckRollup`; documents why a `workflow_run` listener is not viable under `GITHUB_TOKEN`.
- [[Composite Action Step Timeouts]]: Node-provisioning steps are bounded by their owning job's `timeout-minutes`; a step-level cap is a per-workflow choice, not a rule.
- [[Code Audit Team]]: config-driven auditor roster + dispatch resolver; AND-aggregation across dispatched members at the merge gate.
- [[Deliberate Configuration Asymmetries]]: config that differs from its siblings on purpose; the `.claude/hooks/` Edit carve-out, the skill `model:` pinning criterion, the non-opt-outable update check, and why the agent-teams flag is not enabled.
<!-- gaia:maintainer-only:start -->
- [[CLI-Binary-Split]]
- [[Folding Shell Scripts into the CLI Binary]]: considered and declined; the manifest is a never-merged sentinel and the fold is a delete, so it cannot deliver simpler diffs.
- [[Forensics Triage Workflow]]
- [[Sharded CI Test Matrix]]: the `GAIA: Audit CI Tests` workflow as a matrix fan-out plus a thin aggregator; the zero-headroom 2-hop cap arithmetic any restructuring hits first, how to measure this workflow without the two traps, and the levers already weighed.
- [[Shell Guard Fixture Discrimination]]: fixture-region discrimination plus a suppression pragma so the shell guards can read `*.bats` without flagging their own suites' deliberately broken fixtures.
- [[Local Test Runtime]]: `shell-lint.sh`'s own concurrency budget; the full bats corpus as a decided non-goal; the awk interpreter resolver's stated non-claim.
- [[Workflow Naming Convention]]: GAIA: prefix for maintainer-only workflows, sentence-case Tool (scope) job names, (advisory) on non-blocking PR jobs; the prefix is tied to the release-exclude derive by a test.
<!-- gaia:maintainer-only:end -->
- [[Quality Gate]]
- [[Naming Conventions]]: Conventional Commits for commits and PR titles, canonical branch names, and the worktree branch rename; where the convention is read and what enforces it.
- [[pnpm]]
- [[DragonScale Opt-Out]]
- [[Vendored Third-Party Skills]]: third-party skills are vendored byte-identical with a GAIA-owned version marker; GAIA guidance lives outside the vendored folder; updates re-vendor.
- [[spec-kit Extension Strategy]]
- [[Wiki Management]]: wiki primitives, state file, deterministic classification
- [[Claude Integration Fitness]]: check taxonomy + F-to-A+ grading + triage/heal protocol run by `/gaia-fitness`.
- [[TDD RED Verification]]: mechanical enforcement that a new test was observed failing before commit; RED-observation ledger + two hooks.
- [[Determinism Classifier]]: per-file AST signal labelling a source file strict (RED-gated) or emergent (advisory audit); versioned DOM-API allowlist, file-granular.
- [[Worthiness Audit]]: advisory two-axis (honesty + worthiness) review of emergent-surface tests; fresh-context reviewer proposes keep/fix/delete, deletes human-gated, audit ledger sibling to the RED ledger; stories audited as emergent tests; two-tier end-of-task surfacing.
- [[Worthiness Presence Gate]]: merge-time `gh pr merge` hook requiring each changed emergent test to carry a worthiness-ledger line matching its current content; presence + signal match only (never the verdict), scoped to the PR's changed emergent tests, fail-open.
<!-- gaia:maintainer-only:start -->
- [[Dependabot as a Data Source]]: Dependabot alerts feed `/update-deps`, which resolves advisories through the local quality gate; GAIA renders no Dependabot config and keeps automated security fixes off.
- [[Dependabot Security Updates]]: superseded opt-in design for security-update pull requests, kept as the record of what it chose and why it was reversed.
- [[Bundle-time Scrub]]: marker-strip + leak-check + runtime-deps; closes the audit-round loop with build-time enforcement.
<!-- gaia:maintainer-only:end -->

## Concepts

- [[GAIA Philosophy]]
- [[Coding Guidelines]]
- [[Design System]]
- [[Component Testing]]
- [[API Service Pattern]]
- [[Accessibility]]
- [[ESLint Fixes]]
- [[Forensics]]: read-only bug-report bridge with redaction and classification
- [[Test Runner]]
- [[Pre-commit Hooks]]
- [[Git Workflow]]
- [[PR Merge Workflow]]
- [[Task Orchestration]]
- [[Workflow Doctrine]]: the one execution doctrine (roles, git ownership, checkpoint and resume, model choice) and the hook that injects it on a branch.
- [[Code Review Audit Agent]]
- [[Registering a Code Audit Team Member]]: how-to for adding a new roster member: agent def, roster entry, machinery wiring, finding_class bucket, recurrence-tally integration, and the local-gate checklist.
- [[Audit Disposition and Debt Fix]]: forced disposition of out-of-scope audit findings as deduped tech-debt issues; security-class divert; the /gaia-debt fix loop (single issue, recommended related batch, or operator-named batch, isolated per the team's git isolation policy) and statusline nudge; /gaia-residue drains the accepted-residual record the same audit leaves unfiled.
- [[GitHub Labels]]: the label registry at `.gaia/labels.json`, the palette rule, the generated page, and `gaia labels sync` / `docs`.
- [[Policy-Memory Loop]]: prune-first self-improvement; recurring finding_class -> statusline nudge -> `/gaia-harden` -> path-scoped rule -> `/gaia-audit` prunes only on obsolescence/redundancy/supersession/duplication.
- [[Incremental CI Skipping]]: required checks skip when the delta since they last passed green has no relevant files; `resolve-check-base.sh` / `resolve-audit-base.sh`.
- [[Claude Hooks]]
- [[GAIA Scripts]]: the index of `.gaia/scripts/`: one row per root file with its family, ship status, invoker, and what it is, plus the subdirectories and why the directory stays flat.
- [[OS Sandbox]]: two-tier sandbox-enablement preference (owner recommends, each machine resolves) and the honest `.env` deny-merge boundary.
- [[Project Config]]: `.gaia/project.json`, the committed team-shared settings file (sandbox recommendation, isolation policy), its writers and readers, and why `/update-gaia` never touches it.
- [[Package Descriptor]]: the package registry `.gaia/packages.json` and per-package `gaia.package.json`; who reads them, the fail-closed rule, and the frontend launch scope.
- [[Claude Integration Conventions]]: Conventions for Claude's config surface: extension points, monorepo retrofit, service swaps, domain isolation.
- [[Local Working State]]: the gitignored `.gaia/local/` working-state folder and its pointer to the state registry; the SessionStart janitor's wiki-landing catch-up.
- [[Worktrees]]: the worktree model a feature author needs: tree identity from the acting event's working directory, the single main-checkout resolver, the single `.gaia/local` symlink, and the state registry's four scopes.
- [[Claude Skills]]
- [[Update Workflow]]: `/update-gaia` three-way diff, manifest classes (`owned` / `shared` / `wiki-owned`), `.gaia-merge` sidecar patches.
- [[Generated Regions]]: marker-delimited spans inside shipped files a shipped command regenerates; the region-aware merge oracle, the regeneration runner, and the trust model they operate inside.
<!-- gaia:maintainer-only:start -->
- [[Release Workflow]]: Maintainer flow: `/gaia-release`, `release.yml`, tarball scrubbing, `create-gaia` bootstrapper.
- [[Release-Notes]]
<!-- gaia:maintainer-only:end -->
- [[GAIA Spec]]: `/gaia-spec`: Socratic discovery wrapper around spec-kit; produces an immutable SPEC artifact and stops, printing a `/gaia-plan` prompt for a fresh session (a guard enforces the stop).
- [[GAIA Plan]]: `/gaia-plan`: feature plan + orchestrator scaffolding, clipboard handoff to a fresh session.
- [[GAIA Handoff]]: `/gaia-handoff`: session handoff doc.
- [[GAIA Pickup]]: `/gaia-pickup`: resume from the latest handoff.
- [[GAIA Audit]]: `/gaia-audit`: two-stage knowledge-store hygiene sweep.
- [[Wiki Sync]]: `/gaia-wiki sync` and the statusline drift nudge: keep the wiki convergent with code without spawned sub-Claudes.
- [[Wiki Consolidate]]: `/gaia-wiki consolidate`: cross-SPEC redundancy and contradiction audit; surfaces supersession candidates, reversed decisions, near-collision slugs, and subject-orphans.
- [[GAIA Init Workflow]]: `/gaia init` subcommands: strip-branding, configure-i18n, rename, wire-statusline, write-project-config, finalize, resume.
- [[GAIA CLI]]: the `.gaia/cli/` workspace, the `.gaia/cli/gaia` bundled binary, and the adoption ping (`gaia ping`) sent on `/gaia-init`, `/setup-gaia`, and `/update-gaia` completion.
- [[Token Cost Readout]]: per-action token-to-dollar pricing off one shared pricing lib; the `by_model` field, the machine-local rate table seeded from the distributed `token-rates.json` and healed from the public feed, the roll-up's read-time dollar block, and the tally's own per-phase `dollars` snapshot in the `cost.json` sidecar record, each with its degrade markers.
- [[Cost Data Contract]]: the `cost.jsonl` record schema (every field + type), the execute aggregation rule, the schema_version evolution rule, the retention-at-merge rule, and `token-tally.sh` as the single source of truth for the emitted schema.
- [[Usage Ledger]]: the append-only per-message usage store under `.gaia/local/telemetry/`, separate from `cost.jsonl`; read-time attribution through bindings and a lineage graph, the per-PR block at `gh pr merge`, initiative and reconcile readouts, and `usage.sh`.
- [[Serena Integration]]: Serena handles live code; the wiki handles institutional memory.
- [[React Perf Diagnostic]]: `/gaia-react-perf`: measure-only runtime render-performance diagnostic built on bippy; capture -> reduce CLI -> ranked `memoDefeated` findings with a structural-fix cross-reference.
- [[Chromatic Opt-Out]]

<!-- gaia:maintainer-only:start -->

## Meta

- [[dashboard]]
<!-- gaia:maintainer-only:end -->
