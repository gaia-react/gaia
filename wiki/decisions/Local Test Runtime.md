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

The two local pre-merge gates, `.gaia/tests/whole-tree-invariants.sh` and the
`shell-lint.sh` member it includes, run their own units concurrently rather
than in a loop, and each concurrent stage nests inside the one above it. This
page records why, what bounds each level, the negative result on the full bats
corpus, and the two related non-claims a reader is likely to reach for next.

## Why the gates are parallel

Neither gate can shrink the work it does: `whole-tree-invariants.sh` runs
every check whose input is the whole tracked tree, and `shell-lint.sh` runs
shellcheck plus a folded set of custom lints over every tracked shell and
bats file. What both can do is stop paying for that work serially. Forking
each gate's units into a bounded pool overlaps them on the host's cores
instead of running one after another, which is a real win only when the
units genuinely vary in cost: a handful of expensive units account for most
of the wall clock in both gates, and a large remainder costs very little
between them.

## The concurrency budget

Three levels nest by the time a full `whole-tree-invariants.sh` run is
underway:

- The outer level forks `whole-tree-invariants.sh`'s own members, bounded by
  `WTI_JOBS`.
- One of those members is `shell-lint.sh`, which forks its own shellcheck
  passes and its folded guards, bounded by its own `JOBS`.
- Another of those members is the shard-partition bats suite, which bats
  itself forks under `--jobs`, bounded by `WTI_BATS_JOBS`.

Each bound is a resolver with a documented default and floor, not a literal
kept here: `whole-tree-invariants.sh`'s own header carries the reasoning for
its cap and for why it nests the way it does, and running `--list` on either
gate reports the live unit set. This page does not restate either, because a
second copy is a second thing to keep current and the runner's own header is
what cannot go stale.

`shell-lint.sh`'s guards and the shard-partition suite are two different
things that both happen to source a bats parallel backend or an alternate
awk interpreter when one is available. Neither backend is required:
`.gaia/tests/README.md` documents what each buys and states plainly that
adopters never need either, since none of the files that use them ship.

## `whole-tree-invariants.sh` reports its own cost

The runner's own runtime paragraph is a hand-kept sample, and nothing
machine-checks it against actual cost: the one machine-checked lever is a
member-count comparison, which catches a member added or removed without the
paragraph being revisited, and says nothing about a member that changed cost
while holding its place. So every full run also prints its own measured
aggregate alongside the configuration that produced it, unconditionally, with
no threshold and no comparison against the paragraph. That is what makes a
stale figure visible to whoever is already looking at a run, rather than only
to someone who goes back to re-measure it by hand. The runner's own header
gives the fuller reasoning, including why a thresholded warning was
considered and rejected: it would fire on every configuration this runner is
built to support running correctly under, which turns a signal into a notice
nobody reads.

## The awk interpreter pin's stated non-claim

`mawk` measurably outperforms the platform-default `awk` on the specific
guards that tokenize shell source, and `.gaia/scripts/awk-interp-lib.sh`
resolves an interpreter for exactly that closure: itself and the guards that
source it through `.gaia/scripts/guard-awk-lib.sh`. `gawk` is rejected as a
candidate on the same measurement basis, not on the usual expectation about
it: it is slower than the platform default on this workload, so it is never
resolved automatically and is not offered as a fallback.

The resolver, and the guard that pins every awk invocation in its closure to
what it resolves, both govern that closure and nothing wider. Further
command-position awk sites exist elsewhere in `.gaia/scripts/` and
`.gaia/tests/`, in files that do not source `guard-awk-lib.sh`, and a
meaningful share of those files ship to adopters, where a maintainer-only
resolver cannot exist at all. Widening either the resolver or its guard to
reach them is a materially larger conversion than either currently is, and
the divergence closed here was measured on the tokenizer guards specifically.
Both files' own headers carry the fuller argument and derive their surface
from the tree rather than from a count kept here.

## The oracle-blind tokenizer is the named floor

One guard, `lint-oracle-blind-invocations.sh`, does not benefit from either
lever above: its cost is a hand-rolled character tokenizer written in pure
bash rather than in awk, so an alternate awk interpreter changes nothing
about it, and it remains the single most expensive unit in the folded guard
phase. Rewriting that tokenizer in awk is a plausible win, tracked as its own
piece of work in [gaia-react/gaia#2230](https://github.com/gaia-react/gaia/issues/2230)
rather than folded into the levers above, because it is a rewrite of a guard
whose correctness matters and carries its own adversarial-fixture burden
independent of anything here.

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

One consequence worth carrying forward: because the shard-partition suite
that `whole-tree-invariants.sh` includes now also forks under `--jobs`, running
that gate and a full corpus run at the same time contends for cores more than
it used to. Don't run them concurrently.

## Related

- [[Sharded CI Test Matrix]] for the CI-side matrix this page's full-corpus
  finding is distinct from: that page's own "Levers not taken" section
  already covers `bats --jobs` for the CI matrix specifically, on different
  constraints than a single hand-run box.
- [[Quality Gate]] for the local gate this page's runners sit alongside.
