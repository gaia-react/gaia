# react-perf fixtures

Raw render dumps that exercise `gaia react-perf reduce` (see
`src/react-perf/reduce.ts` and its colocated `reduce.test.ts`). The reduce is
the deterministic middle layer of the `/gaia-react-perf` diagnostic: it turns a
large raw bippy capture into a small ranked `ReducedSummary` so the raw dump
never enters the model context.

## Files

| File                      | Provenance                                                     | Role                                                                                          |
| ------------------------- | -------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `bippy-renders-dump.json` | bippy 0.5.42 spike capture of a language-switch navigation.    | PRIMARY input fixture. 248 records, a clean navigation with NO planted bug.                    |
| `memo-defeat.json`        | Authored from the fixloop `StatusBadge` memo-defeat fingerprint. | The `memoDefeated` path: exactly one memo-defeated culprit plus a legitimate parent change.  |
| `renders-dump.json`       | react-scan baseline capture of the same flow.                  | NEGATIVE / shape-divergence fixture. A different record shape the reduce must reject cleanly. |

## `bippy-renders-dump.json` (legacy capture caveat)

Captured with an OLDER harness, so its records carry only
`seq, componentName, phase, selfTime, totalTime, didCommit, didRender,
unnecessary, changedTotal, propsChanged, stateChanged, contextChanged` (each
change entry does carry `unstable`). It does NOT carry `isMemo`, `kind`, `tag`,
or `fiberId`, and has ZERO `memoDefeated` records. Its envelope is
`{afterLoad, meta, total, all}` and its `meta` is `{installed, commits,
errors}` only. The reduce INPUT schema is deliberately permissive (memo record
fields optional; newer meta fields optional with defaults; unknown keys
tolerated) precisely so this legacy dump and the newer Phase-1 dump both parse.

Exercises: framework noise filter, ranking, frame-budget gate, mount-vs-update
bucketing, `Unknown` bucketing, deterministic output, and output schema
validity. A record lacking `isMemo` can never be `memoDefeated`, so this
fixture yields `totals.memoDefeated === 0` and `stopSignal.zeroAppMemoDefeated
=== true`.

## `memo-defeat.json`

A minimal authored dump reproducing the fixloop spike's memo-defeat
fingerprint: a `React.memo`'d `StatusBadge` fed a same-shape, new-reference
`status` object prop (`isMemo: true`, `propsChanged` unstable) by a parent
`SpikePanel` whose own `useState` change is legitimate (`isMemo: false`,
`stateChanged` stable). The reduce flags exactly one finding (`StatusBadge`,
`reactDoctorRule: jsx-no-new-object-as-prop`, rank 1) and must NOT flag the
parent state change.

## `renders-dump.json` (alien shape)

react-scan's auto-build dump. Top-level `{total, cut, all}` with NO `meta`, and
records shaped `{phaseLabel, time, fps, forget, changes, ...}` with `phase` as
a number. The reduce input schema requires `meta` and string `phase`, so this
dump is rejected with a structured `invalid_dump` error. It is NOT a valid
reduce input; it only proves the reject path.
