---
type: concept
title: GAIA Spec
status: active
created: 2026-05-06
updated: 2026-05-06
tags: [concept, claude, skill, orchestration, spec-kit]
---

# GAIA Spec

`/gaia spec [description]` is GAIA's Socratic discovery wrapper around [[spec-kit]]. It produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN/SPEC.md` and chains into [[GAIA Plan]] on confirmation. The skill body lives at `.claude/skills/gaia/references/spec.md` (dispatched by the `/gaia` router skill).

The wrapper is implemented as a spec-kit extension plus preset; the architectural rationale (why extension+preset, the `wrap` strategy, version-pin range, hook semantics) is in [[spec-kit Extension Strategy]].

## Hard constraints

- **No machine-local memory for project decisions.** The skill must never write to `~/.claude/projects/.../memory/`. Project-relevant decisions belong only in the SPEC artifact, the wiki, or `.claude/rules/`.
- **Write-surface allowlist.** Every write during a session lands in `.gaia/local/specs/**`, `.specify/**`, `.gaia/local/cache/**`, or `.gaia/local/telemetry/**`. Source files are off-limits. The `after_specify` lint command audits this.
- **One question at a time.** Closed-set questions go through `AskUserQuestion` with options ordered: recommended FIRST, alternatives, `Other`, `Discuss this`. Open-ended questions use plain prompts.
- **Two-gate ceremony.** Gate 1 confirms intent + UATs in plain English before the clarify loop. Gate 2 confirms the rendered artifact before save. No silent advances.
- **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates. Never punt research to the human.

## Steps

1. **Get description.** Use `$ARGUMENTS` if non-empty; otherwise ask "What do you want to spec?" and wait.
2. **Resume-vs-start prompt.** `lib/spec-allocator.sh in_progress` reports any open SPEC; user picks Resume or Start new. No silent overwrite, no silent fresh allocation.
3. **`/speckit.specify`.** Spec-kit fires the `before_specify` hook (constitution-check + version-pin drift detection) automatically, then runs core. The GAIA preset replaces the core template under `strategy: wrap` so the artifact is GAIA-shaped (frontmatter, immutable flag, frozen `SPEC-NNN` id) and lands at `.gaia/local/specs/SPEC-NNN/SPEC.md`.
4. **Gate 1 — shape confirmation.** Present `intent` + UATs in plain English. On confirmation, cache the gate-1 snapshot to `.gaia/local/cache/gate1-<spec_id>.json` (the `after_clarify` hook reads this to detect scope drift in gate 2).
5. **`/speckit.clarify` (Socratic loop).** Sequential coverage-based questioning. Closed-set goes through `AskUserQuestion`; open-ended uses plain prompts; `Discuss this` drops into plain Q&A and records the settled outcome. Per-topic exhaustion checkpoint forbids silent topic advance. Research questions dispatch a `general-purpose` Agent — never punt to the human.
6. **`after_clarify` hook.** Spec-kit fires `/speckit-gaia-self-review`, which audits drift (vs. the gate-1 snapshot), placeholders, ambiguity, and pending clarifications. Save remains blocked while any pending item is unresolved (block-or-defer prompt).
7. **Gate 2 — artifact confirmation.** Render the full draft and present for review. Plain prompt, not `AskUserQuestion`. Revise to convergence, then proceed.
8. **Save** to `.gaia/local/specs/SPEC-NNN/SPEC.md`. The folder is the archival unit. Sibling artifacts (reports, evidence) live beside `SPEC.md` in the same folder; a flat `SPEC-NNN-<rest>.md` file maps to `SPEC-NNN/<REST>.md` (remainder uppercased, hyphens kept). `lib/spec-folderize.sh` applies this mapping for any legacy flat files.
9. **`after_specify` hook.** Spec-kit fires `/speckit-gaia-lint`, which runs `lib/lint.sh` (frontmatter, frozen UAT-NNN ids, no placeholders, write-allowlist audit). For mutations of an already-saved SPEC, the lint enforces the explicit reopen ceremony — `## Reopen rationale` and `## UAT diff` sections required.
10. **Optional GH Issue mirror.** `lib/gh-mirror.sh` creates an Issue if `gh auth status` succeeds, the repo has Issues enabled, and the viewer has write/admin permission. Otherwise appends a skip record to `.gaia/local/telemetry/gh-mirror.jsonl` and exits 0. Absence never blocks save.
11. **Inline chain-trigger to `/gaia plan`.** No `on_save` hook exists in spec-kit; the chain lives here, inline. `AskUserQuestion` offers "Yes, trigger /gaia plan (Recommended)" or "No, defer". On Yes, dispatch `/gaia plan` with the SPEC path; on No, stop.

## UAT divergence contract

Auto-generated Playwright specs (written by the `before_implement` hook via `lib/uat-write.sh`) carry an inline header defining the cosmetic-vs-logical boundary:

- **Cosmetic divergence** (selector text, button labels, copy, URL slugs, layout assertions): editable by the implementer without reopening the SPEC.
- **Logical divergence** (user flow, success criteria, error branches, preconditions, post-state): forbidden. Implementer must raise the divergence; the SPEC is reopened and the UAT rewritten before re-running `/speckit-implement`.

## Pairs with

- [[spec-kit Extension Strategy]] — the architectural decision that produced this workflow.
- [[spec-kit]] — the underlying engine; pin, install, version-drift detection.
- [[GAIA Plan]] — the downstream chain target.
- [[Task Orchestration]] — what `/gaia plan` produces.
