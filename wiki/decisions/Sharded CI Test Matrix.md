---
type: decision
status: active
priority: 2
date: 2026-08-13
created: 2026-08-13
updated: 2026-10-25
tags: [decision, ci, performance, github-actions, bats]
---

# Decision: Sharded CI Test Matrix

The `GAIA: Audit CI Tests` workflow is the whole pull-request critical path. It runs as a fan-out matrix of legs plus a thin aggregator that carries the declared-required check name, because the bats work saturates a single runner's cores and the remaining lever is more runners. A pull request runs each bats leg change-scoped unless it touches harness machinery; every push to `main` and every manual dispatch runs every leg whole.

## Shape

`.github/workflows/audit-ci-tests.yml` declares these jobs:

- `shards`, a matrix whose legs are named in the workflow's `matrix.shard` list: the bats shards (assigned by `.gaia/tests/bats-shards.sh`), the `.gaia/tests/sandbox` conformance tree, the INV-7 concurrency meter, and the `commitlint` leg, which installs only the root workspace and runs the `.gaia/tests/commitlint/` suites against the real commitlint binary.
- `audit-ci-tests`, the aggregator, which reads `shards`'s result and exits non-zero for anything other than `success`.
- `report-main-status`, which runs on a push to `main` only and keeps a red-main issue current (see [[#Main is re-tested on every push]]).

Splitting the required check name off the work is what lets `fail-fast: false` stop one failing shard from cancelling its siblings without also cancelling the check. The aggregator compares against `success` rather than enumerating failure states, so a conclusion GitHub adds later fails closed, and `always()` on its `if:` stops a skip-on-dependency-failure from satisfying a required context that ran nothing.

`.gaia/tests/bats-shards.sh` owns shard assignment by discovering `.bats` files rather than reading a manifest, so a newly added suite joins a shard automatically instead of silently running nowhere. `.gaia/tests/install-bats.sh` installs bats pinned by version and digest from a vendored archive under `.gaia/tests/vendor/`, so no leg fetches it.

### Exchange groups

The sharder also reports each shard's **exchange group**: the set of legs a file can move between without anyone editing the sharder. The two weighted groups (`hooks-2` to `hooks-4`, and `scripts-1` to `scripts-4`) exchange files among their own buckets on any size change; every other shard is a group of one, because its files are selected by name (`hooks-1`) or by whole directory (`audit`, `lib`, `misc`) and no reshuffle crosses that boundary. `bats-shards.sh group <shard-id>` answers it, and `bats-shards.bats` S14 proves the groups partition the shard set.

The group is the right granularity for anything that must survive a reshuffle. The workflow's `python3-yaml` and `zsh` install step is the case that needs it: naming a needing suite's leg literally makes the step's list a function of the byte size of every suite in that suite's group, with no relationship to the packages. The step lists the needing legs rounded up to whole groups instead, which moves only when a suite's dependency really changes. `audit-ci-shards.bats` W10 recomputes that rounded set from the suites and compares it, as exact equality rather than a superset rule, so a gratuitously listed leg still reds.

## The job caps

Every job declares an integer-literal `timeout-minutes` cap, and every `run:` step of the `shards` job declares its own, and `audit-ci-shards.bats` W5 checks both: an expression-valued cap reads as uncapped and reds, so caps stay integer literals, and each step cap sits strictly below the job cap. A matrix takes one job cap for every leg, so it is the outer bound sized to the heaviest leg's whole run, installs included. What fails a hung leg at its own bound is the step cap, and because a step literal cannot come from the matrix, the bats run is split into one step per group of legs: the hooks group at 9 minutes, the scripts group and the single-shard legs at 12, and the sandbox, concurrency meter and commitlint steps at 2. Each literal is sized from the measured whole-shard p95 of its group on pull-request runs; the hooks group has about 1.25 times headroom, while the scripts group and the single-shard legs sit near 1.07 times and are accepted at that margin until a shard rebalance lands. The aggregator and the reporter carry their own small caps. The workflow's own comments hold the sizing reasoning for each number.

## Measuring this workflow

Two traps make naive measurement useless:

- **Event mixes the baseline.** A push-to-`main` run and a dispatch run every leg whole, while a pull request usually runs a change-scoped share, so a duration is comparable only within one event and one scope. Push runs are the clean whole-matrix baseline (`gh run list --branch main --event push`); read a pull-request duration against the scope of its change.
- **`Per-suite results:` reports exit codes, not counts.** The `0 in Ns` figure is the suite's exit status plus elapsed seconds. Assertion counts come from the TAP plan lines (`1..N`) that follow each `##[group]` header, or by counting `ok ` lines per job.

A useful reconciliation is the sum of per-shard TAP plans against the pre-existing per-directory totals: a partition change that loses a file shows up as a count drop, where every check still greens.

## Entry-point equivalence

`.gaia/tests/bats-shards.sh` is the one entry point: it derives the shard list and, per shard, the `.bats` files that belong to it, and the workflow's own `shards` matrix is pinned to that shard list by `audit-ci-shards.bats` W6. A hand run drives the same script (`bash .gaia/tests/bats-shards.sh run <shard-id>`, once per shard) rather than a separate runner carrying its own copy of the partition, so there is nothing for a second entry point to drift out of step with.

## Change-scoped legs

The workflow's paths filter has two outputs that arm the bats legs. `code` holds harness machinery only, the files that decide which suites run and how, and runs every leg whole; its list equals the change classifier's static harness list (`bash .gaia/tests/bats-change-scope.sh --list-harness-paths`). `scoped` names files whose readers the change selector (`.gaia/scripts/bats-suites-for-change.sh`) can find: each suite that reads one names it, or carries the whole-tree mark. A pull request matching `scoped` and nothing in `code` runs each leg through `bats-shards.sh run-for-change`, which hands bats the leg's suites the selector picks, in full, and the leg's other whole-tree-marked suites filtered to the whole-tree tag. That is the set `verify-harness.sh` runs in branch mode, split across the same legs the full run uses, so the weighted partition still balances it. The concurrency meter runs as it does for `code`. A dependency install input is not harness machinery: it is in `scoped`, and it additionally arms the suites marked as reading installed dependencies, which the Chromium and workspace-package suites carry because they name none of those inputs. The classifier owns which paths are install inputs. A leg plans its suites before it installs anything, and each install step is gated on that plan, so a leg whose selection is empty installs nothing and a leg installs the root workspace only when a suite it runs needs it. The filter's own comments say which files belong in `scoped` and why.

Keeping the fan-out is the point. The whole-tree tests alone take minutes on one runner, so a single "changed suites" leg would trade the full matrix's critical path for one nearly as long. Split across the legs, a wiki sync or a frontend component change owes each leg a fraction of its suites.

A selector that cannot read the change makes the leg run its whole shard, the direction that costs time rather than coverage. The limit is what neither the selector nor the mark guard can see: the guard follows a test into a script or helper it calls, but a test that reaches the tracked tree by a path it builds at run time is invisible to both, so it runs on a scoped change only if its author marked it by hand. The full run on every push to `main` is the backstop, and its red lands there rather than on the pull request. The guard header owns the idioms and hops it recognizes.

## Main is re-tested on every push

A push to `main` runs every leg whole, so each merge gets a verdict on exactly the tree it produced. The workflow's concurrency group is the commit for a push and the ref for a pull request: a push run is never cancelled or dropped as pending behind a later merge, and a pull request still cancels its superseded run.

The `report-main-status` job turns a red verdict into one open issue labeled `ci-red-main`. Its logic lives in `.gaia/tests/report-main-status.sh`, tested under bats with a stubbed `gh`; the job only hands it the run's facts through `env:`.

- A failed push run opens the issue when none is open, naming the run, the commit range and the failing legs from the jobs listing.
- A failed push run with an issue already open comments on it.
- A green push run closes the issue with a link when its commit is the red commit or a descendant of it.
- A cancelled or skipped run does nothing, and a green run with no open issue writes nothing.

The job's group is one static, non-cancelling group, so two red runs finishing together cannot both open an issue. GitHub keeps one pending run per group, so a pending reporter replaced by a newer one reports nothing for the replaced run; the newer run tests a superset of that commit and reports in its place. The job holds the workflow's only write scope, `issues: write`, with `actions: read` for the jobs listing and a checkout that persists no credentials.

The label name and the workflow name are stable names other tooling reads; renaming either breaks that tooling silently.

## Where the time goes

Measured per leg on a clean CI run: the aggregator takes about 3 seconds, and fixed per-leg overhead (runner provisioning, checkout, install) is on the order of 10 seconds. The install step spans roughly 10 to 20 seconds; the sandbox leg, which runs no apt, finishes it first. The concurrency leg runs 66 to 69 seconds against its 13-minute cap, so the declared cap, not any real runtime, is what sizes the leg.

A hand run is a different measurement, because it forks every shard onto one box. Timed one file at a time the whole suite is roughly 1280 seconds of work over 200 files against a heaviest shard near 160, but forked together on an eight-performance-core machine it finishes in about 200 seconds of wall clock, each shard reporting 20 to 30 percent longer than it costs alone. Splitting a group lowers the heaviest shard without lowering the total, so past roughly the core count it promises wall clock the box cannot deliver. The two axes part company there: CI gives every leg its own runner and realizes a rebalance in full, and a hand run realizes the part of it that fits in the cores it has.

Suite cost is uneven, which is why the shard split is not a naive equal division: the hooks and scripts directories dominate, and `local-janitor.bats` is heavy enough to be pinned alone as `hooks-1`.

Within each of those two directories the split is by **file size in bytes**, not by file count. Per-file setup dominates per-test work here, so counting files balances the wrong quantity: one 22-second suite holds 185 `@test` and another holds 1. Size is the better of the two proxies a pure discovery pass can compute, and it is a proxy rather than an identity. Timed one file at a time across the scripts directory, size tracks runtime only loosely: right on average, and wrong for a suite whose cost lives in a command it runs per test rather than in its own text. The sharder walks each directory's files heaviest first and gives each to the lightest shard so far, which is a single deterministic pass over data it already has.

Two legs are irreducible on their own terms. `local-janitor.bats` is one file, which a file-level sharder cannot split, and the whole `audit` directory is one shard; timed a file at a time each runs about 150 seconds. That pair set the floor the group sizes were originally chosen against, and it no longer does. The scripts group has since grown suites that cost several times what their size predicts, because they drive a whole-tree gate once per assertion or build a fixture repository per test rather than doing work in proportion to their own text.

Two properties of the correlation above are what let that happen, and neither is a defect in the sharder. It is a correlation and not an identity, so an outlier is expected rather than excluded; and it is computed from the tree at discovery time, so a suite whose cost sits in what it INVOKES rather than in what it contains drifts away from it silently. Several suites in the scripts group are in that class, and the heaviest of them each cost more than a fifth of an evenly split leg. Stated as a share rather than as a count because the group gains suites, and a count taken once goes quietly wrong where a share degrades gracefully. `.gaia/tests/bats-shards.sh` carries the rule for which of them, if any, earns a bucket of its own.

Splitting one of them along a seam it already has does not move that cost, which is the finding that matters here. A split divides the text, and the whole-tree runs stay with whichever half keeps them: the two halves come out around 287 and 15 seconds on a hand run rather than at any even division, and the larger half by bytes is the cheaper one by minutes. What a split does change is how many files the partition has to place, and placing them is where the failure was. Weighed by bytes these suites are unremarkable, so which bucket each takes is decided by the packing of everything around it, and a tree change anywhere in the group can put two of them on one leg. Co-located they exceed the per-shard cap, the job is cancelled with no failing assertion, and the aggregator reds on a cancelled dependency rather than on anything that ran.

An anchor answers that placement risk by giving a named suite a bucket of its own before the byte walk fills the rest, which makes a collision among the named suites unreachable rather than merely unlikely. The scripts group anchors a single suite, the heaviest in the group by far, which runs its script against a fixture repository in every test (`.gaia/tests/bats-shards.sh` names it). Left to the byte walk it can share a leg with the next heaviest suite and run that leg past the per-shard cap; replayed against two CI runs' per-file timings of one tree, anchoring it alone takes the slowest scripts leg from about 720 seconds to about 565, and no longer list does better on either run. Beyond a suite that heavy, an anchor list beats the plain walk there only by perturbing how the unnamed suites pack around it: the list that group last carried gives a 536-second slowest leg where the plain walk gives 499, against a floor near 370 for an even split of the same work. A win of that kind belongs to one tree, and the next size change anywhere in the group takes it back.

The lever that holds is a suite's own runtime. The heaviest scripts suites spend most of their total on setup rather than on what they assert: a fixture repository rebuilt for every test, or a whole-tree check a test runs without reading its result. Building each fixture once per file and copying it per test, and stubbing the checks a test does not assert on, puts the group near 1110 seconds of bats on CI against about 1460 with per-test fixtures; the two sandbox-driven suites run 93 and 52 seconds against 143 and 118, and the lint suite 31 against 70. With per-test fixtures, five CI runs put the slowest scripts leg at a median of 647 seconds, over three quarters of the per-shard cap in four of them. With per-file fixtures and no anchors, two CI runs of one tree put the slowest scripts leg at 626 and 493 seconds, and the slowest leg of the matrix at 626 and 514. Both runs place every suite identically, so the spread is run-to-run variance and not placement. Which anchor list replays best also flips from one run's timings to another's, so one run's timings are not enough to choose a list. Every figure in this paragraph is from three scripts legs. The cap is not the lever and never was, and suite runtime only holds while the suites grow no faster than fixture work saves. The scripts group runs four shards because the light-route and light-mark suites grew until the byte walk put about 13.5 minutes of tests on one of three legs, past the 13-minute per-shard cap, and that leg was cancelled. Replayed against the cancelled run's per-file timings, a fourth leg brings the slowest scripts leg to about 9 minutes, paid for with one more leg on every code PR (the costs [[Sharded CI Test Matrix#Fan-out has its own costs]] names).

The hooks group carries the same class, and there an anchor earns its place. One suite classifies every tracked path in a single test, one builds a fixture repository per case, and one runs real git pushes, so each costs far more than its bytes predict. Weighed by bytes alone the walk can draw all three onto one leg, and whether it does depends on the suite set: on the current tree the unanchored walk places them on three separate legs, so the anchor guards against a draw the walk can reach as suites shift, not a standing collision. A leg that stacked heavy suites ran 688 seconds of bats against 293 and 270 beside it on one CI run, the slowest leg of the matrix. Anchored, each takes a bucket of its own, and the group measures 359 / 326 / 339 seconds on one CI run. Part of the gap between those runs is a fixture cost rather than placement. The jq-availability suite drives every hook with jq off PATH, and a shim built with one symlink fork per binary in the runner's `/usr/bin` costs several seconds per test; `.gaia/tests/helpers/path.sh` links each directory with one call, which holds the suite near 5 seconds rather than about 210.

The hooks group stops at three shards even though a fourth would lower its own heaviest shard, because the gain does not survive either axis. On CI, splitting hooks further only exposes the next constraint underneath it, worth a few seconds unless the `lib` directory is split as well, and the pair costs three more legs. On a hand run it is worth less than that, for the reason the paragraph below gives.

## Levers not taken, and why

- **A setup job that fetches shared state once.** Adds a serial hop ahead of every shard, lengthening the critical path.
- **A checked-in shard manifest.** Fails silently: a new suite runs in no shard, every check greens, the pass count quietly drops.
- **A checked-in table of per-file runtimes.** A better weight than file size, and the same silent-stale hazard as the manifest above wearing different clothes: a newly added suite weighs nothing, the shard holding it is under-counted, and nothing says so. Size is read from the tree at discovery time, so it is never stale and never absent. The anchor list the sharder does carry is not this table in miniature: it holds no runtimes and changes no file's weight, an unlisted file weighs its bytes rather than nothing, and a listed file discovery cannot find is an error instead of a quiet no-op.
- **A hand-maintained per-shard package list.** Also a silent-green hazard, because the suites that need `python3-yaml` fail rather than skip when it is absent while the ones needing `zsh` skip quietly. The step's list is derived from the suites instead, rounded up to whole exchange groups and pinned by W10; W9 pins the sandbox leg's reduced set.
- **`bats --jobs`.** A live lever rather than a closed question. The reasoning that excludes it, that the runner is already CPU-saturated, describes every shard sharing one box; a shard now runs one suite serially on its own four-core box, leaving cores idle.

## Fan-out has its own costs

Widening the matrix is not free, and two costs are measured rather than theoretical:

- **Shared-host bursts.** The legs that install a package run `apt-get update` within seconds of each other, and a mirror hash-sum mismatch on any one of them reds a declared-required context. The bats archive is vendored rather than fetched for exactly this reason: fetching it puts a second host in the same burst, and GitHub's codeload answers that burst with `503`s costing an affected leg roughly two minutes of backoff. Any change that adds legs, or that puts a fetch back on an install path, widens what is left.
- **Fixed overhead multiplies.** Each leg pays provisioning, checkout, and install. Below roughly a minute of real work, a leg is mostly overhead.

Total machine time rises with fan-out even as wall-clock falls. Fan-out optimizes human-facing latency on the critical path, not runner minutes; change-scoped selection is the lever on runner minutes and timeout exposure.

## Related

- [[Code Audit Team]] for the merge gate that runs alongside it.
- [[Quality Gate]] for the local gate, which has nothing to check on a YAML/bash/bats change.
