# UAT evidence — v2

Maps each of SPEC-001's UAT-001..UAT-018 to the v2 implementation. Every UAT is cross-referenced to the artifact (manifest, command body, helper script, or sandbox transcript) that satisfies it.

Source SPEC: `.gaia/local/specs/SPEC-001.md` (frozen).
Revised contracts: `.gaia/local/specs/SPEC-001-revised-contracts.md`.
Sandbox transcript: `.specify/extensions/gaia/test/v2-validation.md`.

## UAT-001 — SPEC artifact shape

**Given** spec-kit installed at the GAIA pin, GAIA extension loaded, constitution populated.
**When** `/gaia spec` runs through both gates.
**Then** SPEC artifact at `.gaia/local/specs/SPEC-NNN.md` has all schema fields populated, no placeholders, `status: in-progress`, `immutable: true`, stable `UAT-NNN` ids.

Evidence:
- `.specify/extensions/gaia/templates/spec-template.md` — frontmatter with `spec_id`, `type`, `status: in-progress`, `immutable: true`, `wiki_promote_default`, `chain_trigger`, plus body fields.
- `.specify/presets/gaia/templates/spec-template.md` — same skeleton, applied via the preset for any `/speckit-specify` entry path.
- `.claude/skills/gaia/references/spec.md` Step 8 — explicit save target `.gaia/local/specs/SPEC-NNN.md`.
- `lib/spec-allocator.sh` — monotonic zero-padded `SPEC-NNN` ids.

## UAT-002 — preset overrides applied at /specify time

**Given** project with the GAIA preset installed.
**When** `/gaia spec` invokes `/speckit-specify` then `/speckit-clarify`.
**Then** the artifact reflects GAIA preset overrides — coach-tone system prompt, AskUserQuestion-formatted Q&A copy, GAIA frontmatter fields.

Evidence:
- `.specify/presets/gaia/preset.yml` — `provides.templates[]` declares both `speckit.specify` (command, `strategy: wrap`) and `spec-template` (template, `strategy: replace`).
- `.specify/presets/gaia/commands/speckit.specify.md` — wraps core via `{CORE_TEMPLATE}` and adds GAIA pre-checks (Step 0) and post-relocation (Steps 2–3).
- Sandbox check: `specify preset resolve spec-template` returns the GAIA preset's path; `.claude/skills/speckit-specify/SKILL.md` body is the GAIA wrap with core spliced in (393 lines, single Pre-Execution Checks section) — see `v2-validation.md`.
- Coach-tone system prompt at `.specify/extensions/gaia/templates/system-prompt.md`; clarify Q&A copy at `templates/clarify-prompts.md`.

## UAT-003 — closed-set Q&A via AskUserQuestion, recommended-first

**Given** an active `/gaia spec` Socratic loop.
**When** the PO issues a closed-set question.
**Then** options are ordered recommended-first → alternatives → Other → Discuss this; one question per turn.

Evidence:
- `.claude/skills/gaia/references/spec.md` §5a — explicit ordering rules.
- `.specify/extensions/gaia/templates/clarify-prompts.md` Rule 2 + Rule 1 (one question at a time).
- `.specify/extensions/gaia/templates/system-prompt.md` Behavioral contract item 1.

## UAT-004 — Discuss-this escape and resume

**Given** user picks `Discuss this` on a closed-set question.
**When** the topic settles via plain Q&A.
**Then** outcome is recorded in `clarifications.answered[]` and the structured loop resumes on the next topic.

Evidence:
- `.claude/skills/gaia/references/spec.md` §5b — record-and-resume flow.
- `templates/clarify-prompts.md` Rule 3 — settlement signals + announce phrasing + advance to next topic (no re-ask of the discussed question).

## UAT-005 — per-topic exhaustion checkpoint

**Given** the PO has run out of natural follow-ups.
**When** a topic transition is imminent.
**Then** the PO announces via `AskUserQuestion`: `"Out of questions on <topic>. Move to <next>, or push deeper?"`.

Evidence:
- `.claude/skills/gaia/references/spec.md` §5d — exhaustion checkpoint phrasing matches normative copy.
- `templates/clarify-prompts.md` Rule 5 — normative phrasing pinned (silent topic advance forbidden).

## UAT-006 — two-gate ceremony

**Given** discovery has gathered enough material.
**When** the PO is ready to render the SPEC.
**Then** Gate 1 fires (intent + UATs in plain English), then Gate 2 fires (rendered artifact). Save only after Gate 2 confirmation.

Evidence:
- `.claude/skills/gaia/references/spec.md` Steps 4 (Gate 1), 7 (Gate 2), 8 (save).
- Step 4 caches the gate-1 snapshot at `.gaia/local/cache/gate1-<spec_id>.json` (consumed by self-review for drift detection — see UAT-016).

## UAT-007 — constitution placeholder gate

**Given** `.specify/memory/constitution.md` has placeholder text.
**When** user invokes `/gaia spec`.
**Then** the wrapper detects placeholders before any Socratic question is issued, prompts the user to run `/speckit-constitution`, or blocks. Never proceeds silently.

Evidence:
- `.specify/extensions/gaia/extension.yml` — `hooks.before_specify.command: speckit.gaia.constitution-check` (mandatory).
- `.specify/extensions/gaia/commands/constitution-check.md` Step 2 — placeholder regex `\[[A-Z_0-9]+\]` against the constitution file; emits a block message naming the count and first three placeholder ids.
- Sandbox transcript: `before_specify` event renders `EXECUTE_COMMAND: speckit.gaia.constitution-check` directive automatically.

## UAT-008 — immutability lint at after_specify

**Given** a drafted SPEC artifact ready for save.
**When** spec-kit's `after_specify` hook fires.
**Then** the lint pass audits frontmatter for `immutable: true`, frozen `UAT-NNN` ids, no placeholders, all required fields. Pass → save proceeds; fail → save blocked.

Evidence (v2 reshape — slash-command, not shell script):
- `.specify/extensions/gaia/extension.yml` — `hooks.after_specify.command: speckit.gaia.lint` (mandatory).
- `.specify/extensions/gaia/commands/lint.md` — slash-command body that invokes `bash .specify/extensions/gaia/lib/lint.sh <path>` and surfaces findings.
- `lib/lint.sh` — pure helper: stdin-free, takes a path arg, returns `{"ok": bool, "findings": [...]}`. Smoke test against `.gaia/local/specs/SPEC-001.md` returns `{"ok":true,"findings":[]}`.
- Sandbox transcript: `after_specify` event renders `EXECUTE_COMMAND: speckit.gaia.lint` directive automatically.
- The block semantics live in `references/spec.md` Step 9 — the wrapper agent reads the lint failure message and chooses not to advance past save.

## UAT-009 — no machine-local memory writes

**Given** a memory snapshot before `/gaia spec`.
**When** a complete session runs to save.
**Then** the post-session snapshot has no new memory files containing project-relevant decisions.

Evidence:
- `.claude/skills/gaia/references/spec.md` Hard constraint 1 — explicit "No machine-local memory for project decisions" instruction at the top of the wrapper (binding for the agent driving `/gaia spec`).
- `.specify/extensions/gaia/templates/system-prompt.md` Behavioral contract item 8 — same rule from the system prompt side.
- Personal preferences (tone, formatting) remain allowed; project decisions land in the SPEC artifact, the wiki, or `.claude/rules/`.

## UAT-010 — inline chain-trigger to /gaia plan

**Given** a SPEC has just been saved.
**When** the save step completes.
**Then** the wrapper prompts `"SPEC-NNN saved. Trigger /gaia plan now?"` via `AskUserQuestion`. The chain only fires on explicit confirmation; the human can defer.

Evidence (v2 reshape — inline `AskUserQuestion`, not `on_save`):
- `.claude/skills/gaia/references/spec.md` Step 11 — inline `AskUserQuestion` with normative phrasing and the two options (Yes Recommended / No defer). The `on_save` hook does not exist in spec-kit; the chain-trigger lives in the wrapper command body.
- Sandbox transcript: `on_save` event renders `(no hooks)` — confirms the lifecycle does not include this event and the inline placement is the correct location.

## UAT-011 — immutability + reopen ceremony

**Given** a saved SPEC with `status: in-progress`, `immutable: true`.
**When** any process attempts to mutate a UAT in-place.
**Then** the lint rejects the mutation. Amending requires the explicit reopen ceremony — rationale recorded, status flipped to `reopened`, UAT diff captured.

Evidence:
- `lib/lint.sh` reopen-ceremony branch: when `status: reopened`, body must contain `## Reopen rationale` and `## UAT diff` sections; missing → lint fail with `reopen_missing_rationale` / `reopen_missing_diff` finding codes.
- `commands/lint.md` documents the reopen-ceremony enforcement. The wrapper (`references/spec.md` Step 9) honors the lint failure for reopens.

## UAT-012 — optional GitHub Issue mirror

**Given** a project with optional GitHub integration.
**When** the mirror step runs.
**Then** GH Issue is created iff `gh auth status` succeeds AND `repos/{owner}/{repo}.has_issues` is true AND viewer has admin/write permission. Otherwise no mirror, no error, no degradation.

Evidence:
- `lib/gh-mirror.sh` — three guard conditions (`gh auth`, `has_issues`, `permission ∈ {admin,write}`). On any failure: telemetry record to `.gaia/local/telemetry/gh-mirror.jsonl`, exit 0, no SPEC mutation.
- `references/spec.md` Step 10 — invocation pattern `bash .specify/extensions/gaia/lib/gh-mirror.sh "$PWD" "<spec-id>" "<spec-rel-path>"`. CLI args (no stdin payload — the v1 stdin-payload contract was fictional).
- On success: stamps `gh_issue_url` into the SPEC frontmatter idempotently via in-place awk rewrite.

## UAT-013 — resume vs start-new for in-progress SPECs

**Given** an in-progress SPEC at `.gaia/local/specs/`.
**When** user invokes `/gaia spec` without a force-new flag.
**Then** the wrapper asks `"Resume SPEC-NNN, or start new (leaves SPEC-NNN open)?"` via `AskUserQuestion`; user choice honored.

Evidence:
- `.claude/skills/gaia/references/spec.md` Step 2 — pre-flight `bash .specify/extensions/gaia/lib/spec-allocator.sh in_progress "$PWD"` returns the in-progress SPEC id (or `none`); on hit, prompt with the normative phrasing and two options.
- `lib/spec-allocator.sh in_progress <root>` — scans `.gaia/local/specs/SPEC-*.md` for frontmatter `status: in-progress`. Smoke test against the live repo finds nothing in-progress (SPEC-001 is in-progress per its own frontmatter).

## UAT-014 — research subagent dispatch with announce

**Given** a discovery question requires prior-art / repo-convention / competitive lookup.
**When** the PO encounters such a question.
**Then** the PO announces `"Dispatching research agent for <question>"` BEFORE dispatching, never punts research to the human.

Evidence:
- `.claude/skills/gaia/references/spec.md` §5e — normative announce phrasing + general-purpose Agent dispatch pattern.
- `.specify/extensions/gaia/templates/clarify-prompts.md` Rule 6 — same announce phrasing pinned, with note on Discuss-this + research interaction.

## UAT-015 — write-surface allowlist

**Given** an active `/gaia spec` session.
**When** any file is modified.
**Then** writes only land in `.gaia/local/specs/`, `.specify/`, `.gaia/local/cache/`, or `.gaia/local/telemetry/`. No source files modified by the spec command.

Evidence:
- `.claude/skills/gaia/references/spec.md` Hard constraint 2 — explicit allowlist enumerated; binding for the agent driving the wrapper.
- The `after_specify` lint surfaces lint findings; the agent can audit the workspace diff against the allowlist as part of the lint pass (lint helper itself doesn't enforce the allowlist — the wrapper does at the agent-instruction level).
- Out-of-allowlist writes are an agent-discipline matter, not a hook-machine-enforced one (matches the broader hook semantics: hooks signal, the agent obeys).

## UAT-016 — self-review pre-gate-2

**Given** a drafted SPEC ready for gate 2.
**When** the PO completes self-review.
**Then** the artifact is checked for placeholders, scope drift relative to gate 1, internal inconsistency, ambiguous UAT phrasing. Issues fixed before gate 2 presents.

Evidence:
- `.specify/extensions/gaia/extension.yml` — `hooks.after_clarify.command: speckit.gaia.self-review` (mandatory).
- `.specify/extensions/gaia/commands/self-review.md` — checklist covers all five categories (placeholders, scope drift, inconsistency, ambiguity, pending). Reads gate-1 snapshot at `.gaia/local/cache/gate1-<spec_id>.json` for drift comparison.
- `references/spec.md` Step 6 — wrapper applies fixes for any drift/ambiguity/inconsistency findings before Gate 2 (Step 7) presents.
- Sandbox transcript: `after_clarify` event renders `EXECUTE_COMMAND: speckit.gaia.self-review` directive automatically.

## UAT-017 — pending clarifications block-or-defer

**Given** `clarifications.pending` is non-empty at gate-2 time.
**When** user attempts to confirm at gate 2.
**Then** for each pending item the PO asks via `AskUserQuestion` "Answer now, or defer with rationale?" Save blocked until each item is answered or explicitly deferred with rationale.

Evidence:
- `.specify/extensions/gaia/commands/self-review.md` §5 — normative `AskUserQuestion` phrasing with three options (Answer now / Defer with rationale / Discuss this) and the resolution flow.
- `references/spec.md` Step 6 — wrapper enforces "save remains blocked while any pending item is unresolved".

## UAT-018 — spec-kit version pin enforcement

**Given** GAIA's manifest declares a spec-kit version pin.
**When** `/gaia spec` invokes spec-kit primitives.
**Then** spec-kit is invoked at the pinned version and drift produces a clear error before discovery.

Evidence (v2 reshape — manifest `requires.speckit_version` + runtime drift detection):
- `.specify/extensions/gaia/extension.yml` — `requires.speckit_version: ">=0.8.5,<0.10.0"` (specifier-set range, real spec-kit schema; PR #84's fictional `==X.Y.Z` literal removed).
- `lib/version-check.sh` — parses the pinned specifier set, resolves the floor, compares against runtime `specify --version`. Drift → exit 1 with stderr message naming both versions and the upgrade command. Match → cache the verification at `.gaia/local/cache/version-check.lock` for the calendar day.
- `commands/constitution-check.md` Step 1 — invokes `version-check.sh` and halts the lifecycle on drift.
- The pin is enforced by the manifest's `requires.speckit_version` at install time (spec-kit refuses to install an extension whose pin doesn't match) AND by `version-check.sh` at runtime (catches drift between install and runtime, e.g. when the pin floor was bumped but the user hasn't re-installed).

## Summary

All 18 UATs map to artifacts on this branch. Three UATs changed shape vs. PR #84:

| UAT     | PR #84 satisfier                       | v2 satisfier                                                                |
|---------|----------------------------------------|------------------------------------------------------------------------------|
| UAT-008 | `hooks/after_specify.sh` shell script   | `commands/lint.md` slash-command + `lib/lint.sh` helper, fired via `after_specify` hook |
| UAT-010 | `on_save` hook (fictional event)        | Inline `AskUserQuestion` at Step 11 of `references/spec.md`                 |
| UAT-018 | `requires.speckit_version: "==X.Y.Z"` + `requires.speckit_invocation` (both fictional schema fields) | `requires.speckit_version: ">=0.8.5,<0.10.0"` (real schema) + `lib/version-check.sh` runtime drift detection |

The v2 model has no fictional events, no fictional manifest fields, and no shell-script hooks. Hooks are slash commands; `EXECUTE_COMMAND` directives are rendered by spec-kit's `HookExecutor` and the agent invokes them as Claude skills.
