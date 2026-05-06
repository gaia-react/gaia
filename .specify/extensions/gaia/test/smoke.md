# `/gaia spec` — manual smoke runbook

This runbook walks the full `/gaia spec` lifecycle and maps every step to the UAT it satisfies. It is a manual document, not an executable test. Use it as the basis for the evidence file in `task-uat-verification` (Phase 3).

## Prerequisites

- spec-kit installed at the version pinned in `.specify/extensions/gaia/extension.yml`.
- GAIA spec-kit extension loaded.
- `.specify/memory/constitution.md` populated (no placeholder text).
- `gh` CLI installed and authenticated (only required for UAT-012 confirmation).
- Working tree clean enough to spot accidental writes outside the allowlist.

## Pre-flight snapshot

Before starting, capture two snapshots so the post-run audits can diff cleanly:

1. **Memory snapshot.** `find ~/.claude/projects/$(pwd | sed 's|/|-|g')/memory -type f 2>/dev/null > /tmp/gaia-smoke-memory-before.txt`. Used by UAT-009.
2. **Source-tree snapshot.** `git status --porcelain > /tmp/gaia-smoke-tree-before.txt`. Used by UAT-015.

---

## Step 1 — Invoke `/gaia spec` against a populated constitution

**Action.** Run `/gaia spec "trivial test feature: render a hello world panel"` from a clean session.

**Expected outcome.**

- `before_specify.sh` runs the version check first; cache written to `.gaia/local/cache/version-check.lock`.
- Constitution placeholder check passes.
- spec-kit invokes at the pinned version (verifiable by the `speckit_version` field stamped into the session marker).

**UATs covered.** UAT-002 (preset overrides applied to draft), UAT-007 (constitution check passes when populated), UAT-018 (version pin enforced before any discovery).

---

## Step 2 — Constitution placeholder block

**Action.** Restore `.specify/memory/constitution.md` to spec-kit's default template state (or replace one populated value with `[PLACEHOLDER]`). Re-run `/gaia spec "trivial test feature"`.

**Expected outcome.**

- `before_specify.sh` returns `{"action": "block", "reason": "spec-kit constitution at .specify/memory/constitution.md still contains placeholder values..."}`.
- The wrapper surfaces the block message verbatim. No discovery question is issued.
- After running `/speckit.constitution` and re-invoking `/gaia spec`, discovery proceeds normally.

**UATs covered.** UAT-007.

---

## Step 3 — Resume-vs-start-new prompt

**Action.** With an in-progress SPEC already at `.gaia/local/specs/SPEC-NNN.md`, invoke `/gaia spec "another feature"` without a force-new flag.

**Expected outcome.**

- `before_specify.sh` returns `{"action": "prompt", "prompt": "Resume SPEC-NNN, or start new (leaves SPEC-NNN open)?", "default": "resume"}`.
- The wrapper surfaces the prompt via `AskUserQuestion` with two options (Resume, Start new).
- Choosing "Resume" reopens the existing draft; choosing "Start new" leaves SPEC-NNN's `status: in-progress` untouched and allocates a fresh id.

**UATs covered.** UAT-013.

---

## Step 4 — Socratic loop: AskUserQuestion mediation

**Action.** Continue through the discovery loop on the new SPEC. Trigger several closed-set questions.

**Expected outcome.**

- Every closed-set question goes through `AskUserQuestion`.
- Options are ordered: recommended FIRST (annotated `(Recommended)`), alternatives, `Other` (free text), `Discuss this`.
- Open-ended questions use a plain prompt with no enumerated options.
- Exactly one question per turn — no multi-question forms, no silent stacking.

**UATs covered.** UAT-003.

---

## Step 5 — `Discuss this` escape

**Action.** On any closed-set question, pick `Discuss this`. Engage in plain Q&A. Once the topic feels settled, send an explicit settlement signal (e.g. `"ok, that one"`).

**Expected outcome.**

- The structured loop drops to plain Q&A on the single topic.
- On settlement: the discussion outcome is recorded under `clarifications.answered[]` of the in-progress draft as `{ q: "<original question>", a: "<settled outcome>" }`.
- The structured loop resumes on the next topic, not the same one.

**UATs covered.** UAT-004.

---

## Step 6 — Per-topic exhaustion checkpoint

**Action.** Continue answering questions on a single topic until the PO runs out of natural follow-ups.

**Expected outcome.**

- The PO surfaces an `AskUserQuestion`: `"Out of questions on <topic>. Move to <next topic>, or push deeper?"` with `header: "Topic"` and three options (Move (Recommended), Push deeper, Other).
- Silent topic advance never happens.

**UATs covered.** UAT-005.

---

## Step 7 — Research subagent dispatch

**Action.** Reach a question that requires prior-art lookup, repo-convention investigation, or competitive analysis (e.g. "what naming convention does this codebase use for Zustand stores?").

**Expected outcome.**

- The PO announces verbatim: `"Dispatching research agent for <question>"`, then spawns a `general-purpose` Agent.
- Findings are folded into the draft's `research_summary`.
- The user is never asked to do the research themselves.

**UATs covered.** UAT-014.

---

## Step 8 — Gate 1 (shape confirmation)

**Action.** When the PO believes it has enough material, observe the gate-1 step.

**Expected outcome.**

- The PO presents `intent` paragraph and the proposed UATs in plain English (NOT via `AskUserQuestion`).
- Authoring of the rendered artifact does not begin until the user confirms.
- A gate-1 snapshot is cached at `.gaia/local/cache/gate1-<spec_id>.json` containing intent, UAT list, and timestamp.

**UATs covered.** UAT-006 (gate 1 half).

---

## Step 9 — `after_clarify` self-review

**Action.** Allow the clarify loop to complete and the `after_clarify` hook to run.

**Expected outcome.**

- The hook checks the draft against the gate-1 snapshot for placeholders, scope drift, internal inconsistency, and ambiguous UAT phrasing.
- Issues are surfaced via `{"action": "prompt", ...}` and resolved before gate 2 presents.
- The self-review is recorded in `clarifications.answered[]` as a confirmation step.

**UATs covered.** UAT-016.

---

## Step 10 — `clarifications.pending` block-or-defer

**Action.** Force at least one item into `clarifications.pending[]` (e.g. via the `Discuss this` flow that was deferred). Run through to gate 2.

**Expected outcome.**

- For each pending item, `after_clarify` surfaces `AskUserQuestion`: `"Pending clarification: <item>. Answer now, or defer with rationale?"` with options (Answer now, Defer with rationale, Discuss this).
- Save is blocked until each pending item is either answered (moved to `clarifications.answered[]`) or explicitly deferred with a recorded rationale.

**UATs covered.** UAT-017.

---

## Step 11 — Gate 2 (artifact confirmation)

**Action.** After `after_clarify` clears, observe the gate-2 step.

**Expected outcome.**

- The full rendered artifact (frontmatter plus body) is presented in markdown via a plain prompt.
- Save does not happen until the user confirms.
- If the user revises, the loop folds the revision back into the draft and re-presents.

**UATs covered.** UAT-006 (gate 2 half).

---

## Step 12 — `after_specify` immutability lint

**Action.** On gate-2 confirmation, observe `after_specify.sh` running.

**Expected outcome.**

- Lint checks frontmatter for `immutable: true`, `status: in-progress`, well-formed `UAT-NNN` IDs, no placeholder text, and presence of all required schema fields.
- Lint also performs the path-allowlist audit on the session — only `.gaia/local/specs/**`, `.specify/**`, `.gaia/local/cache/**`, `.gaia/local/telemetry/**` may have been written.
- Lint pass returns `{"action": "proceed"}`. Lint fail returns `{"action": "block", "reason": "..."}` and save is halted.

**UATs covered.** UAT-008, UAT-015 (write-surface audit).

---

## Step 13 — SPEC saved to disk

**Action.** Lint passes. The wrapper writes the artifact.

**Expected outcome.**

- File exists at `.gaia/local/specs/SPEC-NNN.md`.
- Frontmatter includes all schema fields, `status: in-progress`, `immutable: true`, stable `UAT-NNN` IDs, no placeholder text.
- No duplicate copies anywhere else in the tree.

**UATs covered.** UAT-001 (full end-to-end), UAT-008 (lint pass culminates in save).

---

## Step 14 — GitHub Issue mirror (conditional)

**Action.** With all three conditions met (gh auth ok, repo Issues enabled, viewer write permission), the wrapper invokes `lib/gh-mirror.sh`.

**Expected outcome — happy path.**

- A new GitHub Issue is created titled `"<spec-id>: <intent first line>"` with the SPEC body as the issue body.
- The SPEC frontmatter gains a `gh_issue_url: <url>` field.
- A telemetry record `{status:"mirrored", detail:"<url>"}` is appended to `.gaia/local/telemetry/gh-mirror.jsonl`.

**Action — failure paths.** Repeat the smoke after each of the following individually:

1. `gh auth logout` (auth fails)
2. Disable Issues on the GitHub repo (has_issues=false)
3. Run as a user without write permission (read-only collaborator)

**Expected outcome — each failure path.**

- `gh-mirror.sh` exits 0 (no error to lifecycle).
- A telemetry record `{status:"skipped", event:"<gh_auth_failed|issues_disabled|no_write_permission>"}` is appended.
- The SPEC is unchanged; no `gh_issue_url` field is stamped.
- The wrapper continues to `on_save` without warning.

**UATs covered.** UAT-012.

---

## Step 15 — `on_save` chain prompt

**Action.** Wait for the wrapper to invoke the `on_save` hook.

**Expected outcome.**

- `on_save.sh` returns `{"action": "prompt", "prompt": "SPEC-NNN saved. Trigger /gaia plan now?", "default": "yes"}`.
- The wrapper surfaces it via `AskUserQuestion` (header `"Chain"`, two options: Yes (Recommended), No).
- On `Yes`: `/gaia plan` dispatches with the SPEC path as input.
- On `No`: the wrapper stops and prints the final confirmation line; no chain fires.

**UATs covered.** UAT-010.

---

## Step 16 — Immutable UAT enforcement (post-save mutation attempt)

**Action.** Manually edit `.gaia/local/specs/SPEC-NNN.md` to change a UAT body. Re-invoke `/gaia spec` so the lint hook re-evaluates the saved artifact.

**Expected outcome.**

- The immutability lint rejects the silent mutation.
- Amending requires the explicit reopen ceremony: rationale recorded in the SPEC body, `status` flipped to `reopened`, UAT diff captured before the mutation is allowed.
- A bare in-place UAT edit without ceremony is blocked.

**UATs covered.** UAT-011.

---

## Step 17 — No-machine-local-memory rule

**Action.** Snapshot machine-local memory after the smoke pass: `find ~/.claude/projects/$(pwd | sed 's|/|-|g')/memory -type f 2>/dev/null > /tmp/gaia-smoke-memory-after.txt`. Diff against the pre-flight snapshot.

**Expected outcome.**

- `diff /tmp/gaia-smoke-memory-before.txt /tmp/gaia-smoke-memory-after.txt` shows no new files containing project-relevant decisions.
- Personal-preference memory entries (tone, formatting) remain allowed; project decisions live in the SPEC, the wiki, or `.claude/rules/`.

**UATs covered.** UAT-009.

---

## Step 18 — Write-surface audit

**Action.** After the full smoke run, capture the post-run tree state and diff.

**Expected outcome.**

- `git status --porcelain` shows changes only under `.gaia/local/specs/`, `.specify/`, `.gaia/local/cache/`, `.gaia/local/telemetry/`.
- No source files (`app/**`, `src/**`, repo-root configs, `package.json`, etc.) were modified.

**UATs covered.** UAT-015.

---

## UAT coverage matrix

| UAT     | Smoke step                              |
| ------- | --------------------------------------- |
| UAT-001 | Step 13 (full end-to-end save)          |
| UAT-002 | Step 1                                  |
| UAT-003 | Step 4                                  |
| UAT-004 | Step 5                                  |
| UAT-005 | Step 6                                  |
| UAT-006 | Steps 8, 11 (gate 1 + gate 2)           |
| UAT-007 | Step 2                                  |
| UAT-008 | Step 12                                 |
| UAT-009 | Step 17                                 |
| UAT-010 | Step 15                                 |
| UAT-011 | Step 16                                 |
| UAT-012 | Step 14 (happy path + 3 failure paths)  |
| UAT-013 | Step 3                                  |
| UAT-014 | Step 7                                  |
| UAT-015 | Steps 12 + 18                           |
| UAT-016 | Step 9                                  |
| UAT-017 | Step 10                                 |
| UAT-018 | Step 1 (version pin) + drift simulation |

## UAT-018 drift simulation

**Action.** Edit `.specify/extensions/gaia/extension.yml` to a non-existent version (e.g. `==v9.9.9`). Invoke `/gaia spec "trivial"`.

**Expected outcome.**

- `version-check.sh` exits non-zero with stderr: pinned version, installed version, and the upgrade command.
- `before_specify.sh` wraps it as `{"action": "block", "reason": "<stderr>"}`.
- The wrapper surfaces the block verbatim. No discovery starts. No constitution check runs (drift is detected first).
- After restoring the pin, the cache file `.gaia/local/cache/version-check.lock` updates on next invocation.
