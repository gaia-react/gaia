---
type: concept
title: GAIA Spec
status: active
created: 2026-05-06
updated: 2026-07-07
tags: [concept, claude, skill, orchestration, spec-kit]
---

# GAIA Spec

`/gaia-spec [description]` is GAIA's Socratic discovery wrapper around [[spec-kit]]. It produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN/SPEC.md` and hands off to [[GAIA Plan]]. The skill body lives at `.claude/skills/gaia/references/spec.md` (dispatched by the `/gaia-spec` command, which reads this reference).

The wrapper is implemented as a spec-kit extension plus preset; the architectural rationale (why extension+preset, the `wrap` strategy, version-pin range, hook semantics) is in [[spec-kit Extension Strategy]].

## Hard constraints

- **No machine-local memory for project decisions.** The skill must never write to `~/.claude/projects/.../memory/`. Project-relevant decisions belong only in the SPEC artifact, the wiki, or `.claude/rules/`.
- **Write-surface allowlist.** Every write during a session lands in `.gaia/local/specs/**`, `.specify/**`, `.gaia/local/cache/**`, or `.gaia/local/telemetry/**`. Source files are off-limits. The `after_specify` lint command audits this.
- **One question at a time.** Closed-set questions go through `AskUserQuestion` with options ordered: recommended FIRST, alternatives, `Other`, `Discuss this`. Open-ended questions use plain prompts.
- **Two-gate ceremony.** Gate 1 confirms intent + UATs in plain English before the clarify loop. Gate 2 confirms the rendered artifact before save. No silent advances.
- **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates. Never punt research to the human.

## Steps

**Model gate (pre-flight).** On entry, before any SPEC id is allocated. SPEC synthesis runs on the main thread, so it uses the session model, and unlike [[GAIA Plan]] this skill cannot pin a subagent (the interactive `AskUserQuestion` and plain-prompt steps do not work in dispatched subagents). Opus and Fable are both top-tier. On Opus or Fable it proceeds silently; on Sonnet/Haiku it offers, via `AskUserQuestion`, to switch to Opus (Recommended) or Fable, or stay on the current model. Picking a switch stops the workflow with a `/model`-and-re-run instruction (nothing is allocated or written); "stay" proceeds on the current model. Auto mode skips the gate and runs on whatever model the automation uses.

1. **Get description.** Use `$ARGUMENTS` if non-empty; otherwise ask "What do you want to spec?" and wait.
2. **Resume-vs-start prompt.** `lib/spec-allocator.sh in_progress` reports an unfinalized draft SPEC (one still being authored, ledger `status: draft`); user picks Resume or Start new. A finalized SPEC is not surfaced: you resume a draft, not a frozen artifact. Three best-effort housekeeping passes run first: `lib/spec-reconcile.sh` flips any finalized SPEC whose PR has merged to `merged` from git ground truth, `lib/spec-archive-merged.sh` deletes any merged-but-present SPEC folder whose cost is represented in `cost.jsonl` (see [[#When a SPEC folder is deleted]]), and `lib/spec-abandon-empty.sh` retires any never-authored draft to `abandoned` (see [[#Ledger status vocabulary]]). All three fail-open and never block. No silent overwrite, no silent fresh allocation.
3. **`/speckit-specify`.** Spec-kit fires the `before_specify` hook (constitution-check + version-pin drift detection) automatically, then runs core. The GAIA preset replaces the core template under `strategy: wrap` so the artifact is GAIA-shaped (frontmatter, immutable flag, frozen `SPEC-NNN` id) and lands at `.gaia/local/specs/SPEC-NNN/SPEC.md`.
4. **Gate 1: shape confirmation.** Present `intent` + UATs in plain English. On confirmation, cache the gate-1 snapshot to `.gaia/local/cache/gate1-<spec_id>.json` (the `after_clarify` hook reads this to detect scope drift in gate 2).
5. **`/speckit-clarify` (Socratic loop).** Sequential coverage-based questioning. Closed-set goes through `AskUserQuestion`; open-ended uses plain prompts; `Discuss this` drops into plain Q&A and records the settled outcome. Per-topic exhaustion checkpoint forbids silent topic advance. Research questions dispatch a `general-purpose` Agent; never punt to the human.
6. **`after_clarify` hook.** Spec-kit fires `/speckit-gaia-self-review`, which audits drift (vs. the gate-1 snapshot), placeholders, ambiguity, and pending clarifications. Save remains blocked while any pending item is unresolved (block-or-defer prompt).
7. **Adversarial SPEC-audit (recommended).** Before gate 2, an `AskUserQuestion` offers the audit at a Standard or Deep rigor tier (or skip for trivial specs); auditing is the recommended default, with the tier and lens set gauged from the draft's stakes and content. Four low-overlap core lenses (factual grounding, UAT testability, coverage/consistency, red-team/feasibility) always run, plus any content-selected specialists (security, migration, accessibility, docs, performance); each verifies the draft's checkable claims against the repo and `node_modules` with `file:line` evidence. A refutation pass keeps severity honest (Deep adds perspective-diverse refuters and a completeness critic); each surviving finding routes to a plan-time directive (recorded in a sibling `AUDIT.md`) or a SPEC contract fix folded into the draft pre-save (no reopen ceremony). The skill's own parallel `general-purpose` Agent fan-out, never the Workflow tool, so it runs in headless and auto-mode contexts. The single-agent step-6 self-review is the always-on baseline. Auto mode runs the recommended tier and lenses; an unavailable fan-out falls back to the self-review. Never blocks save.
8. **Gate 2: artifact confirmation.** Render the full draft and present for review. Plain prompt, not `AskUserQuestion`. Revise to convergence, then proceed.
9. **Save** to `.gaia/local/specs/SPEC-NNN/SPEC.md`. The folder is the archival unit. Sibling artifacts (reports, evidence) live beside `SPEC.md` in the same folder; a flat `SPEC-NNN-<rest>.md` file maps to `SPEC-NNN/<REST>.md` (remainder uppercased, hyphens kept). `lib/spec-folderize.sh` applies this mapping for any legacy flat files.
10. **`after_specify` hook.** Spec-kit fires `/speckit-gaia-lint`, which runs `lib/lint.sh` (frontmatter, frozen UAT-NNN ids, no placeholders, write-allowlist audit). For mutations of an already-saved SPEC, the lint enforces the explicit reopen ceremony: `## Reopen rationale` and `## UAT diff` sections required.
11. **`/gaia-plan` handoff.** No `on_save` hook exists in spec-kit, so the handoff lives inline at the end of the wrapper. After the canonical save, `/gaia-spec` prints a copy-pasteable `/gaia-plan SPEC-NNN` prompt (just the bare id), then stops; the human runs it in a fresh session. `/gaia-plan` resolves the id to `.gaia/local/specs/SPEC-NNN/SPEC.md` (and a sibling `AUDIT.md`, when the audit produced one) itself. See [[Task Orchestration#Topology]].

## UAT divergence contract

Auto-generated Playwright specs (written by the `before_implement` hook via `lib/uat-write.sh`) carry an inline header defining the cosmetic-vs-logical boundary:

- **Cosmetic divergence** (selector text, button labels, copy, URL slugs, layout assertions): editable by the implementer without reopening the SPEC.
- **Logical divergence** (user flow, success criteria, error branches, preconditions, post-state): forbidden. Implementer must raise the divergence; the SPEC is reopened and the UAT rewritten before re-running `/speckit-implement`.

## SPEC number allocation

SPEC numbers are reserved as immutable `spec/NNN` git tags pushed to the remote, pointed at git's empty-tree object so they pin no history and carry no commit alive; each is annotated once, at reservation, with the spec's one-line subject, readable via `git tag -n`. The registry survives a fresh clone; an existing clone syncs new reservations with `git fetch --tags`. The next number is max+1 over the union of those tags and the machine's local signals (the ledger, `spec-NNN-*` branches, `.gaia/local/specs/` folders). Cross-team collision-avoidance reads the remote `spec/*` tag namespace live, not locally-fetched tags, so it never depends on a stale local mirror. The ledger is one union input, holding draft status, intent, and timestamps per machine: load-bearing local state, not scratch.

## Ledger status vocabulary

The ledger lives at `.gaia/local/specs/ledger.json`, a local, gitignored per-machine cache; the `status` field on each row is exactly one of five canonical values:

- `draft`: allocated, still being authored. The only status `lib/spec-allocator.sh in_progress` surfaces for the resume-vs-start prompt.
- `specified`: artifact finalized and frozen. Downstream plan → implement → merge owns the feature from here.
- `merged`: the implementing PR has landed; `merged_at` records when. `lib/spec-reconcile.sh` sets this from git ground truth.
- `archived`: a legacy, manual-only value; no workflow produces it. The merge path leaves the ledger row at `merged` and deletes the working folder outright (see [[#When a SPEC folder is deleted]]), so a merge never yields `archived`. It stays one of the accepted canonical values only so a pre-existing `archived` row, or a hand-archived folder under `.gaia/local/specs/archived/` (each carrying `status: archived` on its SPEC frontmatter), still validates through `lib/ledger-update.sh`.
- `abandoned`: a draft allocated but never authored, retired terminally. `lib/spec-abandon-empty.sh` sets this on every `/gaia-spec` preflight for a draft row that is BOTH empty (no SPEC.md, no draft cache, no gate-1 snapshot) AND older than the guard age (~1 day); `abandoned_at` records when. `lib/spec-allocator.sh in_progress` does not surface it, so it stops re-appearing on the resume-vs-start prompt.

No other value is valid. `lib/ledger-update.sh` is the single chokepoint for ledger writes; it accepts the five canonical values plus the tolerated legacy `in-progress`, and rejects anything else (exit 6), so a stray label cannot reach the ledger through a tool path. `in-progress` is a deprecated legacy value that `spec-reconcile.sh` advances toward `merged` from git; new flows use `draft → specified`.

A ledger that predates the chokepoint can still hold a misnamed status (a hand-edited or backfilled `shipped`, say). These self-heal: `spec-reconcile.sh` runs on every `/gaia-spec` and renames known aliases (`shipped → merged`) to canonical through the guarded chokepoint, logging any unrecognized status rather than guessing its lifecycle position.

## When a SPEC folder is deleted

A merged SPEC's working folder is deleted outright; no `archived/` tree survives it. The ledger row stays at `merged`, the terminal lifecycle state.

Two paths reach the delete:

- **`spec-close`.** `/speckit-gaia-spec-close` deletes a SPEC's working folder once the implementing PR has merged (and after any deferred wiki-promote drain).
- **Auto-sweep.** `lib/spec-archive-merged.sh` runs on every `/gaia-spec`, right after `spec-reconcile.sh`. It deletes any folder whose ledger row reads `merged` and that has no pending wiki-promote drain cache at `.gaia/local/cache/wiki-promote/<id>.json` (a pending cache means the wiki content has not promoted yet, so the close flow still owns it), gated on every `cost.md` phase in the folder being value-represented in `cost.jsonl` (a fail-closed check: an unparseable or unrepresented phase blocks that folder's deletion). A merged row with no active folder is skipped. This is the safety net for a PR merged out-of-band (the GitHub button, another session) or a close that never ran. The sweep is silent-but-logged: one stdout line and a `spec_closed` telemetry event (`disposition: delete`) per folder removed.

## Pairs with

- [[spec-kit Extension Strategy]]: the architectural decision that produced this workflow.
- [[spec-kit]]: the underlying engine; pin, install, version-drift detection.
- [[GAIA Plan]]: the downstream handoff target.
- [[Task Orchestration]]: what `/gaia-plan` produces.
