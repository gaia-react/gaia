---
type: meta
title: Log
status: active
created: 2026-06-12
updated: 2026-06-12
tags: [meta, log]
---

# Log

## [Unreleased]

- 2026-06-23 e27a916 WORTHY - feat(scaffold): comma-bearing prop types in component --props → scaffold CLI improvement, no wiki page
- 2026-06-23 c25f836 WORTHY - fix(deps): pin nested vite >=7.3.5 (GHSA-fx2h-pf6j-xcff) → CVE override, pnpm-overrides pattern already documented
- 2026-06-23 7ef235a WORTHY - feat(tdd): SPEC-006 Phase 1-3 → wiki/decisions/{Determinism Classifier,Worthiness Audit,Worthiness Presence Gate}.md created
- 2026-06-23 f5363ff WORTHY - feat(audit): per-author code-review-audit mode → wiki/concepts/PR Merge Workflow.md updated
- 2026-06-23 0a99801 WORTHY - docs(react-code): expand skill trigger for dependency-vs-platform decisions → skill files only
- 2026-06-23 517ce61 WORTHY - docs(skills): harden efficacy lens + react-code platform-first ladder → skill files only
- 2026-06-23 c0b6956 WORTHY - docs(contributing): issue-claiming policy + /gaia-forensics routing → CONTRIBUTING.md only
- 2026-06-23 b79d350 WORTHY - fix(playwright): cold dev-server hydration race → wiki/dependencies/Playwright.md updated
- 2026-06-23 c63e5fa WORTHY - ci(tests): react-doctor config guard folded into Tests workflow → wiki/dependencies/react-doctor.md updated
- 2026-06-23 a59092c WORTHY - fix(scaffold): route cwd + i18n/naming/dry-run defects → wiki/modules/Routing.md updated
- 2026-06-23 4c3dcc4 WORTHY - docs(wiki): self-heal restore-set reset guard → wiki/concepts/Code Review Audit CI.md updated
- 2026-06-23 3c2732a WORTHY - fix(react-doctor): consolidate doctor.config.ts + duplicate-config guard → wiki/dependencies/react-doctor.md created
- 2026-06-23 30656516 WORTHY - fix(audit-ci): self-heal restore-set reset → documented in commit 4c3dcc4 (Code Review Audit CI.md)
- 2026-06-23 e7ac2e7 WORTHY - fix(deps): undici + qs security-floor overrides → CVE fix, pnpm-overrides pattern already documented
- 2026-06-23 32d55e5 SKIP - docs: prose-only lint-rules bullet drop, no wiki-relevant behavior
- 2026-06-23 0c8cf98 WORTHY - docs(typescript): Zod LLM docs directive → skill files only, no wiki page needed
- 2026-06-23 959a1c1 WORTHY - fix(update-deps): pnpm dedupe for overrides → wiki/dependencies/pnpm-overrides.md created
- 2026-06-23 6c7b9ae SKIP - chore(deps): 20 minor/patch bumps, no behavior change
- 2026-06-23 e2c00d3 WORTHY - feat(wiki): PostCompact hot-cache hooks → wiki/concepts/Claude Hooks.md updated
- 2026-06-23 528f5ee WORTHY - docs(gaia-release): fix stale lockstep file refs in gaia-release command → command file only
- 2026-06-23 84c7a02 WORTHY - fix(release): runtime-deps allowlist for audit-workflow path constant → internal CLI fix, no wiki page
- 2026-06-23 fdb439e SKIP - chore(release): v1.6.1 release plumbing
- `/update-deps` override audit re-resolves with `pnpm dedupe`, not `pnpm install` (which short-circuits "Already up to date" on an overrides-only change and leaves a security floor unapplied), and now asserts the lockfile `overrides:` block matches `pnpm-workspace.yaml` before finishing. New page [[pnpm-overrides]] documents the gotcha; [[pnpm-audit]] and [[pnpm]] cross-link it.

## [v1.6.1] 2026-06-12 | Released

See CHANGELOG.md for details.
