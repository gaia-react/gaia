---
type: decision
status: active
priority: 1
date: 2026-06-04
created: 2026-06-04
updated: 2026-06-05
tags: [decision, tdd, hooks, quality]
---

# TDD RED Verification

Mechanical enforcement that TDD's RED phase actually ran before a commit introduces a new test. Two PreToolUse/PostToolUse hooks and a content-signal ledger close the gap between "a test exists" and "the test was observed failing."

## Problem

Writing a test that starts green (either mirroring existing behavior or trivially passing) satisfies neither the TDD discipline nor the intent of the [[Quality Gate]]. No tooling previously caught a test that was never red.

## Decision

A RED-observation ledger at `.gaia/local/red-ledger/` (machine-local, gitignored) stores per-test evidence from the last one-shot vitest run. Two hooks enforce the lifecycle:

- **`capture-red-observations.sh`** (PostToolUse, Bash): after any one-shot vitest run, re-invokes vitest with `--reporter=json` scoped to the same target and records each genuinely-failing test. Each record stores `file`, `fullName`, a normalized content signal (deterministic hash of the test body), and `failureKind`. Collection and compile errors are excluded to avoid coarse false-REDs. Observe-only; always exits 0.

- **`red-verify-commit-check.sh`** (PreToolUse, Bash deny): before `git commit`, walks every test file that is new at HEAD. For each new test, the hook computes the current content signal and looks it up in the ledger. A missing entry or a signal mismatch (test body changed since the RED was observed) denies the commit, naming the offending test. Fail-open on missing tooling or unparseable test files; fail-closed only for the clean case.

The content signal is a normalized hash of the test body so that a cosmetic rename does not reuse a stale RED entry from a substantively different test.

## Scope

- Pre-commit check on `git commit` only. Does not gate `git push` or CI.
- New tests only: tests that already exist at the merge base are not checked.
- Fail-open: the hook does not block when the ledger tooling (Node, the signal extractor) is unavailable or when a test file cannot be parsed by the TS compiler API.
- Type-only tests are exempt. A test whose assertions are all type-level and which carries no runtime expectation has no runtime failure mode, so the gate has nothing to demand; `tsc` enforces it instead. See [[#Type-only tests]].

## Infrastructure

- `.gaia/scripts/red-ledger/extract-test-signals.mjs`: Node ESM helper using the TypeScript compiler API to emit `{fullName, signal, kind}` NDJSON for each test in a file.
- `.claude/hooks/lib/red-ledger.sh`: shared shell library sourced by both hooks. Owns ledger path resolution, repo-relative normalization, and signal invocation.

## Type-only tests

A type-level assertion is invisible to the test runner: vitest runs without `--typecheck`, so `expectTypeOf`/`assertType` calls and `@ts-expect-error` proofs neither pass nor fail at runtime. A test built only from these always passes the runner yet can never produce a failing run, so demanding a runtime RED for it is unsatisfiable. The signal helper therefore classifies every test and the commit check exempts the type-only ones, delegating their correctness to the `tsc` step of the [[Quality Gate]].

The helper tags each test `kind: "type-only"` or `kind: "runtime"`. A test is `type-only` when it has at least one type-level proof (`expectTypeOf`/`assertType`, or a `@ts-expect-error` directive) **and** no runtime assertion (`expect`/`assert`); otherwise it is `runtime`. The predicate requires a positive type-level signal, so a test with no assertions at all stays `runtime` and is never silently exempted, and a test mixing a runtime assertion with a type-level proof stays `runtime` and still owes a RED.

This exemption is keyed to the correct predicate (no runtime assertion), distinct from the dynamic-title carve-out, which is keyed to uncomputable identity (a computed test title emits no signal, so it never enters the checked set).

Recommended idiom: prefer `expectTypeOf`/`assertType` for an honest per-assertion proof. A pure type-test file can also use the `*.test-d.ts` convention, which `tsc` checks while both vitest and this gate skip it by glob. Reserve `@ts-expect-error` for proving a specific misuse is rejected; its signal is whole-statement and inverted, holding while the error is present and breaking when the code becomes permissive enough to remove it.

## Consequences

A new test always requires a one-shot vitest run that observes the test failing before the commit is allowed. This is a one-time step per new test; a green-only test that was never run red will be denied at commit time with a clear message naming the test.

See [[Claude Hooks]] for hook registration. See the [[Quality Gate]] for the broader pre-commit enforcement surface.
