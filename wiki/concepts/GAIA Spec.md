---
type: concept
title: GAIA Spec
status: active
created: 2026-05-06
updated: 2026-06-24
tags: [concept, claude, skill, orchestration, spec-kit]
---

# GAIA Spec

`/gaia-spec [description]` is GAIA's Socratic discovery wrapper around [[spec-kit]]. It produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN/SPEC.md` and chains into [[GAIA Plan]] on confirmation. The skill body lives at `.claude/skills/gaia/references/spec.md` (dispatched by the `/gaia-spec` command, which reads this reference).

The wrapper is implemented as a spec-kit extension plus preset; the architectural rationale (why extension+preset, the `wrap` strategy, version-pin range, hook semantics) is in [[spec-kit Extension Strategy]].

## Hard constraints

- **No machine-local memory for project decisions.** The skill must never write to `~/.claude/projects/.../memory/`. Project-relevant decisions belong only in the SPEC artifact, the wiki, or `.claude/rules/`.
- **Write-surface allowlist.** Every write during a session lands in `.gaia/local/specs/**`, `.specify/**`, `.gaia/local/cache/**`, or `.gaia/local/telemetry/**`. Source files are off-limits. The `after_specify` lint command audits this.
- **One question at a time.** Closed-set questions go through `AskUserQuestion` with options ordered: recommended FIRST, alternatives, `Other`, `Discuss this`. Open-ended questions use plain prompts.
- **Two-gate ceremony.** Gate 1 confirms intent + UATs in plain English before the clarify loop. Gate 2 confirms the rendered artifact before save. No silent advances.
- **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates. Never punt research to the human.

## Steps

1. **Get description + GH-mirror opt-in.** Use `$ARGUMENTS` if non-empty; otherwise ask "What do you want to spec?" and wait. Then ask the GitHub-issue preference via `AskUserQuestion` (recommended/default: "No, skip GitHub issue"), persisting the answer as `gh_mirror_optin`. The mirror is off by default; this single signal gates step 11.
2. **Resume-vs-start prompt.** `lib/spec-allocator.sh in_progress` reports an unfinalized draft SPEC (one still being authored, ledger `status: draft`); user picks Resume or Start new. A finalized SPEC is not surfaced: you resume a draft, not a frozen artifact. A best-effort `lib/spec-reconcile.sh` pass first flips any finalized SPEC whose PR has merged to `merged` from git ground truth. No silent overwrite, no silent fresh allocation.
3. **`/speckit-specify`.** Spec-kit fires the `before_specify` hook (constitution-check + version-pin drift detection) automatically, then runs core. The GAIA preset replaces the core template under `strategy: wrap` so the artifact is GAIA-shaped (frontmatter, immutable flag, frozen `SPEC-NNN` id) and lands at `.gaia/local/specs/SPEC-NNN/SPEC.md`.
4. **Gate 1: shape confirmation.** Present `intent` + UATs in plain English. On confirmation, cache the gate-1 snapshot to `.gaia/local/cache/gate1-<spec_id>.json` (the `after_clarify` hook reads this to detect scope drift in gate 2).
5. **`/speckit-clarify` (Socratic loop).** Sequential coverage-based questioning. Closed-set goes through `AskUserQuestion`; open-ended uses plain prompts; `Discuss this` drops into plain Q&A and records the settled outcome. Per-topic exhaustion checkpoint forbids silent topic advance. Research questions dispatch a `general-purpose` Agent; never punt to the human.
6. **`after_clarify` hook.** Spec-kit fires `/speckit-gaia-self-review`, which audits drift (vs. the gate-1 snapshot), placeholders, ambiguity, and pending clarifications. Save remains blocked while any pending item is unresolved (block-or-defer prompt).
7. **Adversarial SPEC-audit (recommended).** Before gate 2, an `AskUserQuestion` offers the audit at a Standard or Deep rigor tier (or skip for trivial specs); auditing is the recommended default, with the tier and lens set gauged from the draft's stakes and content. Four low-overlap core lenses (factual grounding, UAT testability, coverage/consistency, red-team/feasibility) always run, plus any content-selected specialists (security, migration, accessibility, docs, performance); each verifies the draft's checkable claims against the repo and `node_modules` with `file:line` evidence. A refutation pass keeps severity honest (Deep adds perspective-diverse refuters and a completeness critic); each surviving finding routes to a plan-time directive (recorded in a sibling `AUDIT.md`) or a SPEC contract fix folded into the draft pre-save (no reopen ceremony). The skill's own parallel `general-purpose` Agent fan-out, never the Workflow tool, so it runs in headless and auto-mode contexts. The single-agent step-6 self-review is the always-on baseline. Auto mode runs the recommended tier and lenses; an unavailable fan-out falls back to the self-review. Never blocks save.
8. **Gate 2: artifact confirmation.** Render the full draft and present for review. Plain prompt, not `AskUserQuestion`. Revise to convergence, then proceed.
9. **Save** to `.gaia/local/specs/SPEC-NNN/SPEC.md`. The folder is the archival unit. Sibling artifacts (reports, evidence) live beside `SPEC.md` in the same folder; a flat `SPEC-NNN-<rest>.md` file maps to `SPEC-NNN/<REST>.md` (remainder uppercased, hyphens kept). `lib/spec-folderize.sh` applies this mapping for any legacy flat files.
10. **`after_specify` hook.** Spec-kit fires `/speckit-gaia-lint`, which runs `lib/lint.sh` (frontmatter, frozen UAT-NNN ids, no placeholders, write-allowlist audit). For mutations of an already-saved SPEC, the lint enforces the explicit reopen ceremony: `## Reopen rationale` and `## UAT diff` sections required.
11. **Optional GH Issue mirror.** Skipped entirely (no invocation, no telemetry) when the step-1 `gh_mirror_optin` is false. When opted in, `lib/gh-mirror.sh` creates an Issue if `gh auth status` succeeds, the repo has Issues enabled, and the viewer has write/admin permission. Otherwise appends a skip record to `.gaia/local/telemetry/gh-mirror.jsonl` and exits 0. Absence never blocks save.
12. **Inline chain-trigger to `/gaia-plan`.** No `on_save` hook exists in spec-kit; the chain lives here, inline. `AskUserQuestion` offers "Yes, trigger /gaia-plan (Recommended)" or "No, defer". On Yes, the skill follows `/gaia-plan` inline on the spec thread (no wrapper sub-agent) with the SPEC path; the planner it spawns is the single Opus-pinned leaf. On No, stop. See [[Task Orchestration#Topology]] for why the chain runs inline.

## UAT divergence contract

Auto-generated Playwright specs (written by the `before_implement` hook via `lib/uat-write.sh`) carry an inline header defining the cosmetic-vs-logical boundary:

- **Cosmetic divergence** (selector text, button labels, copy, URL slugs, layout assertions): editable by the implementer without reopening the SPEC.
- **Logical divergence** (user flow, success criteria, error branches, preconditions, post-state): forbidden. Implementer must raise the divergence; the SPEC is reopened and the UAT rewritten before re-running `/speckit-implement`.

## Pairs with

- [[spec-kit Extension Strategy]]: the architectural decision that produced this workflow.
- [[spec-kit]]: the underlying engine; pin, install, version-drift detection.
- [[GAIA Plan]]: the downstream chain target.
- [[Task Orchestration]]: what `/gaia-plan` produces.
