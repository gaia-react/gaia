---
type: decision
status: active
priority: 1
date: 2026-06-23
created: 2026-06-23
updated: 2026-06-23
tags: [decision, tdd, testing, audit, merge, quality]
---

# Worthiness Presence Gate

A merge-time `gh pr merge` gate that requires each emergent test a PR changes to
carry a worthiness-ledger line matching its current content. It is the
merge-time half of the [[Worthiness Audit]]: the evaluator judges each emergent
test and the tdd skill appends one ledger line per judged test; this gate
enforces at merge that such a line exists for the content being merged. It sits
alongside the [[PR Merge Workflow]]'s code-review-audit gate, both deny
`gh pr merge` independently.

Machine-enforced by `.claude/hooks/worthiness-presence-check.sh`, a PreToolUse
Bash hook registered in `.claude/settings.json` as a sibling to
`.claude/hooks/pr-merge-audit-check.sh`.

## What the gate proves, and what it does not

The check is a ledger lookup plus a signal recompute. It never re-runs tests and
never re-runs the evaluator. A present, signal-matching ledger line proves only
that the test-identity extractor **ran over the test's current content** and a
verdict was recorded against that exact content. It does **not** prove that
judgement was applied.

A scripted rubber-stamp, run `.gaia/scripts/red-ledger/extract-test-signals.mjs`
over the changed files and append a `keep` for every emitted signal, mints every
matching line at near-zero cost and is the cost-minimizing path through this
gate. The judgement guarantee rests on the human PR rollup, not on the presence
of a line, plus the D-8 cross-check below. The gate is a forgery floor against
"no audit ran at all," not a proof that an honest audit ran.

The presence decision reads **presence and signal match only**; it never reads
the keep/fix/delete verdict. That keeps the verdict advisory and avoids
double-gating the emergent surface on a judgement call.

## D-8 cross-check

The one place a verdict is read is the D-8 cross-check. A `keep` ledger line on a
file that still carries an unresolved D-8 static honesty error is a provable
rubber-stamp: the honesty lint already flags the file, so a `keep` contradicts a
machine-checkable signal.

The cross-check matches the frozen D-8 rule-id suffixes
(`no-mock-internal`, `no-literal-tautology`, `no-call-through-only`,
`no-server-import-from-consumer`; the namespace prefix is the lint maintainer's
to set). When the rules are enforced and an in-scope file with a `keep` line
reports one of those errors at error severity, the merge is denied. The
cross-check degrades gracefully: when ESLint is absent, the rules are not
installed, or no D-8 error exists, it is silent and the gate passes.

## Per-verdict artifact

Each non-keep verdict carries a machine-checkable `artifact` on its ledger line
(the cited sibling for a redundancy delete, the unreachable or missing assertion
for a fix), enforced by the ledger writer
`.gaia/scripts/audit-ledger/append-worthiness.mjs`. An all-keep run with no
artifacts is therefore a detectable contradiction: a real audit that found
nothing to fix or delete is plausible, but a run that records only `keep` while
the D-8 lint flags the file is not.

## Scope

The gate scopes to the emergent test files **this PR changed**, the diff against
the merge base with the default branch, not the whole repo's emergent tests. A
whole-repo scope would demand a ledger line for every existing emergent test and
block every unrelated merge.

Emergent membership is decided by the [[Determinism Classifier]]
(`.gaia/scripts/classifier/classify-determinism.mjs`), not a second hand-rolled
classifier. A changed test file under `app/components/**` or `.playwright/**`
whose classifier verdict is `emergent` is in scope; a `.ts` test under
`app/components/**` that the classifier proves deterministic is RED-gated by the
[[TDD RED Verification]] gate, not worthiness-gated, and is excluded.

When zero emergent test files changed, the gate is a no-op and allows the merge.

## Stale-signal rejection

The `signal` is the same `sha256`-of-normalized-test-call the RED ledger computes
via `extract-test-signals.mjs` (wrapped by `.claude/hooks/lib/red-ledger.sh`),
the same primitive the worthiness ledger writer uses, so the recomputed signal
byte-matches the ledger. A line written before a later edit carries the old
signal and never matches the recomputed current signal, so editing a test after
its verdict invalidates the line, exactly like the RED gate's stale-signal
invalidation.

## Cost and latency

The recompute is O(emergent test files changed in the PR): each in-scope file is
fed through the signal helper once. Wall-clock therefore scales with the emergent
test count. This is a separate axis from the per-test token cost, which does not
scale with suite size; the recompute is deliberately linear in the changed
emergent file count and is not made sub-linear.

## Fail-open posture

The gate enforces only where its tooling answers, matching the sibling hooks:

- `jq`, `git`, `node`, the RED-ledger lib, or the classifier unavailable: allow.
- A changed emergent test file the signal helper cannot parse (a mid-edit syntax
  error): skip that file, never deny.
- The deny path is fail-closed only for the clean case: a parseable in-scope
  emergent test whose current signal has no matching ledger line, or a `keep`
  line on a file with an unresolved D-8 error.

## Relationship to the other merge gates

- The code-review-audit gate ([[PR Merge Workflow]]) proves a clean code review
  ran against HEAD. This gate proves the emergent tests the PR changed carry
  worthiness verdicts for their current content. They are independent denials;
  both must clear.
- The [[TDD RED Verification]] commit gate owns the deterministic surface at
  commit time. This gate owns the emergent surface at merge time. The classifier
  draws the line between the two so a test is never gated by both.

See [[Worthiness Audit]], [[PR Merge Workflow]], [[Determinism Classifier]],
[[TDD RED Verification]].
