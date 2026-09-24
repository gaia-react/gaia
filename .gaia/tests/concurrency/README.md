# The concurrency meter (INV-7)

Cross-tree isolation scenarios: two worktrees off the same base running full
audit -> PR -> merge cycles at the same time, and related tree-identity /
`.gaia/local` state-model checks. One `@test` per scenario in
`concurrency.bats`.

## Running

```bash
bash .gaia/tests/concurrency/meter-gate.sh
```

Runs the whole suite and fails on any scenario that does not report an
unconditional `ok` (a `skip` counts as a failure here: it reports green,
which is the opposite of what this meter means), and when bats itself exits
non-zero, since a run killed partway reports only the scenarios it reached.

Or read the raw suite by hand, without the gate:

```bash
.gaia/scripts/bats5.sh .gaia/tests/concurrency/
```

## Prerequisites

- `bats-core` on PATH.
- `pnpm install` at the repo root **and** `pnpm -C .gaia/cli install`: three
  scenarios (`C3-05`, `C4-04`, `C4-07`) drive real node code and need both
  installs to pass rather than red for want of a dependency.

## Files

- `concurrency.bats` — the suite.
- `meter-gate.sh` — the CI gate: runs the whole suite and fails on any
  non-`ok` result.
- `lib/concurrency-harness.sh` — the fixture builder: a main checkout plus N
  linked worktrees off one base, seeded `.gaia/local` state, real
  hooks/scripts/libs copied in at their repo-relative paths, and the runner
  helpers the suite sources.

## CI

`meter-gate.sh` runs as the whole of the `concurrency` leg of the sharded
`Audit CI Tests` workflow (`.github/workflows/audit-ci-tests.yml`), one of
the matrix legs the aggregator job waits on before it reports the required
context.
