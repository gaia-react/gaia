---
type: decision
status: active
priority: 2
date: 2026-08-13
created: 2026-08-13
updated: 2026-08-25
tags: [decision, ci, performance, github-actions, bats]
---

# Decision: Sharded CI Test Matrix

`Audit CI Tests` is the whole pull-request critical path. It runs as a fan-out matrix of twelve legs plus a thin aggregator that carries the declared-required check name, because the bats work saturates a single runner's cores and the remaining lever is more runners.

## Shape

`.github/workflows/audit-ci-tests.yml` declares two jobs:

- `shards`, a matrix of twelve legs: ten bats shards (`hooks-1` to `hooks-4`, `scripts-1` to `scripts-3`, `audit`, `lib`, `misc`), the `.gaia/tests/sandbox` conformance tree, and the INV-7 concurrency meter.
- `audit-ci-tests`, which reads `needs.shards.result` and exits non-zero for anything other than `success`.

Splitting the required check name off the work is what lets `fail-fast: false` stop one failing shard from cancelling its siblings without also cancelling the check. The aggregator compares against `success` rather than enumerating failure states, so a conclusion GitHub adds later fails closed, and `always()` on its `if:` stops a skip-on-dependency-failure from satisfying a required context that ran nothing.

`.gaia/tests/bats-shards.sh` owns shard assignment by discovering `.bats` files rather than reading a manifest, so a newly added suite joins a shard automatically instead of silently running nowhere. `.gaia/tests/install-bats.sh` installs bats pinned by version and digest from a vendored archive under `.gaia/tests/vendor/`, so no leg fetches it.

### Exchange groups

The sharder also reports each shard's **exchange group**: the set of legs a file can move between without anyone editing the sharder. The two weighted groups (`hooks-2` to `hooks-4`, and `scripts-1` to `scripts-3`) exchange files among their own buckets on any size change; every other shard is a group of one, because its files are selected by name (`hooks-1`) or by whole directory (`audit`, `lib`, `misc`) and no reshuffle crosses that boundary. `bats-shards.sh group <shard-id>` answers it, and `bats-shards.bats` S14 proves the groups partition the shard set.

The group is the right granularity for anything that must survive a reshuffle. The workflow's `python3-yaml` and `zsh` install step is the case that needs it: exactly one suite in the whole hooks directory reaches for either package, so naming that suite's leg literally makes the step's list a function of every hooks suite's byte size, with no relationship to the packages. The step lists the needing legs rounded up to whole groups instead, which moves only when a suite's dependency really changes. `audit-ci-shards.bats` W10 recomputes that rounded set from the suites and compares it, as exact equality rather than a superset rule, so a gratuitously listed leg still reds.

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

`.gaia/tests/run-bats-parallel.sh` (the hand runner) and `.gaia/tests/bats-shards.sh` (the CI matrix) consume the same partition, so one entry-point set covers both: the hand runner's `builtin_table()` derives its rows from the sharder rather than carrying an independent copy, and expanding each side's own rows to a sorted list of `.bats` entry points resolves to the same set. `.gaia/tests/forensics/unit.bats`'s delegation to `.github/forensics/tests/` is identical on both sides of that comparison, so it cancels and the check is over entry points, not transitive coverage.

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

Measured per leg on a clean CI run: the aggregator takes about 3 seconds, and fixed per-leg overhead (runner provisioning, checkout, install) is on the order of 10 seconds. The install step spans roughly 10 to 20 seconds; the sandbox leg, which runs no apt, finishes it first. The concurrency leg runs 66 to 69 seconds against its 13-minute cap, so the cap constraint above binds the declared numbers rather than any real runtime.

A hand run is a different measurement, because it forks every shard onto one box. Timed one file at a time the whole suite is roughly 1280 seconds of work over 200 files against a heaviest shard near 160, but forked together on an eight-performance-core machine it finishes in about 200 seconds of wall clock, each shard reporting 20 to 30 percent longer than it costs alone. Splitting a group lowers the heaviest shard without lowering the total, so past roughly the core count it promises wall clock the box cannot deliver. The two axes part company there: CI gives every leg its own runner and realizes a rebalance in full, and a hand run realizes the part of it that fits in the cores it has.

Suite cost is uneven, which is why the shard split is not a naive equal division: the hooks and scripts directories dominate, and `local-janitor.bats` is heavy enough to be pinned alone as `hooks-1`.

Within each of those two directories the split is by **file size in bytes**, not by file count. Per-file setup dominates per-test work here, so counting files balances the wrong quantity: one 22-second suite holds 185 `@test` and another holds 1. Against a per-file timing of every suite, a file's size predicts its runtime at r=0.80 where its `@test` count manages r=0.42. The sharder walks each directory's files heaviest first and gives each to the lightest shard so far, which is a single deterministic pass over data it already has.

Two legs are irreducible on their own terms. `local-janitor.bats` is one file, which a file-level sharder cannot split, and the whole `audit` directory is one shard; timed a file at a time each runs about 150 seconds. That pair set the floor the group sizes were originally chosen against, and it no longer does. The scripts group has since grown suites that cost several times what their size predicts, because they drive an expensive external script once per test rather than doing work in proportion to their own text: `shell-lint.bats` ran about 310 seconds on CI against a 150-second floor and a 780-second cap, and `check-script-capabilities.bats` sits in the same class. `shell-lint.bats` reached that cap and was cancelled, reddening the aggregator on a dependency rather than on anything it ran (#1619).

Two properties of the r=0.80 correlation above are what let that happen, and neither is a defect in the sharder. It is a correlation and not an identity, so an outlier is expected rather than excluded; and it is measured over the tree as it stood, so a suite whose cost sits in what it invokes rather than in what it contains drifts away from it silently. The repair for such a suite is therefore its own runtime, not the partition: `shell-lint.bats` was running one whole-tree gate per assertion where one run served them all, and it now runs about 80 seconds beside a 125-second `shell-lint-bash32.bats` split off at the seam `--only bash32-parse` already names.

What is true after that repair, measured on CI rather than converted from a hand run, since the two clocks do not track each other: the two halves run 93 and 190 seconds where the single file ran about 310, and the group's heaviest shard is 580 seconds against the 780-second cap. That 580 is the unlucky draw rather than the typical one, the partition having put `check-script-capabilities.bats` and both halves in `scripts-1` together while the other two shards took 157 and 182 seconds. So the binding leg is whichever scripts shard holds `check-script-capabilities.bats`, not either of the two legs named above, and a fourth scripts shard would now lower it where the earlier sizing found it bought nothing. That option is foreclosed by the leg ceiling rather than by the floor: shards plus aggregator is already exactly what the poller window allows at two hops. So the lever that remains for this group is the one that worked here, a suite's own runtime, and the next candidate for it is the leg now doing the binding, whose own whole-tree differential is 95 seconds of its total.

The hooks group stops at three shards even though a fourth would lower its own heaviest shard, because the gain does not survive either axis. On CI, splitting hooks further only exposes the next constraint underneath it, worth a few seconds unless the `lib` directory is split as well, and the pair costs three more legs. On a hand run it is worth less than that, for the reason the paragraph below gives.

## Levers not taken, and why

- **A setup job that fetches shared state once.** Adds a third hop; see the ceiling above.
- **Per-shard narrowed paths filters.** Every leg shares one `steps:` block, so the filter is defined once and evaluated per leg. Narrowing per shard also breaks `.gaia/scripts/tests/workflow-filter-coverage.bats`, which requires every gate on a step to reach every literal path that step names, independently. `audit-ci-shards.bats` W7 pins the count at exactly one filter step.
- **A checked-in shard manifest.** Fails silently: a new suite runs in no shard, every check greens, the pass count quietly drops.
- **A checked-in table of per-file runtimes.** A better weight than file size, and the same silent-stale hazard as the manifest above wearing different clothes: a newly added suite weighs nothing, the shard holding it is under-counted, and nothing says so. Size is read from the tree at discovery time, so it is never stale and never absent.
- **A hand-maintained per-shard package list.** Also a silent-green hazard, because the suites that need `python3-yaml` fail rather than skip when it is absent while the ones needing `zsh` skip quietly. The step's list is derived from the suites instead, rounded up to whole exchange groups and pinned by W10; W9 pins the sandbox leg's reduced set.
- **`bats --jobs`.** A live lever rather than a closed question. The reasoning that excludes it, that the runner is already CPU-saturated, describes every shard sharing one box; a shard now runs one suite serially on its own four-core box, leaving cores idle.

## Fan-out has its own costs

Widening the matrix is not free, and two costs are measured rather than theoretical:

- **Shared-host bursts.** The legs that install a package run `apt-get update` within seconds of each other, and a mirror hash-sum mismatch on any one of them reds a declared-required context. The bats archive is vendored rather than fetched for exactly this reason: fetching it puts a second host in the same burst, and GitHub's codeload answers that burst with `503`s costing an affected leg roughly two minutes of backoff. Any change that adds legs, or that puts a fetch back on an install path, widens what is left.
- **Fixed overhead multiplies.** Each leg pays provisioning, checkout, and install. Below roughly a minute of real work, a leg is mostly overhead.

Total machine time rises with fan-out even as wall-clock falls. The thing being optimized here is human-facing latency on the critical path, not runner minutes.

## Related

- [[Dispatched-Check Rollup via Polling]] for the poller window this workflow's caps are derived from.
- [[Code Audit Team]] for the merge gate that runs alongside it.
- [[Quality Gate]] for the local gate, which has nothing to check on a YAML/bash/bats change.
