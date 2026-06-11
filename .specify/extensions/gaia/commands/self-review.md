---
description: 'GAIA after_clarify hook: pre-gate-2 self-review pass on the in-progress SPEC draft.'
---

# Self-review pass before gate 2

Fired automatically by spec-kit on the `after_clarify` event (mandatory hook). Runs after the Socratic clarify loop and before the GAIA wrapper presents the rendered artifact for gate-2 confirmation.

## Inputs

- The in-progress SPEC draft. The wrapper writes the working draft to `.gaia/local/cache/draft.md` during the loop; the path may also be supplied via `$ARGUMENTS`.
- The gate-1 snapshot at `.gaia/local/cache/gate1-<spec_id>.json`, captured when the user confirmed intent + UATs.

## Audit checklist

Read the draft and the gate-1 snapshot. Surface findings under each heading; do not fix in place, the wrapper folds fixes back in.

### 1. Placeholder text

Scan for `[PLACEHOLDER]`, `<TODO>`, `<TBD>`, `FIXME`, and bare `TBD` tokens. Any hit is a finding: name the field and the offending line.

### 2. Scope drift relative to gate 1

Compare draft fields against the gate-1 snapshot:

- `intent` paragraph diverged in shape, not just polish.
- A UAT was renumbered, removed, or added since gate 1.
- `success_criteria` gained or lost an entry without a corresponding answered clarification.

For each drift, name the gate-1 value, the current value, and ask the wrapper to surface a confirmation prompt before gate 2 (or to revert).

### 3. Internal inconsistency

Cross-check fields against each other:

- A UAT references a behavior absent from `intent` or `success_criteria`.
- `scope_boundaries.always` includes a behavior contradicted by `scope_boundaries.never`.
- `clarifications.answered[]` entries that contradict the current `intent`.

### 4. Ambiguous UAT phrasing

Each UAT must be testable. Flag UATs that:

- Use hedging ("should", "might", "ideally").
- Lack a falsifiable `then`.
- Reference an undefined system (e.g. "the orchestrator" without prior naming).

### 5. Pending clarifications block-or-defer

For each item in `clarifications.pending[]`, surface via `AskUserQuestion`:

- question: `"Pending clarification: <item>. Answer now, or defer with rationale?"`
- header: `"Pending"`
- options:
  - `{ label: "Answer now", description: "Resolve the clarification before save." }`
  - `{ label: "Defer with rationale", description: "Record a rationale and proceed; item remains pending." }`
  - `{ label: "Discuss this", description: "Drop to plain Q&A on this clarification." }`

On `Answer now`: collect the answer, move the item to `clarifications.answered[]`.
On `Defer with rationale`: collect the rationale via plain prompt, record alongside the pending item.
On `Discuss this`: drop to plain Q&A; on settlement, move to `clarifications.answered[]`.

Save remains blocked while any pending item is unresolved (neither answered nor explicitly deferred).

## Output

Emit a structured report the wrapper can fold back in:

```
self-review findings (gate 2 gate):
  placeholders: <N>: <field>:<line>, ...
  scope_drift:  <N>: gate1.<field> vs current.<field>
  inconsistency: <N>: <description>
  ambiguous_uats: <N>: UAT-NNN: <phrasing>
  pending: <N>: <item summary>, ...
```

If every section is clean:

> `after_clarify` self-review clean: ready for gate 2.

## Notes

- This hook is the last automated gate before the human-facing gate 2. Surface every candidate finding in each section, including borderline and low-confidence ones; do not pre-filter for importance or confidence. Gate 2 (the human) triages. Suppressing a borderline finding here is the failure mode this gate exists to catch.
- Self-review never edits the draft; the wrapper does. This skill produces a report; the wrapper consumes it.
- The pending-clarifications gate is itself a required behavior. The wrapper is responsible for honoring the user's choice and looping until pending is resolved.
