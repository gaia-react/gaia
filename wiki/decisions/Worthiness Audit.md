---
type: decision
status: active
priority: 1
date: 2026-06-23
created: 2026-06-23
updated: 2026-06-23
tags: [decision, tdd, testing, audit, quality]
---

# Worthiness Audit

An advisory, two-axis review of the tests on the **emergent surface**
(`app/components/**`, `.playwright/**`), the surface where the [[TDD RED
Verification]] gate does not apply. The emergent surface has no stable
failing-then-passing run to gate on, so its honesty and worthiness come from a
fresh-context reviewer instead of a mechanical RED proof. The reviewer
**proposes** verdicts and **edits no files**; a human acts on every proposal.

## Problem

The RED gate proves a deterministic test can fail. It cannot run on the emergent
surface: a component-interaction test, an async test, a layout test, an E2E test
have no honest RED to observe. Without a mechanism, an emergent test that always
passes (a tautology, a child-redundant re-prove, a platform-byte assertion, a
behavior-rich component covered only by a tracer bullet) ships unchallenged and
adds maintenance cost while catching none of its own component's bugs.

## Decision

A committed reviewer prompt judges each changed emergent test on two axes and
returns one verdict per test. A fresh-context reviewer is the cheapest way to
recover the honesty signal the RED gate cannot supply here, because the author
who wrote the tests shares their blind spots.

### The two axes

- **Honesty**: the test can fail for a real reason, asserts through the public
  interface, and survives an internal refactor. A tautology, an internal-collaborator
  mock, or a sole `toHaveBeenCalled` fails this axis.
- **Worthiness**: the discriminator (a failure points at MY code, not a
  dependency), composition non-redundancy (the test asserts the seam, not a
  child's own output), no platform-output tests (the formatter's bytes belong to
  the formatter), and non-triviality (a behavior-rich tracer-bullet/vacuous-a11y-only
  test is incomplete).

### Verdicts

`keep` clears both axes. `fix` is honest-but-flawed (implementation coupling,
platform-byte assertion, or a behavior-rich tracer-bullet/vacuous-a11y-only
test, which returns `fix`, not `keep`). `delete` is worthless or unfalsifiable
and is **always human-gated**.

### Delete constraints

- **Propose-only.** The reviewer never deletes; a human confirms every delete.
- **Composition deletes cite both sides and the sibling is machine-verified.** A
  child-redundancy delete cites the redundant sibling assertion AND the subsuming
  seam assertion, and the cited sibling is confirmed to contain a matching
  assertion before the proposal reaches a human. An unverifiable sibling downgrades
  the proposal.
- **Security / escaping / data-integrity carve-out.** A seam test asserting XSS
  escaping, sanitization, injection resistance, or data integrity is never
  deleted without a machine-verified sibling that asserts the same property.

### Non-triviality is corroboration, not the producer

The judge-independent producer of the non-triviality signal is a structural
floor (a static-shape check at
`.gaia/scripts/a11y-structural/check-a11y-triviality.mjs`), not the reviewer's
runtime agreement. The reviewer's `fix` on a behavior-rich tracer-bullet-only
test is corroborating evidence; when the reviewer and the structural floor
disagree, the disagreement surfaces rather than the reviewer's `keep` overriding
the structural `fix`.

The floor inspects a11y test files (those calling the emergent-signal a11y
helpers `expectNoA11yViolations` / `runAxe`) and flags a vacuous a11y test when
EITHER its `render(...)` passes no props (only defaults) OR its rendered markup
carries no interactive or landmark node while the component's stories declare
interactive variants. It reads no LLM judgement and rests on no can-it-fail axis
(an a11y render reads GREEN identically whether the test is honest or vacuous),
so the structural shape is the mechanical pass condition. It is ADVISORY: a
`trivial` verdict adds a `fix` to the end-of-task summary and routes into the
ledger as a `fix`; it never blocks a commit. A render-only axe pass stays a
complete a11y test for a component with no interactive behavior (a Spinner, a
static badge). The a11y-helper call names are in the [[Determinism Classifier]]
emergent set, so a vacuous a11y test never leaks to the deterministic RED
surface; this floor grades the same test's worthiness.

### Two-tier surfacing

Advisory findings never interrupt mid-implementation; they surface only at
end-of-task, in two tiers. Honesty findings auto-fix in place and are left in the
working tree for normal review. Every proposed delete requires human
confirmation and renders its cited redundant sibling AND the subsuming seam
assertion inline, so the human confirms against the evidence without opening
files. The list is capped: top-N by severity with a count (`delete` proposals
before `fix` findings), never a wall. On the no-orchestrator path the findings
share one end-of-task summary with the determinism roll-up; on the orchestrated
path the same content goes into the leaf's `SUMMARY.md` and the pre-merge
summary.

## Audit ledger

Each verdict appends one line to an append-only ledger, sibling to the RED
ledger:

```json
{"schema": 1, "file": "<repo-rel>", "fullName": "<vitest fullName>", "signal": "sha256:...", "verdict": "keep"|"fix"|"delete", "auditedAt": "<iso>", "artifact": "<...>"}
```

- Path: `.gaia/local/audit-ledger/worthiness.jsonl` (append-only, gitignored,
  grows-forever, sibling to `.gaia/local/red-ledger/observations.jsonl`).
- `signal` is the SAME `sha256`-of-normalized-test-call the RED ledger computes
  via `.gaia/scripts/red-ledger/extract-test-signals.mjs`. The writer reuses
  that helper, so the signal byte-matches what the merge presence gate
  recomputes; reinventing the identity primitive would desync the gate.
- Each non-keep verdict carries a machine-checkable `artifact` (the cited
  sibling for a redundancy delete, the unreachable/missing assertion for a fix),
  so an all-keep run with no artifacts is a detectable contradiction.

## Infrastructure

- `.claude/agents/worthiness-evaluator.md`: the committed, versioned reviewer
  prompt. Reads only the changed emergent test files plus their sibling suites,
  judges both axes, returns `{keep, fix, delete}` per test, edits no files. The
  human-facing encoding of the same contract is
  `.claude/skills/tdd/references/tests-react.md` (the discriminator, composition,
  and platform rules).
- `.gaia/scripts/audit-ledger/append-worthiness.mjs`: the ledger writer. Takes a
  repo-relative test path, a `fullName`, a verdict, and (for non-keep) an
  artifact; recomputes the signal via the RED-ledger helper and appends one
  JSONL line. Rejects an unknown verdict and a non-keep with no artifact.
- `.gaia/scripts/a11y-structural/check-a11y-triviality.mjs`: the structural a11y
  floor. A Node ESM AST helper (TypeScript compiler API, repo-relative path arg,
  `--stdin`, `--stories <path>`) that emits
  `{file, verdict: "trivial" | "non-trivial" | "not-a11y", findings}`. It is the
  judge-independent producer of the non-triviality signal; the reviewer's
  matching `fix` is corroboration only.

## Consumers

- The tdd skill dispatches the fresh-context reviewer and writes the ledger on
  the no-orchestrator path (otherwise principle-6 always-on is violated). Its
  surviving no-orchestrator guarantees (static honesty lint, RED on the
  deterministic surface, the fresh-subagent audit if dispatched) are distinct
  from the orchestrated-only guarantees (the merge presence gate, leaf
  isolation).
- The merge presence gate reads this ledger, recomputes each test's signal, and
  scopes to the emergent set the [[Determinism Classifier]] defines.
