# ci-shape integration fixture

The slice 2 acceptance fixture for SPEC-001. Exercises the
`gaia ci-stale-check` and `gaia ci-revert` CLI primitives end-to-end
against a mocked `gh` / `git` shell layer to verify UAT-009, UAT-010,
and UAT-019 without spawning real processes.

## What this fixture covers

| UAT | Scenario | Test file |
|---|---|---|
| UAT-009 | revert opens, ledger records the entry | `revert-flow.test.ts` |
| UAT-009 | hard cap: second `open` blocked, zero gh/git calls | `revert-flow.test.ts` |
| UAT-009 | unmerged PR refused with `pr_not_merged` | `revert-flow.test.ts` |
| UAT-010 | `mark-failed` flips ledger entry to `failed` | `revert-flow.test.ts` |
| UAT-010 | `is-cap-reached` returns true after `failed` | `revert-flow.test.ts` |
| UAT-010 | second `open` after `mark-failed` still blocked | `revert-flow.test.ts` |
| UAT-019 | both predicates passed to `gh pr list` | `stale-check.test.ts` |
| UAT-019 | `[]` response → `decision: "proceed"` | `stale-check.test.ts` |
| UAT-019 | `gh` failure → exit non-zero | `stale-check.test.ts` |

## How to run

```bash
# From the GAIA repo root:
( cd .gaia/cli && pnpm test --run ci-shape )
```

The vitest config at `.gaia/cli/vitest.config.ts` includes
`./test-fixtures/**/*.test.{ts,tsx}` so these tests run alongside the
in-tree unit tests. The `ci-shape` filter narrows to this fixture.

## How to run the opt-in shell smoke

```bash
GAIA_CI_SHAPE_E2E=1 bash .gaia/cli/test-fixtures/ci-shape/composite-actions.smoke.sh
```

The smoke runs `actionlint` on the two composite actions (wrapped in
synthetic consumer workflows because actionlint cannot lint composite
actions directly) and `shellcheck` on every `.sh` helper. It is **not**
wired into `pnpm test --run` because `actionlint` and `shellcheck` are
host tools (not pnpm dependencies); slice 3 will add a GH Actions
workflow that runs them on every PR.

## How to add a new scenario

1. Pick the test file that owns the relevant UAT
   (`revert-flow.test.ts` or `stale-check.test.ts`).
2. Copy the closest existing `it('...', ...)` block.
3. Change the discriminating fields:
   - The mock responses in `installGhMock({...})`.
   - The pre-populated ledger via `sandbox.writeLedger({...})` (if any).
   - The CLI argv passed to `run([...])`.
   - The expectations on `mock.ghCalls`, `mock.gitCalls`, and the
     ledger after.
4. Run `pnpm test --run ci-shape` to verify.

The fixture deliberately uses inline assertions instead of snapshots —
slice 2's invariants (the hard cap, the both-predicates rule) are too
load-bearing for snapshot drift to silently absorb.

## What this fixture does NOT cover

- The composite-action YAML itself. The shell smoke checks the YAML
  parses; the steps' bash logic is exercised on a real GH Actions
  runner, not in vitest.
- The polling helpers (`wait-for-merge.sh` / `wait-for-ci.sh`). They
  are pure shell; `shellcheck` is the only static analysis applied to
  them. Slice 3's per-tool workflows will exercise them on real PRs.
- Time-related ledger fields beyond `opened_at` — slice 2 doesn't
  introduce other timestamps.
