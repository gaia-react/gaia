---
type: concept
title: GAIA Spec
status: active
created: 2026-05-06
updated: 2026-10-06
tags: [concept, claude, skill, orchestration]
---

# GAIA Spec

`/gaia-spec [description]` is GAIA's script-driven Socratic discovery workflow; no spec-kit runtime is involved. It produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN/SPEC.md` and stops, printing a handoff prompt the human pastes into a fresh [[GAIA Plan]] session. The skill body lives at `.claude/skills/gaia/references/spec.md` (dispatched by the `/gaia-spec` command, which reads this reference).

The workflow runs on GAIA's own scripts in `.gaia/scripts/spec/`, Claude-read prose in `.claude/skills/gaia/references/spec/`, and script-consumed templates in `.gaia/templates/spec/`, called directly by the skill.
<!-- gaia:maintainer-only:start -->
The superseded record of the earlier extension-plus-preset design is [[spec-kit Extension Strategy]].
<!-- gaia:maintainer-only:end -->

## Hard constraints

- **No machine-local memory for project decisions.** The skill must never write to `~/.claude/projects/.../memory/`. Project-relevant decisions belong only in the SPEC artifact, the wiki, or `.claude/rules/`.
- **Write-surface allowlist.** Every write during a session lands in `.gaia/local/specs/**`, `.gaia/local/cache/**`, or `.gaia/local/telemetry/**`. Source files are off-limits. The step-10 lint audits this.
- **One question at a time.** Closed-set questions go through `AskUserQuestion` with options ordered: recommended FIRST, alternatives, `Other`, `Discuss this`. Open-ended questions use plain prompts.
- **Two-gate ceremony.** Gate 1 confirms intent + UATs in plain English before the clarify loop. Gate 2 confirms the rendered artifact before save. No silent advances.
- **Coach tone, not interrogator.** Mirror back, name trade-offs, propose candidates. Never punt research to the human.

## Steps

**Model gate (pre-flight).** On entry, before any SPEC id is allocated. SPEC synthesis runs on the main thread, so it uses the session model, and unlike [[GAIA Plan]] this skill cannot pin a subagent (the interactive `AskUserQuestion` and plain-prompt steps do not work in dispatched subagents). Opus and Fable are both top-tier. On Opus or Fable it proceeds silently; on Sonnet/Haiku it offers, via `AskUserQuestion`, to switch to Opus (Recommended) or Fable, or stay on the current model. Picking a switch stops the workflow with a `/model`-and-re-run instruction (nothing is allocated or written); "stay" proceeds on the current model. Auto mode skips the gate and runs on whatever model the automation uses.

1. **Get description.** Use `$ARGUMENTS` if non-empty; otherwise ask "What do you want to spec?" and wait.
2. **Resume-vs-start prompt.** `.gaia/scripts/spec/spec-allocator.sh in_progress` reports an unfinalized draft SPEC (one still being authored, ledger `status: draft`); user picks Resume or Start new. A finalized SPEC is not surfaced: you resume a draft, not a frozen artifact. Four best-effort housekeeping passes run first: `.gaia/scripts/spec/spec-reconcile.sh` flips any finalized SPEC whose PR has merged to `merged` from git ground truth, `.gaia/scripts/spec/spec-archive-merged.sh` reaps any merged SPEC folder once consolidated, past the retention window, and cost-represented in `cost.jsonl`, `.gaia/scripts/spec/spec-archive-abandoned.sh` reaps any abandoned SPEC folder once past the same retention window and cost-represented (see [[#When a SPEC folder is deleted]]), and `.gaia/scripts/spec/spec-abandon-empty.sh` retires any never-authored draft to `abandoned` (see [[#Ledger status vocabulary]]). All four fail-open and never block. No silent overwrite, no silent fresh allocation.
3. **Initial draft (allocate, anchor, stamp).** Allocate the id via `.gaia/scripts/spec/spec-allocator.sh next` with a non-empty subject and halt on a non-zero exit. Create the main-anchored SPEC folder, failing closed when the main checkout cannot be resolved. Write the draft from `.claude/skills/gaia/references/spec/spec-template.md` with the GAIA frontmatter stamped (immutable flag, frozen `SPEC-NNN` id).
4. **Gate 1: shape confirmation.** Present `intent` + UATs in plain English. On confirmation, cache the gate-1 snapshot to `.gaia/local/cache/gate1-<spec_id>.json` (the step-6 self-review reads this to detect scope drift before gate 2).
5. **Socratic loop.** Sequential coverage-based questioning. Closed-set goes through `AskUserQuestion`; open-ended uses plain prompts; `Discuss this` drops into plain Q&A and records the settled outcome. Per-topic exhaustion checkpoint forbids silent topic advance. Research questions dispatch a `general-purpose` Agent; never punt to the human. Coverage over the topic bank (Clear / Partial / Missing) is the loop's stop condition, bounded by a question ceiling (`.claude/skills/gaia/references/spec.md`).
6. **Self-review.** The wrapper dispatches it as a `general-purpose` Agent after the loop and before gate 2, as an explicit step of the skill. It audits drift (vs. the gate-1 snapshot), placeholders, ambiguity, and pending clarifications. Save remains blocked while any pending item is unresolved (block-or-defer prompt).
7. **Adversarial SPEC-audit.** Before gate 2, the audit runs automatically on every spec with no prompt: the draft's stakes and content are gauged to set the rigor tier (Standard or Deep) and the specialist lens set, then the fan-out runs at that tier. Four low-overlap core lenses (factual grounding, UAT testability, coverage/consistency, red-team/feasibility) always run, plus any content-selected specialists (security, migration, accessibility, docs, performance); each verifies the draft's checkable claims against the repo and `node_modules` with `file:line` evidence. A refutation pass keeps severity honest (Deep adds perspective-diverse refuters and a completeness critic; above a refuter cap, either tier batches one refuter per lens and Deep skips the critic); each surviving finding routes to a plan-time directive (recorded in a sibling `AUDIT.md`) or a SPEC contract fix folded into the draft pre-save (no reopen ceremony). The skill's own parallel `general-purpose` Agent fan-out, never the Workflow tool, so it runs in headless and auto-mode contexts. The single-agent step-6 self-review is the always-on baseline. Interactive and auto mode share the same gauge and tier and differ only in how findings surface at disposition; an unavailable fan-out falls back to the self-review. Never blocks save.
8. **Gate 2: artifact confirmation.** Render the full draft and present for review. Plain prompt, not `AskUserQuestion`. Revise to convergence, then proceed.
9. **Save** to `.gaia/local/specs/SPEC-NNN/SPEC.md`. The folder is the archival unit. Sibling artifacts (reports, evidence) live beside `SPEC.md` in the same folder; a flat `SPEC-NNN-<rest>.md` file maps to `SPEC-NNN/<REST>.md` (remainder uppercased, hyphens kept).
10. **Immutability lint.** The skill runs `.gaia/scripts/spec/lint.sh` itself on the saved SPEC (frontmatter, frozen UAT-NNN ids, no placeholders, write-allowlist audit). For mutations of an already-saved SPEC, the lint enforces the explicit reopen ceremony: `## Reopen rationale` and `## UAT diff` sections required.
11. **`/gaia-plan` handoff, then stop.** The handoff lives inline at the end of the skill. After the canonical save, `/gaia-spec` prints a copy-pasteable `/gaia-plan SPEC-NNN` prompt (just the bare id), then stops; the human runs it in a fresh session. `/gaia-plan` resolves the id to `.gaia/local/specs/SPEC-NNN/SPEC.md` (and a sibling `AUDIT.md`, when the audit produced one) itself. Planning is always a new session: authoring a SPEC burns an enormous context (Socratic loop, gate renders, self-review, adversarial audit), and `/gaia-plan`'s deep synthesis needs a clean one, so the handoff is a prompt the human pastes into a fresh session rather than a chain the wrapper runs. See [[Task Orchestration#Topology]].

## UAT divergence contract

The `/gaia-plan` orchestrator's UAT render step turns each browser-flow UAT into a red Playwright spec before the first implementation phase, and each rendered spec carries a contract marker plus an inline header defining the cosmetic-vs-logical boundary. The owning phase must turn the spec green, and a logical divergence halts the run for a SPEC reopen. `.claude/skills/gaia/references/spec/lifecycle.md` owns the render, gate and close steps:

- **Cosmetic divergence** (selector text, button labels, copy, URL slugs, layout assertions): editable by the implementer without reopening the SPEC.
- **Logical divergence** (user flow, success criteria, error branches, preconditions, post-state): forbidden. Implementer must raise the divergence; the SPEC is reopened and the UAT rewritten before re-running the implementation.

## SPEC number allocation

SPEC numbers are reserved as immutable `spec/NNN` git tags pushed to the remote, pointed at git's empty-tree object so they pin no history and carry no commit alive; each is annotated once, at reservation, with the spec's one-line subject, readable via `git tag -n`. The registry survives a fresh clone; an existing clone syncs new reservations with `git fetch --tags`. The next number is max+1 over the union of those tags and the machine's local signals (the ledger, plan branches naming a SPEC as read by `.gaia/scripts/branch-name-lib.sh`, `.gaia/local/specs/` folders). Cross-team collision-avoidance reads the remote `spec/*` tag namespace live, not locally-fetched tags, so it never depends on a stale local mirror. The ledger is one union input, holding draft status, intent, and timestamps per machine: load-bearing local state, not scratch.

## Ledger status vocabulary

The ledger lives at `.gaia/local/specs/ledger.json`, a local, gitignored per-machine cache; the `status` field on each row is exactly one of four canonical values:

- `draft`: allocated, still being authored. The only status `.gaia/scripts/spec/spec-allocator.sh in_progress` surfaces for the resume-vs-start prompt.
- `ready`: artifact finalized and frozen. Downstream plan → implement → merge owns the feature from here.
- `merged`: the implementing PR has landed; `merged_at` records when. `.gaia/scripts/spec/spec-reconcile.sh` sets this from git ground truth.
- `abandoned`: a draft retired terminally, either a never-authored ghost or an authored one dropped for cause. `.gaia/scripts/spec/spec-abandon-empty.sh` sets this on every `/gaia-spec` preflight for a draft row that is BOTH empty (no SPEC.md, no draft cache, no gate-1 snapshot) AND older than the guard age (~1 day); an authored draft dropped for cause (a falsified premise, a change that shipped the same intent elsewhere) is set the same way through `.gaia/scripts/spec/ledger-update.sh`'s chokepoint, or by whatever process makes that call. Either way `abandoned_at` records when. `.gaia/scripts/spec/spec-allocator.sh in_progress` does not surface it, so it stops re-appearing on the resume-vs-start prompt, and (like a merged row) its folder is reaped once `abandoned_at` ages past the retention window and cost is represented (see [[#When a SPEC folder is deleted]]).

No other value is valid. `.gaia/scripts/spec/ledger-update.sh` is the single chokepoint for ledger writes; it accepts only these four canonical values and rejects anything else (exit 6), so a stray label cannot reach the ledger through a tool path. This ledger `status` is a distinct axis from the SPEC-artifact frontmatter's own `status` field (`in-progress | reopened | closed`, validated by `.gaia/scripts/spec/lint.sh`), which tracks whether the artifact itself is being drafted, has been reopened for amendment, or is closed, and from the `{PLAN_DIR}/RUNNING` execution sentinel, which tracks whether a plan is actively running. All three answer different questions and are never conflated.

A ledger that predates the chokepoint can still hold an off-vocabulary status (an older value from before the vocabulary unified, or a hand-edited alias like `shipped`). `spec-reconcile.sh` renames known aliases (`shipped → merged`) to canonical through the guarded chokepoint on every `/gaia-spec`, logging any still-unrecognized status rather than guessing its lifecycle position. A status the alias rename does not cover is fixed by running the one-time migration directly, `.gaia/scripts/ledger-status-migrate.sh`, idempotent so a repeat run is a no-op.

## When a SPEC folder is deleted

A merged SPEC's working folder is kept at merge, not removed. Consolidation reads `SPEC.md` → `AUDIT.md` → the colocated plan's `PROGRESS.md` (top wins) and produces a verified `SUMMARY.md` before the merge; once the merge is confirmed, the orchestrator's post-merge close removes `SPEC.md` and `AUDIT.md`: the folder reduces to `SUMMARY.md` plus its `cost.json` sidecar, the merged folder's archival record (see [[Task Orchestration]]). The ledger row stays at `merged`, the terminal lifecycle state; the whole folder is reaped later, once it clears the retention window.

Two steps handle a merged folder:

- **Post-merge close.** The `/gaia-plan` orchestrator confirms the merge, reconciles the ledger, verifies `SUMMARY.md`, removes `SPEC.md` and `AUDIT.md`, and archives the plan folder. `.claude/skills/gaia/references/spec/lifecycle.md` owns the steps. Nothing reaps the folder early: the retention window is the only clock.
- **Auto-sweep.** `.gaia/scripts/spec/spec-archive-merged.sh` runs on every `/gaia-spec` and `/gaia-plan` pre-flight, right after `spec-reconcile.sh`. It reaps any folder whose ledger row reads `merged`, whose `SUMMARY.md` is present and well-formed (a folder still holding `SPEC.md`/`AUDIT.md` with no consolidated `SUMMARY.md` is kept, consolidation never ran), whose `merged_at` has aged past the retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days), and whose cost is fully represented in `cost.jsonl` via its `cost.json` sidecar (a fail-closed check: an unparseable or unrepresented sidecar blocks that folder's reap). A merged row with no active folder is skipped. This is the safety net for a PR merged out-of-band (the GitHub button, another session) or a close that never ran. The sweep is silent-but-logged: one stdout line per folder reaped.

An **abandoned** SPEC's folder follows the same clock on a simpler path: there is no merge event and no early reap, so auto-sweep is the only path, and there is no consolidation gate (nothing about an abandoned draft is ever promoted into the wiki), so the whole folder reaps as one unit. `.gaia/scripts/spec/spec-archive-abandoned.sh` runs alongside `spec-archive-merged.sh` in the same place, the `/gaia-spec` pre-flight sweep. It reaps any folder whose ledger row reads `abandoned`, whose `abandoned_at` has aged past the same retention window, and whose cost is fully represented in `cost.jsonl`, on the same fail-closed terms as the merged sweep. The reap does not wait on anything beyond the retention window and cost representation. The sweep is silent-but-logged: one stdout line per folder reaped.

### Durability

A `.gaia/local/specs/<ID>/` folder is working state, not the archival
record: it is gitignored, machine-local, and reaped by design after the
retention window above, whether the row is `merged` or `abandoned`. For a
merged SPEC the durable source of truth is the implementing PR, plus
anything the SPEC's content promotes into the wiki; consult those, not the
folder. An abandoned SPEC has no implementing PR and nothing promotes into
the wiki, so its folder genuinely is the only surviving record of the
audit findings and reasoning while it exists. That is a deliberate trade,
not an oversight: a SPEC is abandoned for a definitive reason, and
revisiting one past the retention window is vanishingly unlikely, so the
folder is not kept indefinitely just to hedge against it. Whether either
kind of folder is still present or already reaped says nothing about
whether its intent, decisions, or history are recoverable; consult the PR
(and the wiki, where promoted) for a merged SPEC, or accept that an
abandoned SPEC's detail does not outlive the window. Never mutate or
delete a folder to probe a lifecycle script's behavior or gates; read the
script instead. A folder's routine reap is not data loss.

## Pairs with

<!-- gaia:maintainer-only:start -->
- [[spec-kit Extension Strategy]]: superseded record of the earlier extension-plus-preset design.
- [[spec-kit]]: superseded; GAIA no longer installs spec-kit.
<!-- gaia:maintainer-only:end -->
- [[GAIA Plan]]: the downstream handoff target.
- [[Task Orchestration]]: what `/gaia-plan` produces.
