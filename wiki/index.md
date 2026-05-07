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

> **Domain isolation:** Technical work fetches from `wiki/modules/`, `wiki/concepts/`, `wiki/decisions/`, `wiki/components/`, `wiki/flows/`, `wiki/dependencies/`. Cross-load with `wiki/entities/` only when the task genuinely spans both.

## Top-level

- [[overview]] — executive summary
- [[hot]] — recent context cache (~200 words)
- [[log]] — chronological ingest log

## Modules (architecture)

- [[Folder Structure]]
- [[Routing]]
- [[Pages]]
- [[Components]]
- [[Form Components]] — the star feature
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

## Entities

- [[GAIA]]
- [[Steven Sacks]]

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
- [[Thin Routes]]
- [[Co-located Tests Folder]]
- [[composeStory Pattern]]
- [[Dark Mode Modernization]]
- [[Quality Gate]]
- [[pnpm]]
- [[DragonScale Opt-Out]]
- [[spec-kit Extension Strategy]]

## Concepts

- [[Agentic Design]] — how GAIA implements the canonical agentic patterns and principles
- [[GAIA Philosophy]]
- [[Coding Guidelines]]
- [[Component Testing]]
- [[API Service Pattern]]
- [[Accessibility]]
- [[ESLint Fixes]]
- [[Test Runner]]
- [[Pre-commit Hooks]]
- [[Git Workflow]]
- [[PR Merge Workflow]]
- [[Task Orchestration]]
- [[Code Review Audit Agent]]
- [[Claude Hooks]]
- [[Claude Integration Conventions]] — Conventions for Claude's config surface: extension points, monorepo retrofit, service swaps, domain isolation.
- [[Claude Skills]]
- [[Release Workflow]] — Maintainer flow: `/gaia-release`, `release.yml`, tarball scrubbing, `create-gaia` bootstrapper.
- [[Update Workflow]] — Adopter flow: `/update-gaia` three-way diff, manifest classes (`owned` / `shared` / `wiki-owned`), `.gaia-merge` sidecar patches.
- [[GAIA Spec]] — `/gaia spec`: Socratic discovery wrapper around spec-kit; produces an immutable SPEC artifact and chains into `/gaia plan`.
- [[GAIA Plan]] — `/gaia plan`: feature plan + orchestrator scaffolding, clipboard handoff to a fresh session.
- [[GAIA Handoff]] — `/gaia handoff`: session handoff doc.
- [[GAIA Pickup]] — `/gaia pickup`: resume from the latest handoff.
- [[GAIA Audit]] — `/gaia audit`: two-stage knowledge-store hygiene sweep.
- [[Wiki Sync]] — `/wiki-sync` + drift hooks: keep the wiki convergent with code without spawned sub-Claudes.
- [[Wiki Consolidate]] — `/wiki-consolidate`: cross-SPEC redundancy and contradiction audit; surfaces supersession candidates, reversed decisions, near-collision slugs, and subject-orphans.
- [[Telemetry]] — three-stream telemetry (mentorship, cloud projection, analytics), `.gaia/cli/` workspace, `.gaia/cli/gaia` bundled binary, profile computation, adaptation injection.
- [[Serena Integration]] — Serena handles live code; the wiki handles institutional memory.
- [[Chromatic Opt-Out]]

## Meta

- [[README]] — vault schema, mode declaration, conventions
- [[dashboard]]
- [[lint-report-2026-05-07]]
- [[consolidate-report-2026-05-07]]
- [[lint-report-2026-05-06]]
- [[lint-report-2026-05-04]]
- [[lint-report-2026-05-03]]
- [[lint-report-2026-05-01]]
- [[lint-report-2026-04-27]]
- [[lint-report-2026-04-26]]
- [[lint-report-2026-04-21]]
