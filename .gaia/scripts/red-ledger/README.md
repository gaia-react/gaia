# RED-observation ledger

Mechanical TDD RED-verification records each test the agent observed failing,
so the commit gate can confirm a new passing test was seen failing first. Two
hooks share this directory's contract: a PostToolUse capture hook appends
observations, and a PreToolUse check denies a commit whose new passing test has
no matching RED on record.

## Ledger

- **Directory:** `.gaia/local/red-ledger/` (under the gitignored `.gaia/local/`,
  so the ledger never gets committed). The capture hook `mkdir -p`s it on first
  write.
- **File:** `.gaia/local/red-ledger/observations.jsonl`; append-only JSON
  Lines, one observation per line. Capture never rewrites or dedups; duplicate
  observations for the same `(file, fullName, signal)` are harmless and the
  check treats "at least one matching valid RED exists" as satisfied.

## Record schema

```json
{
  "schema": 1,
  "file": "app/x/index.test.ts",
  "fullName": "X does Y",
  "signal": "sha256:…",
  "failureKind": "assertion",
  "observedAt": "2026-06-04T20:55:00Z"
}
```

- `schema` (number); version, currently `1`. Readers ignore lines whose
  schema they do not understand (forward-compat).
- `file` (string); repo-relative POSIX path to the test file. No leading
  `./`, never absolute.
- `fullName` (string); vitest's `assertionResults[].fullName`: the enclosing
  describe titles plus the test title, space-joined.
- `signal` (string); `sha256:` followed by the lowercase-hex sha256 of the
  test's normalized source span (see below).
- `failureKind` (string); `"assertion"` or `"runtime"`. Both are valid REDs.
  A `"collection"` kind is never written: a suite-level collection or compile
  error where no test body ran is not a valid RED.
- `observedAt` (string); ISO-8601 UTC timestamp.

## Content signal

vitest's `--reporter=json` emits `location: null` for every assertion, so the
signal is derived from the test file source, not the reporter. The signal binds
a RED to a specific test body: editing the body changes the signal and
invalidates the RED, so a fresh failing run must be observed.

## Helper: `extract-test-signals.mjs`

Node ESM, Node stdlib only (resolves `typescript` from `node_modules` for a
robust AST walk).

```
node .gaia/scripts/red-ledger/extract-test-signals.mjs <repo-relative-test-path>
node .gaia/scripts/red-ledger/extract-test-signals.mjs <path> --stdin
```

Reads the file from disk (or stdin with `--stdin`) and prints one JSON object
per discovered `test(...)`/`it(...)` call, newline-delimited:
`{"fullName":"…","signal":"sha256:…"}`. Exit `0` on success (no output when no
tests are found); non-zero with a one-line stderr message on a parse failure.

`fullName` is the enclosing describe titles (outermost first) plus the test
title, single-space-joined. `signal` is `sha256:` plus the lowercase-hex
sha256 of the test call expression's normalized source; trimmed, with internal
whitespace runs collapsed to single spaces, so it stays stable across pure
reformatting and changes when the title, assertion, or body changes.
