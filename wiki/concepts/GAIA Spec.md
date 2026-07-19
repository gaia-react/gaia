---
type: concept
title: GAIA Spec
status: active
created: 2026-05-06
updated: 2026-07-19
tags: [concept, claude, skill, orchestration, spec-kit]
---

# GAIA Spec

`/gaia-spec [description]` is GAIA's Socratic discovery wrapper around [[spec-kit]]. It produces an immutable SPEC artifact at `.gaia/local/specs/SPEC-NNN/SPEC.md` and stops, printing a handoff prompt the human pastes into a fresh [[GAIA Plan]] session. The skill body lives at `.claude/skills/gaia/references/spec.md` (dispatched by the `/gaia-spec` command, which reads this reference).

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
2. **Resume-vs-start prompt.** `lib/spec-allocator.sh in_progress` reports an unfinalized draft SPEC (one still being authored, ledger `status: draft`); user picks Resume or Start new. A finalized SPEC is not surfaced: you resume a draft, not a frozen artifact. Four best-effort housekeeping passes run first: `lib/spec-reconcile.sh` flips any finalized SPEC whose PR has merged to `merged` from git ground truth, `lib/spec-archive-merged.sh` reaps any merged SPEC folder once consolidated, past the retention window, and cost-represented in `cost.jsonl`, `lib/spec-archive-abandoned.sh` reaps any abandoned SPEC folder once past the same retention window and cost-represented (see [[#When a SPEC folder is deleted]]), and `lib/spec-abandon-empty.sh` retires any never-authored draft to `abandoned` (see [[#Ledger status vocabulary]]). All four fail-open and never block. No silent overwrite, no silent fresh allocation.
3. **`/speckit-specify`.** Spec-kit fires the `before_specify` hook (constitution-check + version-pin drift detection) automatically, then runs core. The GAIA preset replaces the core template under `strategy: wrap` so the artifact is GAIA-shaped (frontmatter, immutable flag, frozen `SPEC-NNN` id) and lands at `.gaia/local/specs/SPEC-NNN/SPEC.md`.
4. **Gate 1: shape confirmation.** Present `intent` + UATs in plain English. On confirmation, cache the gate-1 snapshot to `.gaia/local/cache/gate1-<spec_id>.json` (the step-6 self-review reads this to detect scope drift before gate 2).
5. **Socratic loop.** Sequential coverage-based questioning. Closed-set goes through `AskUserQuestion`; open-ended uses plain prompts; `Discuss this` drops into plain Q&A and records the settled outcome. Per-topic exhaustion checkpoint forbids silent topic advance. Research questions dispatch a `general-purpose` Agent; never punt to the human. Coverage over the topic bank (Clear / Partial / Missing) is the loop's stop condition, bounded by a question ceiling (`.claude/skills/gaia/references/spec.md`).
6. **Self-review.** The wrapper dispatches it as a `general-purpose` Agent after the loop and before gate 2, independent of any spec-kit hook. It audits drift (vs. the gate-1 snapshot), placeholders, ambiguity, and pending clarifications. Save remains blocked while any pending item is unresolved (block-or-defer prompt).
7. **Adversarial SPEC-audit.** Before gate 2, the audit runs automatically on every spec with no prompt: the draft's stakes and content are gauged to set the rigor tier (Standard or Deep) and the specialist lens set, then the fan-out runs at that tier. Four low-overlap core lenses (factual grounding, UAT testability, coverage/consistency, red-team/feasibility) always run, plus any content-selected specialists (security, migration, accessibility, docs, performance); each verifies the draft's checkable claims against the repo and `node_modules` with `file:line` evidence. A refutation pass keeps severity honest (Deep adds perspective-diverse refuters and a completeness critic); each surviving finding routes to a plan-time directive (recorded in a sibling `AUDIT.md`) or a SPEC contract fix folded into the draft pre-save (no reopen ceremony). The skill's own parallel `general-purpose` Agent fan-out, never the Workflow tool, so it runs in headless and auto-mode contexts. The single-agent step-6 self-review is the always-on baseline. Interactive and auto mode share the same gauge and tier and differ only in how findings surface at disposition; an unavailable fan-out falls back to the self-review. Never blocks save.
8. **Gate 2: artifact confirmation.** Render the full draft and present for review. Plain prompt, not `AskUserQuestion`. Revise to convergence, then proceed.
9. **Save** to `.gaia/local/specs/SPEC-NNN/SPEC.md`. The folder is the archival unit. Sibling artifacts (reports, evidence) live beside `SPEC.md` in the same folder; a flat `SPEC-NNN-<rest>.md` file maps to `SPEC-NNN/<REST>.md` (remainder uppercased, hyphens kept). `lib/spec-folderize.sh` applies this mapping for any legacy flat files.
10. **`after_specify` hook.** Spec-kit fires `/speckit-gaia-lint`, which runs `lib/lint.sh` (frontmatter, frozen UAT-NNN ids, no placeholders, write-allowlist audit). For mutations of an already-saved SPEC, the lint enforces the explicit reopen ceremony: `## Reopen rationale` and `## UAT diff` sections required.
11. **`/gaia-plan` handoff, then stop.** No `on_save` hook exists in spec-kit, so the handoff lives inline at the end of the wrapper. After the canonical save, `/gaia-spec` prints a copy-pasteable `/gaia-plan SPEC-NNN` prompt (just the bare id), then stops; the human runs it in a fresh session. `/gaia-plan` resolves the id to `.gaia/local/specs/SPEC-NNN/SPEC.md` (and a sibling `AUDIT.md`, when the audit produced one) itself. The stop is enforced, not advised: see [[#The spec-to-plan chain guard]]. See [[Task Orchestration#Topology]].

## The spec-to-plan chain guard

Planning is always a new session. Authoring a SPEC burns an enormous context (Socratic loop, gate renders, self-review, adversarial audit), and `/gaia-plan`'s deep synthesis needs a clean one, so the handoff is a prompt the human pastes into a fresh session rather than a chain the wrapper runs.

Prose alone does not hold that boundary. When `/gaia-spec` is invoked as a skill rather than typed by a human, the driving agent carries an outer goal ("spec and build X") that outlives the skill body, and step 11's stop reads as a suggestion it can weigh against the goal. `.claude/hooks/block-spec-plan-chain.sh` makes it deterministic instead.

Both commands are thin dispatchers whose body is "read the reference and follow it exactly", so every entry path funnels through tool calls a `PreToolUse` hook sees:

- **Stamp** (a spec session is underway, never blocked): a `Skill` call resolving to `gaia-spec`, or a `Bash` call invoking `lib/spec-allocator.sh`. The allocator is the stamp of record, because a human-typed `/gaia-spec` expands at the prompt level and reaches no tool, while every `/gaia-spec` path (fresh, resume, auto) allocates a SPEC id.
- **Deny** (while that stamp is live): a `Skill` call resolving to `gaia-plan`, or a `Read` of `.claude/skills/gaia/references/plan.md`. Denying the `Read` is what closes the real hole, an agent can plan without ever touching the `Skill` tool, by reading the reference and following it inline.

The sentinel is keyed on `session_id` (`.gaia/local/cache/spec-chain-<session_id>.json`), so the guard is scoped to the session that authored the SPEC and is inert everywhere else: a fresh session reaches `/gaia-plan` by any route, including the model's own natural-language dispatch. `/clear` releases it (the guard's `SessionStart` arm); compaction deliberately does not, since a compacted spec session is the same session with the same momentum.

The block is strict: at the `Read` chokepoint a human-typed `/gaia-plan` is indistinguishable from a model-initiated one, so it is denied too. That matches the policy rather than bending it, and the sanctioned path is one keystroke away, which the deny message names.

## UAT divergence contract

Auto-generated Playwright specs (written by the `before_implement` hook via `lib/uat-write.sh`) carry an inline header defining the cosmetic-vs-logical boundary:

- **Cosmetic divergence** (selector text, button labels, copy, URL slugs, layout assertions): editable by the implementer without reopening the SPEC.
- **Logical divergence** (user flow, success criteria, error branches, preconditions, post-state): forbidden. Implementer must raise the divergence; the SPEC is reopened and the UAT rewritten before re-running `/speckit-implement`.

## SPEC number allocation

SPEC numbers are reserved as immutable `spec/NNN` git tags pushed to the remote, pointed at git's empty-tree object so they pin no history and carry no commit alive; each is annotated once, at reservation, with the spec's one-line subject, readable via `git tag -n`. The registry survives a fresh clone; an existing clone syncs new reservations with `git fetch --tags`. The next number is max+1 over the union of those tags and the machine's local signals (the ledger, `spec-NNN-*` branches, `.gaia/local/specs/` folders). Cross-team collision-avoidance reads the remote `spec/*` tag namespace live, not locally-fetched tags, so it never depends on a stale local mirror. The ledger is one union input, holding draft status, intent, and timestamps per machine: load-bearing local state, not scratch.

## Ledger status vocabulary

The ledger lives at `.gaia/local/specs/ledger.json`, a local, gitignored per-machine cache; the `status` field on each row is exactly one of four canonical values:

- `draft`: allocated, still being authored. The only status `lib/spec-allocator.sh in_progress` surfaces for the resume-vs-start prompt.
- `ready`: artifact finalized and frozen. Downstream plan → implement → merge owns the feature from here.
- `merged`: the implementing PR has landed; `merged_at` records when. `lib/spec-reconcile.sh` sets this from git ground truth.
- `abandoned`: a draft retired terminally, either a never-authored ghost or an authored one dropped for cause. `lib/spec-abandon-empty.sh` sets this on every `/gaia-spec` preflight for a draft row that is BOTH empty (no SPEC.md, no draft cache, no gate-1 snapshot) AND older than the guard age (~1 day); an authored draft dropped for cause (a falsified premise, a change that shipped the same intent elsewhere) is set the same way through `lib/ledger-update.sh`'s chokepoint, by hand or by whatever process makes that call. Either way `abandoned_at` records when. `lib/spec-allocator.sh in_progress` does not surface it, so it stops re-appearing on the resume-vs-start prompt, and (like a merged row) its folder is reaped once `abandoned_at` ages past the retention window and cost is represented (see [[#When a SPEC folder is deleted]]).

No other value is valid. `lib/ledger-update.sh` is the single chokepoint for ledger writes; it accepts only these four canonical values and rejects anything else (exit 6), so a stray label cannot reach the ledger through a tool path. This ledger `status` is a distinct axis from the SPEC-artifact frontmatter's own `status` field (`in-progress | reopened | closed`, validated by `lib/lint.sh`), which tracks whether the artifact itself is being drafted, has been reopened for amendment, or is closed, and from the `{PLAN_DIR}/RUNNING` execution sentinel, which tracks whether a plan is actively running. All three answer different questions and are never conflated.

A ledger that predates the chokepoint can still hold an off-vocabulary status (an older value from before the vocabulary unified, or a hand-edited alias like `shipped`). These self-heal: a one-time migration rewrites every off-vocabulary status to its canonical replacement the next time the SessionStart janitor runs, and `spec-reconcile.sh` separately renames other known aliases (`shipped → merged`) to canonical through the guarded chokepoint on every `/gaia-spec`, logging any still-unrecognized status rather than guessing its lifecycle position.

## When a SPEC folder is deleted

A merged SPEC's working folder is kept at merge, not removed. Consolidation reads `SPEC.md` → `AUDIT.md` → the colocated plan's `PROGRESS.md` (top wins) and produces a verified `SUMMARY.md`, then `SPEC.md` and `AUDIT.md` are removed: the folder reduces to `SUMMARY.md` plus its `cost.json` sidecar, the merged folder's archival record (see [[Task Orchestration]]). The ledger row stays at `merged`, the terminal lifecycle state; the whole folder is reaped later, once it clears the retention window.

Two paths reach the reap:

- **`spec-close`.** `/speckit-gaia-spec-close` runs consolidation once the implementing PR has merged (and after any deferred wiki-promote drain), then delegates to `lib/spec-archive-merged.sh --close` for the single-id reap, which bypasses only the age gate (early-reap-at-close); every other gate still applies.
- **Auto-sweep.** `lib/spec-archive-merged.sh` runs on every `/gaia-spec`, right after `spec-reconcile.sh`, and again from the SessionStart janitor. It reaps any folder whose ledger row reads `merged`, that has no pending wiki-promote drain cache at `.gaia/local/cache/wiki-promote/<id>.json` (a pending cache means the wiki content has not promoted yet, so the close flow still owns it), whose `SUMMARY.md` is present and well-formed (a folder still holding `SPEC.md`/`AUDIT.md` with no consolidated `SUMMARY.md` is kept, consolidation never ran), whose `merged_at` has aged past the retention window (`GAIA_SPEC_RETENTION_DAYS`, default 30 days), and whose cost is fully represented in `cost.jsonl` via its `cost.json` sidecar (a fail-closed check: an unparseable or unrepresented sidecar blocks that folder's reap). A merged row with no active folder is skipped. This is the safety net for a PR merged out-of-band (the GitHub button, another session) or a close that never ran. The sweep is silent-but-logged: one stdout line per folder reaped.

An **abandoned** SPEC's folder follows the same clock on a simpler path: there is no `spec-close`-equivalent early-reap (an abandoned draft has no merge event to trigger one), so auto-sweep is the only path, and there is no consolidation gate (nothing about an abandoned draft is ever promoted into the wiki), so the whole folder reaps as one unit. `lib/spec-archive-abandoned.sh` runs alongside `spec-archive-merged.sh` in the same two places (the `/gaia-spec` pre-flight sweep and the SessionStart janitor). It reaps any folder whose ledger row reads `abandoned`, whose `abandoned_at` has aged past the same retention window, and whose cost is fully represented in `cost.jsonl`, on the same fail-closed terms as the merged sweep. Unlike the merged path it does not guard on a pending wiki-promote defer cache; a row abandoned after `/speckit-implement` ran (a finalized SPEC's PR left open, then dropped for cause) can leave one behind, and since no close flow will ever drain it, the reap purges it instead of waiting on a merge that will never happen. The sweep is silent-but-logged: one stdout line per folder reaped.

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

- [[spec-kit Extension Strategy]]: the architectural decision that produced this workflow.
- [[spec-kit]]: the underlying engine; pin, install, version-drift detection.
- [[GAIA Plan]]: the downstream handoff target.
- [[Task Orchestration]]: what `/gaia-plan` produces.
