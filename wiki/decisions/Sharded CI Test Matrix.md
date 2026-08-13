---
type: decision
status: active
priority: 2
date: 2026-08-13
created: 2026-08-13
updated: 2026-08-13
tags: [decision, ci, performance, github-actions, bats]
---

# Decision: Sharded CI Test Matrix

`Audit CI Tests` is the whole pull-request critical path. It runs as a fan-out matrix of eleven legs plus a thin aggregator that carries the declared-required check name, because the bats work saturates a single runner's cores and the remaining lever is more runners.

## Shape

`.github/workflows/audit-ci-tests.yml` declares two jobs:

- `shards`, a matrix of eleven legs: nine bats shards (`hooks-1` to `hooks-4`, `scripts-1`, `scripts-2`, `audit`, `lib`, `misc`), the `.gaia/tests/sandbox` conformance tree, and the INV-7 concurrency meter.
- `audit-ci-tests`, which reads `needs.shards.result` and exits non-zero for anything other than `success`.

Splitting the required check name off the work is what lets `fail-fast: false` stop one failing shard from cancelling its siblings without also cancelling the check. The aggregator compares against `success` rather than enumerating failure states, so a conclusion GitHub adds later fails closed, and `always()` on its `if:` stops a skip-on-dependency-failure from satisfying a required context that ran nothing.

`.gaia/tests/bats-shards.sh` owns shard assignment by discovering `.bats` files rather than reading a manifest, so a newly added suite joins a shard automatically instead of silently running nowhere. `.gaia/tests/install-bats.sh` installs bats pinned by version and digest from a vendored archive under `.gaia/tests/vendor/`, so no leg fetches it.

## The constraint any further restructuring hits first

The `needs:` chain sits at **exactly its ceiling with zero headroom**, and this is the first thing to check before proposing any new CI structure here.

- The self-heal poller window is 25 minutes (see [[Dispatched-Check Rollup via Polling]]).
- `.gaia/scripts/tests/retrigger-reachability.bats` charges `POLLER_MARGIN_MIN=5` **per hop**, so the ceiling is `25 - 5 x hops`. At two hops that is 15 minutes.
- The caps are 13 (shards) + 2 (aggregator) = 15. Exactly the ceiling.

Consequences, each load-bearing:

- **A third hop is unavailable.** Any design that inserts a job between or before these two drops the ceiling to 10 minutes while raising the chain total, and reds that suite immediately.
- **Neither cap can rise** without the other falling by the same amount.
- **An expression-valued `timeout-minutes` reads as uncapped** and reds, so caps stay integer literals.

The zero headroom is deliberate: it fails loudly and locally rather than silently, and the heaviest leg gets a 13-minute budget on a box it no longer shares.

## Measuring this workflow

Two traps make naive measurement useless:

- **Push-to-`main` runs skip.** The job's `if:` admits only `pull_request` and `workflow_dispatch`, so a push run completes in about a second with no duration and no logs. `gh run list --branch main` yields nothing usable; source baselines from `--event pull_request`.
- **`Per-suite results:` reports exit codes, not counts.** The `0 in Ns` figure is the suite's exit status plus elapsed seconds. Assertion counts come from the TAP plan lines (`1..N`) that follow each `##[group]` header, or by counting `ok ` lines per job.

A useful reconciliation is the sum of per-shard TAP plans against the pre-existing per-directory totals: a partition change that loses a file shows up as a count drop, where every check still greens.

## Entry-point equivalence

`.gaia/tests/run-bats-parallel.sh` (the hand runner) and `.gaia/tests/bats-shards.sh` (the CI matrix) consume the same nine-shard partition, so one entry-point set covers both: the hand runner's `builtin_table()` derives its rows from the sharder rather than carrying an independent copy, and expanding each side's own rows to a sorted list of `.bats` entry points resolves to the same set. `.gaia/tests/forensics/unit.bats`'s delegation to `.github/forensics/tests/` is identical on both sides of that comparison, so it cancels and the check is over entry points, not transitive coverage.

The workflow's own `shards` matrix is pinned to the sharder's shard list by `audit-ci-shards.bats` W6, so the sharder stands in for the CI side below.

Reproduce the check on any tree, comparing the two live expansions rather than two points in history:

```bash
bash -c '
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
hand="$(mktemp)"; ci="$(mktemp)"
( . .gaia/tests/run-bats-parallel.sh; builtin_table ) | cut -f3 |
  while read -r _bash _sharder _run id; do bash .gaia/tests/bats-shards.sh files "$id"; done |
  LC_ALL=C sort > "$hand"
bash .gaia/tests/bats-shards.sh shards |
  while read -r id; do bash .gaia/tests/bats-shards.sh files "$id"; done |
  LC_ALL=C sort > "$ci"
diff "$hand" "$ci" && echo IDENTICAL
'
```

The hand side expands the rows `builtin_table()` actually emits rather than asking the sharder for its id list twice, which is what keeps the check live: a runner that emitted eight rows, or the wrong ids, reds it.

## Where the time goes

Measured per leg on a clean run: the slowest shard is around 154 seconds, the aggregator about 3, and fixed per-leg overhead (runner provisioning, checkout, install) is on the order of 10 seconds. The install step spans roughly 10 to 20 seconds; the sandbox leg, which runs no apt, finishes it first. The concurrency leg runs 66 to 69 seconds against its 13-minute cap, so the cap constraint above binds the declared numbers rather than any real runtime.

Suite cost is uneven, which is why the shard split is not a naive equal division: the hooks and scripts directories dominate, and `local-janitor.bats` is heavy enough to be pinned alone as `hooks-1`.

## Levers not taken, and why

- **A setup job that fetches shared state once.** Adds a third hop; see the ceiling above.
- **Per-shard narrowed paths filters.** All eleven legs share one `steps:` block, so the filter is defined once and evaluated per leg. Narrowing per shard also breaks `.gaia/scripts/tests/workflow-filter-coverage.bats`, which requires every gate on a step to reach every literal path that step names, independently. `audit-ci-shards.bats` W7 pins the count at exactly one filter step.
- **A checked-in shard manifest.** Fails silently: a new suite runs in no shard, every check greens, the pass count quietly drops.
- **A per-shard package list.** Also a silent-green hazard, because the suites that need `python3-yaml` fail rather than skip when it is absent while the ones needing `zsh` skip quietly. The install is split by leg kind instead, and W9 pins the sandbox leg's reduced set.
- **`bats --jobs`.** A live lever rather than a closed question. The reasoning that excludes it, that the runner is already CPU-saturated, describes nine shards sharing one box; a shard now runs one suite serially on its own four-core box, leaving cores idle.

## Fan-out has its own costs

Widening the matrix is not free, and two costs are measured rather than theoretical:

- **Shared-host bursts.** Ten of the eleven legs run `apt-get update` within seconds of each other, and a mirror hash-sum mismatch on any one of them reds a declared-required context. The bats archive is vendored rather than fetched for exactly this reason: fetching it puts a second host in the same burst, and GitHub's codeload answers that burst with `503`s costing an affected leg roughly two minutes of backoff. Any change that adds legs, or that puts a fetch back on an install path, widens what is left.
- **Fixed overhead multiplies.** Each leg pays provisioning, checkout, and install. Below roughly a minute of real work, a leg is mostly overhead.

Total machine time rises with fan-out even as wall-clock falls. The thing being optimized here is human-facing latency on the critical path, not runner minutes.

## Related

- [[Dispatched-Check Rollup via Polling]] for the poller window this workflow's caps are derived from.
- [[Code Audit Team]] for the merge gate that runs alongside it.
- [[Quality Gate]] for the local gate, which has nothing to check on a YAML/bash/bats change.
