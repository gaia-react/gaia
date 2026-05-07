---
type: meta
title: Log
status: active
created: 2026-05-04
updated: 2026-05-07
tags: [meta, log]
---

# Log

## [Unreleased]

- 2026-05-07 868f05b - SKIP: docs(wiki): scrub UAT and SPEC-NNN references from body prose (wiki maintenance, no architectural change)
- 2026-05-07 ce6bc10 - SKIP: docs(rules): wiki-style — present tense rules already committed; no wiki narrative update needed
- 2026-05-07 d886b5c - WORTHY: docs(plan): add SUMMARY.md findings ledger to orchestrator contract → wiki/concepts/Task Orchestration.md
- 2026-05-07 df25fee - SKIP: fix(statusline): shorten /setup-gaia indicator text (UI-only change)
- 2026-05-07 8c9b0ec - WORTHY: feat: clone-setup gate, mentorship rule relocation, wiki primitive expansions → wiki/hot.md, wiki/index.md
- 2026-05-07 d238697 - WORTHY: feat(cli): gaia init subcommands (strip-branding, configure-i18n, rename, wire-statusline, finalize, resume) → wiki/concepts/Init Workflow.md (new), wiki/index.md
- 2026-05-07 fc69dde - WORTHY: feat(cli): gaia release namespace (preflight, bump, changelog, scrub-wiki, manifest, commit-and-tag) → wiki/concepts/Release Workflow.md, wiki/index.md
- 2026-05-07 71674d7 - WORTHY: feat(cli): gaia update merge — three-way file compare with manifest classes → wiki/concepts/Update Merge.md (new), wiki/index.md
- 2026-05-07 3704e6c - WORTHY: feat(cli): gaia wiki sync land — deterministic branch-aware push → wiki/concepts/Wiki Sync.md
- 2026-05-07 4e85e08 - SKIP: refactor(commands): wire wiki-sync, wiki-lint, wiki-consolidate (implementation plumbing; concepts already documented)
- 2026-05-07 a3f2a0c - WORTHY: feat(cli): wiki primitives (state, commit-classify, state-bump, log-prepend, page-index, orphans, near-collisions) → wiki/concepts/Wiki Sync.md, wiki/decisions/Wiki Management.md (new)
- 2026-05-07 0a443c1 - WORTHY: feat(cli): scaffold component/hook/route/service subcommands → wiki/modules/CLI Scaffolding.md (new), wiki/index.md
- 2026-05-07 86db352 - WORTHY: feat(cli): scaffold shared infrastructure (template loader, barrel insert) → wiki/modules/CLI Scaffolding.md
- 2026-05-07 3da4cc3 - SKIP: chore(claude): quick wins (model swaps, hook simplifications, playwright split; no architectural change)
- 2026-05-07 2b57eed - SKIP: chore(deps): bump vite 8.0.10 → 8.0.11; clamp /update-deps Wave B (dependency maintenance)
- 2026-05-07 5847b5b - SKIP: chore(deps): bump ulid 2 → 3, +11 minor/patch (dependency maintenance)
- 2026-05-07 ebaaec6 - WORTHY: chore(cli): relocate to .gaia/cli, ship as bundled binary, scrub internal refs → wiki/concepts/CLI Architecture.md (updated), wiki/index.md
- 2026-05-07 54d8b4b - SKIP: wiki: consolidate + lint reports (meta audit output)
- 2026-05-07 320335e - WORTHY: SPEC-001 telemetry v1 — gaia-cli/ workspace, three-stream architecture, mentorship opt-in, profile detection, adaptation injection → wiki/concepts/Telemetry.md (new), wiki/index.md
- 2026-05-07 b27f060 - SKIP: README-only update (no architectural decision)
- 2026-05-07 5ddfe48 - SKIP: wiki already updated in-commit (wiki/dependencies/Husky.md updated for lint-staged v17 + .lintstagedrc.json rename in the same commit); react-router + other bumps are version-only
- 2026-05-07 dab5338 - SKIP: wiki sync + lint fixes already landed in-commit (squash PR included wiki: sync through f54f730 and wiki: lint fixes sub-commits)
- 2026-05-06 f54f730 - WORTHY: /wiki-consolidate command + consolidation gate in /wiki-sync + state schema change → wiki/concepts/Wiki Consolidate.md (new), wiki/concepts/Wiki Sync.md, wiki/index.md
- 2026-05-06 7dd6e44 - SKIP: /gaia plan + /gaia spec skill refactor (implementation details in skill refs; user-facing wiki surface unchanged)
- 2026-05-06 7a2c8fb - SKIP: wiki pages updated in-commit (gaia state path .claude/ → .gaia/local/; all wiki edits landed in the commit)
- 2026-05-06 114b5b2 - WORTHY: .claude/rules/_internal/ + .specify/extensions/gaia/test/ + .gaia/local/ added to release-exclude → wiki/concepts/Release Workflow.md
- 2026-05-06 57671bf - SKIP: tree READMEs + inventory audit (docs-only; no new architectural decision)
- 2026-05-06 c40fe5a - SKIP: Serena handles inventory — internal test tree reorganization (.specify/ + .claude-tests/); no new wiki concept
- 2026-05-06 6a2be93 - SKIP: docs-only (manual smoke procedure for before_implement hook; no new wiki concept)
- 2026-05-06 b9f3818 - SKIP: test-only (wiki-promote smoke harness)
- 2026-05-06 c4748ca - SKIP: Serena handles inventory — wire before_implement hook into extension.yml; no new wiki concept
- 2026-05-06 3cee28d - SKIP: Serena handles inventory — wiki-promote handoff + revised-contracts amendment in .specify/; no new wiki concept
- 2026-05-06 10945b8 - SKIP: Serena handles inventory — before_implement UAT renderer in .specify/; no new wiki concept
- 2026-05-06 71c9d27 - SKIP: Serena handles inventory — wiki-promote routing + page render in .specify/; no new wiki concept
- 2026-05-06 d7a0aa6 - SKIP: Serena handles inventory — wiki-promote PR-merge detection in .specify/; no new wiki concept
- 2026-05-06 ce9ced2 - WORTHY: UAT divergence policy rule (.claude/rules/uat-divergence.md); cosmetic-vs-logical contract for Playwright UATs → wiki/concepts/GAIA Spec.md
- 2026-05-06 cfed5a5 - SKIP: Serena handles inventory — wiki-promote manifest entry in .specify/; no new wiki concept
- 2026-05-06 3cb80a6 - SKIP: bug fix in spec-kit version-check.sh (exclusive ceiling enforcement); no architectural decision
- 2026-05-06 4d7a979 - SKIP: docs-only (scrub fictional on_save references from smoke.md)
- 2026-05-06 2e5ef3b - SKIP: style (lint+prettier sweep)
- 2026-05-06 84e1a6d - SKIP: wiki: prefix (wiki sync commit itself)
- 2026-05-06 ef53be1 - WORTHY: gaia-init installs spec-kit + GAIA extension + preset → wiki/decisions/spec-kit Extension Strategy.md, wiki/dependencies/spec-kit.md
- 2026-05-06 24f694b - SKIP: test-only (UAT evidence map); architecture captured in wiki/decisions/spec-kit Extension Strategy.md
- 2026-05-06 d5f7b6d - SKIP: test-only (sandbox v2 validation transcript); architecture captured in wiki/decisions/spec-kit Extension Strategy.md
- 2026-05-06 22fbcc0 - WORTHY: real spec-kit extension + preset for GAIA → wiki/concepts/GAIA Spec.md, wiki/decisions/spec-kit Extension Strategy.md
- 2026-05-06 05204a2 - WORTHY: salvaged GAIA wrapper scaffold from PR #84 → folded into wiki/concepts/GAIA Spec.md
- 2026-05-06 37be294 - SKIP: pure formatting (lint --fix tailwind class ordering)
- 2026-05-06 dc7e8d5 - SKIP: gitignore tweak; SPEC-002 architecture lives in subsequent commits
- 2026-05-06 0f64c77 - WORTHY: code-review-audit + wiki integration of Serena/knip → existing wiki/dependencies pages already current
- 2026-05-06 db90e9c - WORTHY: Serena MCP integration → wiki/dependencies/Serena.md, wiki/concepts/Serena Integration.md (already landed in commit)
- 2026-05-06 806d59b - SKIP: gitignore tweak (.smoke)
- 2026-05-06 f55799a - SKIP: version bump only (zod 4.4.2 → 4.4.3)
- 2026-05-06 7b4f9f0 - WORTHY: knip dead-code detection → wiki/dependencies/knip.md (already landed in commit)
- 2026-05-06 5a4d4fc - SKIP: version bumps only (no add/remove/swap)
- 2026-05-06 5f584af - SKIP: chore(release) v1.0.5

## [v1.0.5] 2026-05-04 | Released

See CHANGELOG.md for details.
