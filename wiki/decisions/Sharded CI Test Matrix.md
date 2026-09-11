---
type: decision
status: active
priority: 2
date: 2026-08-13
created: 2026-08-13
updated: 2026-09-11
tags: [decision, ci, performance, github-actions, bats]
---

# Decision: Sharded CI Test Matrix

`Audit CI Tests` is the whole pull-request critical path. It runs as a fan-out matrix of twelve legs plus a thin aggregator that carries the declared-required check name, because the bats work saturates a single runner's cores and the remaining lever is more runners.

## Shape

`.github/workflows/audit-ci-tests.yml` declares these jobs:

- `shards`, a matrix of twelve legs: ten bats shards (`hooks-1` to `hooks-4`, `scripts-1` to `scripts-3`, `audit`, `lib`, `misc`), the `.gaia/tests/sandbox` conformance tree, and the INV-7 concurrency meter.
- `hook-capabilities-live-tree` and `verb-arming-adoption`, standalone jobs that run alongside `shards` rather than depending on it. Each checks out full history (`fetch-depth: 0`) on every pull request and gates its own checker step on a hand-rolled `code` filter, neither of which matches a `wiki/` path. Their checkers already skip a wiki-only pull request; the checkout itself does not, and stays a fixed cost neither lever below removes. That is the honest bound on what narrowing this workflow saves.
- `audit-ci-tests`, the aggregator, which reads `shards`, `hook-capabilities-live-tree` and `verb-arming-adoption`'s results and exits non-zero for anything other than `success`.

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

Within each of those two directories the split is by **file size in bytes**, not by file count. Per-file setup dominates per-test work here, so counting files balances the wrong quantity: one 22-second suite holds 185 `@test` and another holds 1. Size is the better of the two proxies a pure discovery pass can compute, and it is a proxy rather than an identity. Timed one file at a time across the scripts directory, size predicts runtime at r=0.43 over the group as it stands, and at r=0.73 once the suites the sharder anchors are set aside: sound for the group's ordinary members, blind to its outliers. The sharder walks each directory's files heaviest first and gives each to the lightest shard so far, which is a single deterministic pass over data it already has.

Two legs are irreducible on their own terms. `local-janitor.bats` is one file, which a file-level sharder cannot split, and the whole `audit` directory is one shard; timed a file at a time each runs about 150 seconds. That pair set the floor the group sizes were originally chosen against, and it no longer does. The scripts group has since grown suites that cost several times what their size predicts, because they drive a whole-tree gate once per assertion rather than doing work in proportion to their own text.

Two properties of the correlation above are what let that happen, and neither is a defect in the sharder. It is a correlation and not an identity, so an outlier is expected rather than excluded; and it is computed from the tree at discovery time, so a suite whose cost sits in what it INVOKES rather than in what it contains drifts away from it silently. Two suites in the scripts group are in that class. Between them they carry better than a third of the group's wall clock while weighing almost nothing, and the next suite behind them costs under a quarter of either. Stated as shares rather than as counts because the group gains suites, and a count taken once goes quietly wrong where a share degrades gracefully. `.gaia/tests/bats-shards.sh` names them and carries the rule for what belongs in that set.

Splitting one of them along a seam it already has does not move that cost, which is the finding that matters here. A split divides the text, and the whole-tree runs stay with whichever half keeps them: the two halves come out around 287 and 15 seconds on a hand run rather than at any even division, and the larger half by bytes is the cheaper one by minutes. What a split does change is how many files the partition has to place, and placing them is where the failure was. Weighed by bytes these suites are unremarkable, so which bucket each takes is decided by the packing of everything around it, and a tree change anywhere in the group can put two of them on one leg. Co-located they exceed the per-shard cap, the job is cancelled with no failing assertion, and the aggregator reds on a cancelled dependency rather than on anything that ran.

So the sharder anchors them instead: each named outlier takes a bucket of its own before the byte walk fills the rest, which makes the collision unreachable rather than merely unlikely. Measured one file at a time over the whole scripts directory, the group moves from 535 / 257 / 592 seconds to 519 / 529 / 336, and the arrangement that matters is the one it removes: the same walk was free to produce an 830-second shard, and did. The cap is not the lever and never was. `.github/workflows/audit-ci-tests.yml` records that the per-shard cap plus the aggregator's is exactly what the self-heal poller window allows at two hops, so raising either reds the suite that checks the chain. A fourth scripts shard is a separate question from that ceiling, which bounds a chain's wall clock rather than the matrix's width; it is not needed while the outliers are held apart, and it would not have prevented the collision, since a wider byte walk still places them by weight. The lever that remains, if the group grows back into the cap, is a suite's own runtime: the heavier anchor spends most of its total re-driving whole-tree gates one assertion at a time.

The hooks group stops at three shards even though a fourth would lower its own heaviest shard, because the gain does not survive either axis. On CI, splitting hooks further only exposes the next constraint underneath it, worth a few seconds unless the `lib` directory is split as well, and the pair costs three more legs. On a hand run it is worth less than that, for the reason the paragraph below gives.

## Levers not taken, and why

- **A setup job that fetches shared state once.** Adds a third hop; see the ceiling above.
- **A checked-in shard manifest.** Fails silently: a new suite runs in no shard, every check greens, the pass count quietly drops.
- **A checked-in table of per-file runtimes.** A better weight than file size, and the same silent-stale hazard as the manifest above wearing different clothes: a newly added suite weighs nothing, the shard holding it is under-counted, and nothing says so. Size is read from the tree at discovery time, so it is never stale and never absent. The anchor list the sharder does carry is not this table in miniature: it holds no runtimes and changes no file's weight, an unlisted file weighs its bytes rather than nothing, and a listed file discovery cannot find is an error instead of a quiet no-op.
- **A hand-maintained per-shard package list.** Also a silent-green hazard, because the suites that need `python3-yaml` fail rather than skip when it is absent while the ones needing `zsh` skip quietly. The step's list is derived from the suites instead, rounded up to whole exchange groups and pinned by W10; W9 pins the sandbox leg's reduced set.
- **`bats --jobs`.** A live lever rather than a closed question. The reasoning that excludes it, that the runner is already CPU-saturated, describes every shard sharing one box; a shard now runs one suite serially on its own four-core box, leaving cores idle.

## Per-leg narrowing for wiki-only changes

Per-leg narrowing faces two objections. Every leg shares one `steps:` block, so the `code:` filter is defined once and its output is identical on every leg; per-shard narrowing therefore needs a per-leg GATE, not a second filter step. And it must not break `.gaia/scripts/tests/workflow-filter-coverage.bats`, which requires every gate on a step to reach every literal path that step names. Both are answered on their merits, not routed around.

The per-leg gate is a step output computed by one script, not a second `dorny/paths-filter` step, so the single filter step stays single, and the single-filter property `.gaia/tests/lib/audit-ci-shards.bats` pins stays untouched. `steps.filter.outputs.code == 'true'` stays a conjunct of every narrowed step's `if:`, and the script's output is an ADDITIONAL conjunct, never a replacement: `workflow-filter-coverage.bats`'s extractor only credits a gate whose producing step is a paths-filter step in the same job, so a gate-output-only `if:` would silently drop every narrowed step out of its literal-input and self-coverage assertions.

The narrowing is derived from the suites at run time, through the sharder's exchange groups, and defaults to arming the full matrix on anything it cannot resolve.

A file that names every page the narrowing can distinguish between contributes nothing to any single page's arming decision, and is excluded from the namer set of all of them. This is a real, accepted under-arming risk rather than a footnote: a suite that genuinely read every one of those pages would be excluded too, and would not arm on a change to any of them. No such suite exists today, the leg holding the suite that checks this narrowing arms unconditionally regardless, and every other rule in the decision order fails open, but the risk stands as stated.

The same rule carries an accepted cost in the safe direction. A path inventory that is written once and never regenerated is a namer of all only until the narrowing gains a page it does not name. From then on it arms its directory's legs for every page it does name, though it reads none of them. Every rule that would drop it tells one namer from another by a guess that under-arms when wrong, so the over-arming stands, bounded by what the frozen inventory names: a page added later reaches it only when its path or bare file name already occurs in the inventory.

Measured against the tree, the saving is runner-minutes before it is wall clock. Some pages are named only by `lib`'s own suites and arm that single leg, which moves both wall clock and runner-minutes; others also reach the scripts group, whose legs sit on the critical path, so narrowing to them moves runner-minutes only. `wiki/.state.json`, the file every wiki sync rewrites, would arm nearly the whole matrix through this lever alone.

A `code:` filter entry may be qualified by change type, and the `wiki/.state.json` entry is: a content-only rewrite of that file, which is what every wiki sync does to it, does not arm `code:` at all. What makes that safe is the checker the entry narrows against being blind to the file's content, not the entry being cheap; the invariant pinning that lives beside the per-leg gate's own invariants.

See `.gaia/tests/leg-arming.sh` for the decision, `.gaia/tests/bats-shards.sh` for the exchange groups it is derived through, and `.gaia/tests/lib/audit-ci-shards.bats` for what pins it, including the per-page armed-leg table.

## Fan-out has its own costs

Widening the matrix is not free, and two costs are measured rather than theoretical:

- **Shared-host bursts.** The legs that install a package run `apt-get update` within seconds of each other, and a mirror hash-sum mismatch on any one of them reds a declared-required context. The bats archive is vendored rather than fetched for exactly this reason: fetching it puts a second host in the same burst, and GitHub's codeload answers that burst with `503`s costing an affected leg roughly two minutes of backoff. Any change that adds legs, or that puts a fetch back on an install path, widens what is left.
- **Fixed overhead multiplies.** Each leg pays provisioning, checkout, and install. Below roughly a minute of real work, a leg is mostly overhead.

Total machine time rises with fan-out even as wall-clock falls. The thing being optimized here is human-facing latency on the critical path, not runner minutes.

## Related

- [[Dispatched-Check Rollup via Polling]] for the poller window this workflow's caps are derived from.
- [[Code Audit Team]] for the merge gate that runs alongside it.
- [[Quality Gate]] for the local gate, which has nothing to check on a YAML/bash/bats change.
