---
type: decision
status: active
priority: 3
date: 2026-09-22
created: 2026-09-22
updated: 2026-09-22
tags: [decision, testing, performance, shell, bats]
---

# Decision: Local Test Runtime

The local pre-merge gate is the verification runner's branch mode
(`.gaia/tests/verify-harness.sh`), of which `.gaia/tests/shell-lint.sh` is one
check. `shell-lint.sh` runs its shellcheck passes concurrently rather than in a
loop; its folded guards run in a fixed serial sequence instead. This page records why the shellcheck passes are
parallel, what bounds that concurrency, the negative result on the full bats
corpus, and the two related non-claims a reader is likely to reach for next.

## Why the shellcheck passes are parallel

`shell-lint.sh` cannot shrink the shellcheck work it does: it runs shellcheck
over every tracked shell and bats file, and one shellcheck invocation is
single-threaded and CPU-bound. Splitting each pass's file list across a
bounded pool of workers costs roughly the longest chunk instead of the whole
list on one core.

The gate's folded guards (`.gaia/scripts/lint-*.sh`) run one after another
in the order the gate declares. Together they cost a few seconds more than
their slowest member, too little to justify a second pool with its own
stream capture and replay.

## The concurrency budget

`shell-lint.sh` forks its own shellcheck passes, bounded by its own `JOBS`;
its folded guards run serially and need no such bound. The `JOBS` bound is a
resolver with a documented default and floor, not a literal kept here: the
script's own header carries the reasoning for its cap. This page does not
restate it, because a second copy is a second thing to keep current and the
runner's own header is what cannot go stale.

`shell-lint.sh`'s guards source a bats parallel backend or an alternate awk
interpreter when one is available. Neither backend is required: adopters
never need either, since none of the files that use them ship.

## The awk interpreter resolver's stated non-claim

`mawk` measurably outperforms the platform-default `awk` on the specific
guards that tokenize shell source, and `.gaia/scripts/awk-interp-lib.sh`
resolves an interpreter for exactly that closure: itself and the guards that
source it through `.gaia/scripts/guard-awk-lib.sh`. `gawk` is rejected as a
candidate on the same measurement basis, not on the usual expectation about
it: it is slower than the platform default on this workload, so it is never
resolved automatically and is not offered as a fallback.

The resolver governs that closure and nothing wider. Further command-position
awk sites exist elsewhere in `.gaia/scripts/` and `.gaia/tests/`, in files
that do not source `guard-awk-lib.sh`, and a meaningful share of those files
ship to adopters, where a maintainer-only resolver cannot exist at all.
Widening the resolver to reach them is a materially larger conversion than it
currently is, and the divergence closed here was measured on the tokenizer
guards specifically. The resolver's own header carries the fuller argument
and derives its surface from the tree rather than from a count kept here.

## The full bats corpus: no scheduling win exists

Running every `.bats` suite in the repository, sharded across the available
cores, is CPU-saturated: the shards are reasonably well balanced, and the
worst-case shard's own wall clock sits at almost exactly the whole run's wall
clock, which is what a well-packed partition looks like. Forking `--jobs`
inside a shard on top of that only redistributes the same CPU across more
processes; it does not add capacity the host does not have. The parallel
efficiency across the available cores lands around 6x, well short of the
core count, and the per-test cost implied by the total (dividing wall-clock
CPU-seconds by the number of tests run) is a fraction of a CPU-second, which
is bats' own per-test overhead: a fresh subshell per test, `run`'s own forks,
setup and teardown, and a temp directory per test.

**This is a decided non-goal.** The only lever left on that number is fewer
or cheaper fixtures, which is a test-design question for whatever suite is
heaviest, not a scheduling question this decision covers. Nothing here
schedules the full corpus differently, and re-deriving this as an
infrastructure task from the raw wall-clock figure alone is the mistake this
section exists to prevent.

The runner's branch mode does not reopen this: it runs the suites tagged
`whole-tree` plus the suites the change selector picks for the branch, never
the full corpus, so the non-goal stands.

One consequence worth carrying forward: the shard-partition suite itself
forks under `--jobs`, so running it and a full corpus run at the same time
contends for cores. Don't run them concurrently.

## Related

- [[Sharded CI Test Matrix]] for the CI-side matrix this page's full-corpus
  finding is distinct from: that page's own "Levers not taken" section
  already covers `bats --jobs` for the CI matrix specifically, on different
  constraints than a single hand-run box.
- [[Quality Gate]] for the local gate this page's runners sit alongside.
