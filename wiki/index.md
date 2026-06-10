---
type: meta
title: Index
status: active
created: 2026-04-20
updated: 2026-05-07
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

## Components (Form deep dives)

- [[Form Field]]
- [[Form Text Inputs]]
- [[Form Select]]
- [[Form YearMonthDay]]
- [[Form Choices]]
- [[Form Layout]]

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

- [[React Router 7]]
- [[remix-flat-routes]]
- [[remix-i18next]]
- [[remix-toast]]
- [[Serena]]
- [[spec-kit]]
- [[Conform]]
- [[Zod]]
- [[Ky]]
- [[i18next]]
- [[Tailwind]]
- [[react-icons]]
- [[gaia-lint]]
- [[knip]]
- [[pnpm-audit]]: dependency-CVE advisory oracle (`pnpm audit --json`); read-only, advisory, baseline-scoped.
- [[Vitest]]
- [[React Testing Library]]
- [[Playwright]]
- [[Chromatic]]
- [[Storybook]]
- [[MSW]]
- [[Husky]]

## Decisions (ADRs)

- [[No Component Library]]
- [[TypeScript Language Files]]
- [[TypeScript 7 Readiness]]: tsconfig pre-adopts the TS7 strict baseline; the 7.1 upgrade is a dep swap gated on typescript-eslint's programmatic API.
- [[Thin Routes]]
- [[Co-located Tests Folder]]
- [[composeStory Pattern]]
- [[Dark Mode Modernization]]
- [[Content Security Policy]]: per-request nonce CSP; Report-Only pending an upstream React Router fix; documents the `unsafe-inline` and no-`report-uri` trade-offs.
- [[Dispatched-Check Rollup via Polling]]: in-loop pollers stamp dispatched-workflow jobs via the Checks API so they land in `statusCheckRollup`; documents why a `workflow_run` listener is not viable under `GITHUB_TOKEN`.
<!-- gaia:maintainer-only:start -->
- [[Forensics Triage Workflow]]
<!-- gaia:maintainer-only:end -->
- [[Quality Gate]]
- [[pnpm]]
- [[DragonScale Opt-Out]]
- [[spec-kit Extension Strategy]]
- [[Wiki Management]]: wiki primitives, state file, deterministic classification
- [[Claude Integration Fitness]]: check taxonomy + F-to-A+ grading + triage/heal protocol run by `/gaia-fitness`.
- [[TDD RED Verification]]: mechanical enforcement that a new test was observed failing before commit; RED-observation ledger + two hooks.
<!-- gaia:maintainer-only:start -->
- [[Bundle-time Scrub]]: marker-strip + leak-check + runtime-deps; closes the audit-round loop with build-time enforcement.
<!-- gaia:maintainer-only:end -->

## Concepts

- [[Agentic Design]]: how GAIA implements the canonical agentic patterns and principles
- [[GAIA Philosophy]]
- [[Coding Guidelines]]
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
- [[Code Review Audit Agent]]
- [[Code Review Audit CI]]: pre-merge GitHub Actions gate; `GAIA-Audit:` trailer skip logic; adopter-tunable knobs at `.gaia/audit-ci.yml`.
- [[Policy-Memory Loop]]: prune-first self-improvement; recurring finding_class -> statusline nudge -> `/gaia-harden` -> path-scoped rule -> `/gaia-audit` prunes only on obsolescence/redundancy/supersession/duplication.
- [[Incremental CI Skipping]]: required checks skip when the delta since they last passed green has no relevant files; `resolve-check-base.sh` / `resolve-audit-base.sh`.
- [[Claude Hooks]]
- [[Claude Integration Conventions]]: Conventions for Claude's config surface: extension points, monorepo retrofit, service swaps, domain isolation.
- [[Claude Skills]]
- [[Update Workflow]]: `/update-gaia` three-way diff, manifest classes (`owned` / `shared` / `wiki-owned`), `.gaia-merge` sidecar patches.
<!-- gaia:maintainer-only:start -->
- [[Release Workflow]]: Maintainer flow: `/gaia-release`, `release.yml`, tarball scrubbing, `create-gaia` bootstrapper.
- [[Release-Notes]]
<!-- gaia:maintainer-only:end -->
- [[GAIA Spec]]: `/gaia-spec`: Socratic discovery wrapper around spec-kit; produces an immutable SPEC artifact and chains into `/gaia-plan`.
- [[GAIA Plan]]: `/gaia-plan`: feature plan + orchestrator scaffolding, clipboard handoff to a fresh session.
- [[GAIA Handoff]]: `/gaia-handoff`: session handoff doc.
- [[GAIA Pickup]]: `/gaia-pickup`: resume from the latest handoff.
- [[GAIA Audit]]: `/gaia-audit`: two-stage knowledge-store hygiene sweep.
- [[Wiki Sync]]: `/gaia-wiki sync` + drift hooks: keep the wiki convergent with code without spawned sub-Claudes.
- [[Wiki Consolidate]]: `/gaia-wiki consolidate`: cross-SPEC redundancy and contradiction audit; surfaces supersession candidates, reversed decisions, near-collision slugs, and subject-orphans.
- [[GAIA Init Workflow]]: `/gaia init` subcommands: strip-branding, configure-i18n, rename, wire-statusline, finalize, resume.
- [[Telemetry]]: three-stream telemetry (mentorship, cloud projection, analytics), `.gaia/cli/` workspace, `.gaia/cli/gaia` bundled binary, profile computation, adaptation injection.
- [[Serena Integration]]: Serena handles live code; the wiki handles institutional memory.
- [[Chromatic Opt-Out]]

<!-- gaia:maintainer-only:start -->

## Meta

- [[dashboard]]
<!-- gaia:maintainer-only:end -->
