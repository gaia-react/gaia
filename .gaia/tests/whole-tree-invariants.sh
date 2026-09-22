#!/usr/bin/env bash
# shellcheck shell=bash
#
# whole-tree-invariants.sh: run, as one named set, every check whose input is
# the whole tree. Exit 0 when every member passes, 1 when any member fails, 2
# on a usage error. Run it from the repository root:
# `bash .gaia/tests/whole-tree-invariants.sh`.
#
# Why this exists. Pre-dispatch self-verification selects checks by the paths a
# diff touches, and a whole-tree checker has no path that selects it -- its
# input is the directory. So the set that actually ran was whichever a
# currently-loaded rule happened to name, and rule activation is itself
# path-scoped: structurally the wrong shape for a check whose input is the
# whole tree. The cost when one is missed is a full audit round, because the
# repair commit moves HEAD, rotates every dispatched member's content digest,
# and buys a re-audit of each.
#
# This deliberately duplicates work CI already does. That is the point: CI
# finds it after the push, which costs the round above, and the pre-dispatch
# step exists to front-load exactly that.
#
# Membership is decided by two questions, read from each candidate's own header
# rather than inferred from its name. The first accounts for every exclusion
# but one: is the input the whole tracked tree, with no path-scoped trigger
# that could select it? The second exists for exactly one member so far: a
# candidate that answers yes to the first question can still be excluded on
# cost, when its standalone wall clock is long enough that no per-PR aggregate
# should absorb it inline. `.gaia/scripts/check-hook-capabilities.sh` is that
# member; its own dedicated gated CI job runs it against the live tree instead,
# and its WTI_EXCLUDED reason line carries the measured figure that earned it
# the exclusion. The candidates that answer no to either question are listed in
# WTI_EXCLUDED below with their reason, so a reader can see they were
# considered rather than missed, and .gaia/tests/lib/whole-tree-invariants.bats
# fails if a candidate appears in neither table. That suite sweeps the five
# `.sh` naming families that have produced a member (`check-*`, `audit-*-
# complete`, `lint-*` and `verify-*` under .gaia/scripts/, plus .gaia/tests/*.sh),
# rather than `check-*` alone: WTI_SCRIPTS holds members outside that glob. The
# `.bats` family is deliberately not swept even though WTI_BATS names a member
# from it, because the only glob that would reach it, .gaia/tests/lib/*.bats,
# enumerates every ordinary suite in that directory and would need an exclusion
# entry per suite saying nothing. The one bats member is named directly instead.
#
# Runtime. Every figure below is one sample, indicative and host-dependent
# rather than a contract: a loaded host moves them by several times the spread
# between two honest samples, so re-measure the WHOLE paragraph rather than
# reconcile a disagreement or patch one number. Sampled on an otherwise idle
# Apple M2 Pro (12 cores, macOS 27) in 2026-09, tree green (every member
# passing), with mawk and a bats --jobs backend (GNU parallel) resolvable on
# PATH and WTI_JOBS/WTI_BATS_JOBS at their defaults (8 each): the forked
# aggregate this script reports is ~145s. Two members account for nearly all
# of it even under the fork: the WTI_BATS member (the shard-partition suite),
# run under bats --jobs 8, costs ~87s standalone (~242s forced serial, so the
# backend buys it roughly 2.8x); and shell-lint.sh as a member costs ~43s. The
# other 21 WTI_SCRIPTS members total roughly 32s between them, the heaviest
# being check-script-capabilities.sh at ~14s (it walks the invocation closure
# of every allowlisted script) and check-registry-source-literals.sh at ~6s.
#
# The aggregate does not collapse toward the ~87s slowest member, because
# total CPU is close to fixed rather than shrinking under the fork: this
# run's user+sys time (~7m user, ~6m19 sys) sits within a few percent of the
# same total on an unforked serial run of every member. The pool buys
# overlap on 12 cores, not less work, so the two heavy members still contend
# with each other and with the lighter 21 for the same cores.
#
# Both figures the aggregate leans on are conditional, and the runner
# degrades rather than refusing when either input is absent (see
# "Concurrency" below and this plan's README.md FC-7). Absent a bats --jobs
# backend, the WTI_BATS member runs serially and becomes the pool's long
# pole at its own standalone cost, roughly the ~242s above rather than ~87s.
# Absent mawk, the awk-tokenizer guards shell-lint.sh folds in resolve a
# slower interpreter; the per-guard breakdown lives in shell-lint.sh's own
# header rather than repeated here.
#
# A second host type is on record for one member only. shell-lint.sh is its
# own CI gate, and that job's shellcheck step measures roughly 85-160s on
# ubuntu-latest across repeated successful runs, which brackets the local
# figure rather than contradicting it. The runner itself has no CI
# counterpart, so its aggregate is local-only by construction and a second
# host type for it is not something that can be asked for.
#
# Time each member the way this script invokes it, the WTI_SCRIPTS members
# with `bash <path> >/dev/null </dev/null` and the WTI_BATS member with
# `bats <path>`, and time the aggregate by running this script. Running `bash`
# at the bats member is not merely wrong-and-loud: its `local` declarations
# fail outside a function, so the body's paths expand unrooted and it attempts
# a write at `/` before dying on a syntax error.
#
# There is one tier rather than a fast default plus a named slower tier. A
# split is worth its second name only once the honest set is slow enough that
# people skip it, and an aggregate slow enough to skip is worse than none; the
# ~145s aggregate stated in the Runtime paragraph above, against the price of
# an audit round, is not that, and the margin is comfortable rather than
# narrow: shell-lint.sh's own inline cost (~43s) now sits below the 66-70s
# standalone figure that earned check-hook-capabilities.sh its own cost
# exclusion in WTI_EXCLUDED below, so that exclusion's threshold and this
# runner's own heaviest inline member no longer sit in tension.
#
# Re-measure the WHOLE paragraph, not the figure being edited. Only the member
# COUNT below is machine-checked, so every number here decays independently:
# the shard suite's own figure nearly doubled as its W10 fixtures grew across
# two rounds of one change, and the scripts half sat ~19s low for long enough
# that the stated parts could no longer reach the stated whole. A component
# figure nobody re-measured is the one that misdirects, because it reads as
# current beside the ones that were.
#
# The staleness lever: nothing above used to notice a member added without
# this figure catching up, which is exactly what happened here (this comment
# said "fifteen" while WTI_SCRIPTS already held sixteen). main() checks
# WTI_SCRIPTS's live count against WTI_SCRIPTS_COUNT_ASOF below and refuses to
# run when they disagree, so adding or removing a member forces this paragraph
# to be re-visited rather than drifting unnoticed again.
#
# What the lever does not catch, stated so it is not mistaken for more than it
# is: only WTI_SCRIPTS_COUNT_ASOF is machine-checked, and a member swapped for
# another, or simply grown, holds the count, so the runtime figures above can
# go stale with the lever fully satisfied. Nothing cheap correlates with cost
# across every configuration this runner supports (a bats --jobs backend
# present or absent, mawk present or absent, WTI_JOBS/WTI_BATS_JOBS at their
# defaults or overridden), so the figures above are maintained by convention
# rather than by a machine check, and this header can be wrong while every
# gate stays green.
#
# What closes part of that gap: every full run prints its own measured
# aggregate and the configuration that produced it (the worker cap, whether a
# bats --jobs backend was found, the resolved awk), unconditionally, with no
# threshold and no comparison against the figures above. That makes a
# discrepancy visible to whoever is already looking at the run, which this
# comment cannot be. Two narrower designs were considered and rejected. A
# thresholded warning against the figures above fires on every
# guaranteed-working degraded configuration this runner supports (no backend,
# no mawk, a non-default WTI_JOBS or WTI_BATS_JOBS; see FC-7 in this plan's
# README.md), which makes it an always-firing notice on a working state,
# noise rather than signal. A baseline kept per configuration is a matrix of
# hand-kept figures where the problem was one hand-kept figure, and it decays
# faster than the thing it protects.
#
# No member is ever skipped. A missing member path, and a bats member with no
# `bats` on PATH, both count as failures rather than passing quietly, because a
# member that silently drops out reproduces the defect this script exists to
# end.
#
# Concurrency. Every member below forks into a bounded pool sized by WTI_JOBS
# (see the resolver beside it) instead of running as two serial loops. Fork
# order and replay order are independent: the pool dispatches the WTI_BATS
# member first, because it is this set's long pole, then WTI_SCRIPTS in
# declared order, but replay always walks WTI_SCRIPTS then WTI_BATS in that
# same declared order regardless of which member actually finished first,
# because the pinned PASS/FAIL sequence below is what
# .gaia/tests/lib/whole-tree-invariants.bats asserts against. Each member's
# stdout and stderr land in two separate per-member logs rather than one
# merged log, so a caller reading only this script's stdout keeps seeing
# exactly what it saw before this runner forked anything.
#
# Members are invoked from the current directory, so run it from the repository
# root. That is also what lets the sibling bats suite exercise the aggregation
# against a fixture tree of stubs instead of paying the real cost, the
# end-to-end figure stated once in the runtime paragraph above rather than
# restated here: two copies of one measurement is two things to keep current,
# and the stale one reads as authoritative.

set -uo pipefail

readonly PROG="whole-tree-invariants"

# Members invoked as `bash <path>`.
readonly WTI_SCRIPTS='.gaia/scripts/check-audit-base-derivation.sh
.gaia/scripts/check-audit-key-callers.sh
.gaia/scripts/check-base-provenance-adoption.sh
.gaia/scripts/check-hook-command-rooting.sh
.gaia/scripts/check-hook-scope-manifest.sh
.gaia/scripts/check-main-root-derivation.sh
.gaia/scripts/check-registry-completeness.sh
.gaia/scripts/check-registry-settings-permissions.sh
.gaia/scripts/check-registry-source-literals.sh
.gaia/scripts/check-resolver-singleton.sh
.gaia/scripts/check-scope-digest-adoption.sh
.gaia/scripts/check-script-capabilities.sh
.gaia/scripts/check-step-body-extractor-roster.sh
.gaia/scripts/check-verb-arming-adoption.sh
.gaia/scripts/check-wiki-state-collision.sh
.gaia/scripts/audit-rules-changed-complete.sh
.gaia/scripts/audit-machinery-complete.sh
.gaia/scripts/lint-errexit-source-guard.sh
.gaia/scripts/lint-retired-label-spellings.sh
.gaia/scripts/lint-shipped-issue-refs.sh
.gaia/scripts/verify-audit-roster.sh
.gaia/tests/shell-lint.sh'

# The staleness lever's baseline: WTI_SCRIPTS's own member count at the time
# the runtime paragraph above was last measured. main() compares the live
# count against this and refuses to run on a mismatch, per that paragraph.
readonly WTI_SCRIPTS_COUNT_ASOF=22

# Members invoked as `bats <path>`. The shard partition is a whole-tree
# invariant in the same sense as the scripts above: its input is every .bats
# file's weight, so adding or growing one anywhere can repack a leg and leave
# the workflow's per-leg apt-install step pointing at the wrong shard.
readonly WTI_BATS='.gaia/tests/lib/audit-ci-shards.bats'

# Deliberately NOT members, `<path>|<reason>`. Each answers no to the
# membership question above, and each is here so the answer is written down
# rather than left as an omission the sibling suite cannot tell from one.
readonly WTI_EXCLUDED='.gaia/scripts/check-debt-issue-metadata.sh|argument-driven per-filing validator; every mode but --pre-file reads the tracker over the network, --investigate-cap on the blocking filing path
.gaia/scripts/check-registry-runtime.sh|reads the gitignored .gaia/local/ runtime tree, reports and never blocks, and is meaningless on a fresh checkout
.gaia/scripts/check-updates.sh|SessionStart update probe that writes a cache; network-dependent and asserts no invariant
.gaia/scripts/lint-git-path-quoting.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-grep-ere-escapes.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-errexit-status-read.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-hook-array-guard.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-workflow-run-interpolation.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-oracle-blind-invocations.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-stale-cardinals.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-guard-rule-shell-coverage.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-collapsed-signal-trap.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-hook-wiki-inventory.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-wiki-cached-version.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-hook-advisory-classification.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-sigpipe-readers.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-hook-cwd-relative-loads.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-hook-jq-availability.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-hook-monitor-arming.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-scripts-wiki-inventory.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-awk-interpreter-pin.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/hook-registration-lib.sh|a sourced library defining functions and running nothing; every gate that sources it is a member by the lines above and by shell-lint.sh, and its other consumer is a bats helper covered by the hooks suites in Audit CI Tests
.gaia/tests/bats-shards.sh|harness plumbing, it partitions suites into shards rather than asserting anything; the partition itself is the bats member above
.gaia/tests/install-bats.sh|harness plumbing, it installs the pinned bats and asserts no invariant
.gaia/tests/run-bats-parallel.sh|harness plumbing, the hand-run entry point for the same partition
.gaia/tests/leg-arming.sh|per-leg CI arming decision: its answer is conditioned on the changed-file list a pull request carries and the matrix leg id, so it decides one leg rather than asserting an invariant over the checkout; its guards live in .gaia/tests/lib/audit-ci-shards.bats, already the WTI_BATS member
.gaia/scripts/verify-cli-bundle-fresh.sh|rebuilds the CLI via pnpm bundle; a build step needing installed dependencies, not a read of the tree
.gaia/scripts/verify-required-checks.sh|reads the live GitHub ruleset over the network, so its subject is repository configuration rather than the tree
.gaia/tests/whole-tree-invariants.sh|this runner; a member of itself would recurse
.gaia/scripts/check-cli-workspace-floors.sh|path-scoped and separately gated; its parity subjects are the two files under .gaia/cli/ that arm the code filter in cli-tests.yml, where it runs offline as its own step, and the network-reading advisory arm it also carries runs on no pull request at all, only on the scheduled non-required lane in .github/workflows/cli-advisory-scan.yml
.gaia/scripts/check-hook-capabilities.sh|excluded on cost: 66-70s median standalone gate-mode cost, measured on the manifest-complete tree over two independent n=3 samples on the same host (medians 66.4s and 70.3s; the gap is host load), and 83s measured on an ubuntu-latest runner, which is the slower host; it runs instead in its own dedicated gated job in .github/workflows/audit-ci-tests.yml'

usage() {
  cat <<EOF
usage: bash .gaia/tests/whole-tree-invariants.sh [--list | --list-excluded | --help]

Run every whole-tree invariant check as one set, from the repository root.

  (no argument)     run every member; exit 1 if any fails
  --list            print every member path, one per line
  --list-excluded   print every deliberate non-member as <path>|<reason>
  --help            this text
EOF
}

wti_failed=''
wti_fail_count=0

# record_result <label> <exit-status>
#
# The verdict lines below are a pinned output contract, not free-form logging:
# .gaia/tests/lib/whole-tree-invariants.bats matches the two-space `PASS  ` and
# `FAIL  ` prefixes literally and counts lines carrying them, so reformatting one
# reds several tests in a file this edit does not touch. The same holds for the
# two summary lines at the end of main.
record_result() {
  if [ "$2" -eq 0 ]; then
    printf 'PASS  %s\n' "$1"
  else
    printf 'FAIL  %s\n' "$1"
    wti_fail_count=$((wti_fail_count + 1))
    wti_failed="${wti_failed}${1}
"
  fi
}

# WTI_JOBS: the outer fork's worker-pool bound. An explicit override is
# honored as-is, INCLUDING a degenerate WTI_JOBS=1 -- that is the value
# someone reaches for while debugging a fork/wait bug, and it has to run the
# same bounded-pool code as everyone else rather than a silently different
# serial path. Absent a valid override, detect_jobs()-shaped:
# getconf _NPROCESSORS_ONLN, clamped to 2..8 and floored at 2 on a non-numeric
# or absent answer, the same fallback reasoning shell-lint.sh's own
# detect_jobs() uses. The cap is 8 rather than the raw core count because this
# pool nests inside others: shell-lint.sh forks its own shellcheck and guard
# workers when it is the member running, and a later runtime phase forks
# bats' own --jobs inside the WTI_BATS member; the peak process count is
# computed under this cap, not over the whole member set.
WTI_JOBS_CAP=8
WTI_JOBS_FLOOR=2
detect_wti_jobs() {
  local n
  if [ -n "${WTI_JOBS-}" ]; then
    n="$WTI_JOBS"
    case "$n" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$n" -ge 1 ]; then
          printf '%s\n' "$n"
          return
        fi
        ;;
    esac
  fi
  n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  case "$n" in
    '' | *[!0-9]*) n="$WTI_JOBS_FLOOR" ;;
  esac
  if [ "$n" -lt "$WTI_JOBS_FLOOR" ]; then
    n="$WTI_JOBS_FLOOR"
  fi
  if [ "$n" -gt "$WTI_JOBS_CAP" ]; then
    n="$WTI_JOBS_CAP"
  fi
  printf '%s\n' "$n"
}

# WTI_BATS_JOBS: the WTI_BATS member's own --jobs bound, honored the same
# way WTI_JOBS above honors its override -- as-is, including a degenerate
# WTI_BATS_JOBS=1, which is the value someone reaches for while debugging.
# Unlike WTI_JOBS the fallback is a static default rather than a core count:
# a bats worker here runs one test file's cases, not a whole member, so the
# right default is the measured shard-suite shape (this plan's README.md
# FC-4), not the host's core count.
WTI_BATS_JOBS_DEFAULT=8
detect_wti_bats_jobs() {
  local n
  if [ -n "${WTI_BATS_JOBS-}" ]; then
    n="$WTI_BATS_JOBS"
    case "$n" in
      '' | *[!0-9]*) ;;
      *)
        if [ "$n" -ge 1 ]; then
          printf '%s\n' "$n"
          return
        fi
        ;;
    esac
  fi
  printf '%s\n' "$WTI_BATS_JOBS_DEFAULT"
}

# wti_bats_backend_probe: whether bats' own --jobs flag has a backend to run
# under. bats 1.13.0 accepts either GNU parallel or shenwei356/rush, so this
# checks for either rather than assuming the one this repository installs.
# Probed once from main(), not once per member: there is exactly one
# WTI_BATS member.
wti_bats_backend_probe() {
  command -v parallel >/dev/null 2>&1 || command -v rush >/dev/null 2>&1
}

# slug_for <path>: a filesystem-safe log-file stem. Every WTI_SCRIPTS and
# WTI_BATS path is repo-relative and drawn from [A-Za-z0-9._/-], so collapsing
# '/' to '_' cannot collide between two distinct members.
slug_for() {
  printf '%s\n' "$1" | tr '/' '_'
}

# wti_collect_oldest: wait on the pool's oldest live pid, record its status,
# and pop it off the queue. bash 3.2 has no `wait -n`, so there is no way to
# ask "which of these pids finished" -- only "wait for this one specific
# pid" -- and freeing a pool slot therefore means waiting on the OLDEST
# outstanding pid, never a newer one, or a fast member could sit collected
# while the pool blocks on a slow one dispatched after it for no reason.
# `|| rc=$?`, never `if ! wait ...`: inside an `if !` body `$?` is the negated
# status, not the command's.
wti_collect_oldest() {
  local rc
  rc=0
  wait "${pool_pids[0]}" || rc=$?
  done_paths+=("${pool_paths[0]}")
  done_status+=("$rc")
  pool_paths=("${pool_paths[@]:1}")
  pool_pids=("${pool_pids[@]:1}")
}

# wti_dispatch <path> <interp>: fork one member into the pool, or, for a
# member that cannot run at all (a missing path, or the bats interpreter with
# no bats on PATH), record its failure straight into
# done_paths/done_status with no process forked and no pool slot spent.
# Either way the member gets a synthetic log pair, so replay_member's log
# reading never has to special-case "this member was never actually run".
#
# `</dev/null` on the fork replaces the header's older "shared heredoc"
# hazard note: there is no longer a shared heredoc for an unredirected member
# to drain, since each member is now its own fork, but a member that reads
# its own stdin unredirected would otherwise inherit whatever this script's
# own stdin happens to be, so the redirect stays for the same reason.
#
# Stdout and stderr land in two SEPARATE logs, never merged with `2>&1`. A
# caller reading only this script's stdout does not see a member's
# diagnostics today, and merging would silently change that for 23 members at
# once; the cost is that a single member's own stdout and stderr no longer
# interleave in the replayed output, which is worth stating because
# run_shellcheck_pass (.gaia/tests/shell-lint.sh) and run-bats-parallel.sh,
# the two forked patterns this one copies the shape of, both merge instead.
wti_dispatch() {
  local path="$1" interp="$2" slug
  slug="$(slug_for "$path")"

  if [ "$interp" = bats ] && [ "$have_bats" -eq 0 ]; then
    printf 'bats not found on PATH; run bash .gaia/tests/install-bats.sh\n' >"$wti_tmp/$slug.err"
    : >"$wti_tmp/$slug.out"
    done_paths+=("$path")
    done_status+=(1)
    return
  fi

  if [ ! -f "$path" ]; then
    printf 'missing: %s (expected relative to the repository root)\n' "$path" >"$wti_tmp/$slug.err"
    : >"$wti_tmp/$slug.out"
    done_paths+=("$path")
    done_status+=(1)
    return
  fi

  # wti_bats_extra_args holds --jobs <n> when main() found a backend, and it
  # is only ever spent on the bats interp: a WTI_SCRIPTS member takes no
  # such argument, so the branch below keeps it off the bash interp's
  # command line entirely rather than expanding an always-empty array
  # there. `${arr[@]+"${arr[@]}"}` is the offset-guarded expansion
  # `.gaia/scripts/lint-hook-array-guard.sh` requires in place of a bare
  # "${arr[@]}", which aborts under this file's `set -u` on bash 3.2 when
  # the array is genuinely empty (a missing backend, or the WTI_SCRIPTS
  # loop this same function serves).
  if [ "$interp" = bats ]; then
    "$interp" ${wti_bats_extra_args[@]+"${wti_bats_extra_args[@]}"} "$path" >"$wti_tmp/$slug.out" 2>"$wti_tmp/$slug.err" </dev/null &
  else
    "$interp" "$path" >"$wti_tmp/$slug.out" 2>"$wti_tmp/$slug.err" </dev/null &
  fi
  pool_paths+=("$path")
  pool_pids+=("$!")
  if [ "${#pool_pids[@]}" -ge "$WTI_JOBS" ]; then
    wti_collect_oldest
  fi
}

# wti_status_for <path>: look up a collected member's exit status by path.
# Linear scan rather than an associative array: bash 3.2 has none, and 23
# members make the O(n^2) worst case trivial. Unreachable in practice --
# main() drains the pool fully before any replay_member call -- and the
# fallback is a hard failure rather than a silent pass, so a bug here cannot
# read as a clean run.
wti_status_for() {
  local path="$1" i
  i=0
  while [ "$i" -lt "${#done_paths[@]}" ]; do
    if [ "${done_paths[$i]}" = "$path" ]; then
      printf '%s\n' "${done_status[$i]}"
      return
    fi
    i=$((i + 1))
  done
  printf '%s\n' 1
}

# replay_member <path>: print the group header and this member's two logs, in
# that order, then record PASS/FAIL. A log this member should have produced
# but did not -- the log directory was unwritable, or something removed it
# after the member ran -- means that member ran no check as far as this
# replay can tell, so it is recorded FAIL regardless of whatever status
# wti_status_for would otherwise report: the same "missing log means failure,
# never a skip" rule run_shellcheck_pass and run-bats-parallel.sh apply to
# their own worker logs.
replay_member() {
  local path="$1" slug status out_ok err_ok
  slug="$(slug_for "$path")"
  printf '\n===== %s\n' "$path"

  out_ok=1
  err_ok=1
  if [ -f "$wti_tmp/$slug.out" ]; then
    cat "$wti_tmp/$slug.out"
  else
    out_ok=0
  fi
  if [ -f "$wti_tmp/$slug.err" ]; then
    cat "$wti_tmp/$slug.err" >&2
  else
    err_ok=0
  fi

  if [ "$out_ok" -eq 0 ] || [ "$err_ok" -eq 0 ]; then
    printf 'missing log for %s; this member ran no check\n' "$path" >&2
    record_result "$path" 1
    return
  fi

  status="$(wti_status_for "$path")"
  record_result "$path" "$status"
}

main() {
  # Arity before dispatch: the case below reads only "$1", so without this a
  # mistyped `--list --list-exluded` would run the first and discard the
  # misspelling, handing the caller a success they did not ask for.
  if [ "$#" -gt 1 ]; then
    printf '%s: too many arguments\n' "$PROG" >&2
    usage >&2
    return 2
  fi

  case "${1-}" in
    --help | -h)
      usage
      return 0
      ;;
    --list)
      printf '%s\n%s\n' "$WTI_SCRIPTS" "$WTI_BATS"
      return 0
      ;;
    --list-excluded)
      printf '%s\n' "$WTI_EXCLUDED"
      return 0
      ;;
    '') ;;
    *)
      printf '%s: unknown argument: %s\n' "$PROG" "$1" >&2
      usage >&2
      return 2
      ;;
  esac

  # The staleness lever (see the comment above WTI_SCRIPTS_COUNT_ASOF): a
  # member added or removed without re-measuring the runtime paragraph above
  # stops the run here instead of drifting unnoticed. Runs before any fork.
  local live_count
  live_count="$( printf '%s\n' "$WTI_SCRIPTS" | grep -c . )"
  if [ "$live_count" -ne "$WTI_SCRIPTS_COUNT_ASOF" ]; then
    printf '%s: WTI_SCRIPTS holds %s members but the runtime paragraph above was last measured at %s; re-measure the runtime paragraph above and update WTI_SCRIPTS_COUNT_ASOF.\n' \
      "$PROG" "$live_count" "$WTI_SCRIPTS_COUNT_ASOF" >&2
    return 2
  fi

  # SECONDS resets and starts counting here, so the self-report below times
  # the run itself rather than the interpreter's own startup. bash's built-in
  # $SECONDS is whole seconds and process-local, so it needs nothing torn
  # down and cannot leak into a forked member's own environment.
  SECONDS=0

  local have_bats path wti_backend_found
  local pool_paths pool_pids done_paths done_status wti_bats_extra_args
  pool_paths=()
  pool_pids=()
  done_paths=()
  done_status=()
  wti_bats_extra_args=()

  # NOT `local`: detect_wti_jobs() reads an explicit override through
  # "${WTI_JOBS-}" at the moment it runs, which is before this assignment
  # takes effect (the command substitution on the right runs first). A `local
  # WTI_JOBS` declared here, even unset, would shadow that read and make a
  # caller's `WTI_JOBS=1 bash whole-tree-invariants.sh` invisible to it.
  WTI_JOBS="$(detect_wti_jobs)"

  # NOT `local`, for the same class of reason as WTI_JOBS above and a
  # different mechanism: the EXIT trap below runs after main() returns, so a
  # local is out of scope by the time the trap body expands it. Under this
  # file's `set -u` that aborts the trap, and the temp directory survives
  # every run rather than being cleaned up once.
  wti_tmp="$(mktemp -d "${RUNNER_TEMP:-/tmp}/whole-tree-invariants.XXXXXX")"
  trap 'rm -rf "$wti_tmp"' EXIT

  # Exported, not merely assigned: a forked member is a separate process, and
  # only the environment crosses a fork/exec, not this shell's own variables.
  # No real member reads this. It exists so a fixture member can reach into
  # its own log directory and delete its own log, the adversarial drive
  # .gaia/tests/lib/whole-tree-invariants.bats uses to prove the missing-log
  # path actually reds rather than merely being read as passing.
  export WTI_LOG_DIR="$wti_tmp"

  have_bats=1
  command -v bats >/dev/null 2>&1 || have_bats=0

  # wti_backend_found feeds only the self-report at the end of this
  # function; it plays no role in what wti_bats_extra_args ends up holding.
  wti_backend_found=no

  # WTI_BATS_JOBS only ever reaches the shard-partition member when a
  # backend is actually there to answer it; a missing bats has already been
  # handled above and never reaches this branch. No backend degrades: the
  # member still runs, serially, with the same test count and verdict, and
  # this notice says so on stderr rather than failing the run (this plan's
  # README.md FC-7). Maintainer-only: .gaia/tests/ is wholesale
  # release-excluded, so no adopter runs this suite or needs either backend.
  if [ "$have_bats" -eq 1 ]; then
    if wti_bats_backend_probe; then
      wti_backend_found=yes
      wti_bats_extra_args=(--jobs "$(detect_wti_bats_jobs)")
    else
      printf '%s\n' "############################################################" >&2
      printf '%s\n' "# NOTE: no GNU parallel or rush on PATH." >&2
      printf '%s\n' "# Running $WTI_BATS serially instead of under --jobs." >&2
      printf '%s\n' "# Costs time, not correctness -- the test count and verdict" >&2
      printf '%s\n' "# are unchanged. Install a backend to parallelize it:" >&2
      printf '%s\n' "#   brew install parallel        (or) cargo install rush" >&2
      printf '%s\n' "# Maintainer-only: adopters never run this suite and never" >&2
      printf '%s\n' "# need either backend." >&2
      printf '%s\n' "############################################################" >&2
    fi
  fi

  # Dispatch order and replay order are independent (see "Concurrency" in the
  # header above). Dispatch the WTI_BATS member FIRST: it is this set's long
  # pole, and a bounded pool that forked it last would start it several
  # members late for nothing. WTI_SCRIPTS follows in declared order.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    wti_dispatch "$path" bats
  done <<EOF
$WTI_BATS
EOF

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    wti_dispatch "$path" bash
  done <<EOF
$WTI_SCRIPTS
EOF

  # Drain whatever the pool still holds once every member has been
  # dispatched. wti_dispatch already drains down to WTI_JOBS-1 live members
  # as it fills the pool; this collects the tail that never triggered another
  # dequeue.
  while [ "${#pool_pids[@]}" -gt 0 ]; do
    wti_collect_oldest
  done

  # Replay in declared order -- WTI_SCRIPTS then WTI_BATS -- never completion
  # order. That sequence is the pinned output contract
  # .gaia/tests/lib/whole-tree-invariants.bats asserts against, independent of
  # which member actually finished first above.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    replay_member "$path"
  done <<EOF
$WTI_SCRIPTS
EOF

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    replay_member "$path"
  done <<EOF
$WTI_BATS
EOF

  printf '\n===== %s\n' "$PROG"

  # Self-report: printed unconditionally on every full run, pass or fail,
  # with no threshold and no comparison against the Runtime paragraph above
  # (see "What the lever does not catch" there for why a threshold is
  # rejected). This is what makes a stale paragraph visible to whoever is
  # already looking at the run, rather than only to someone who goes back to
  # re-measure it. Sources awk-interp-lib.sh directly rather than through the
  # guard-awk-lib.sh closure it is normally reached through: this is a read of
  # GAIA_AWK_STATUS/GAIA_AWK_IDENT for display, never a gate, and it runs
  # after every member has already been dispatched and collected, so it
  # cannot change what any forked member saw.
  local wti_awk_ident
  wti_awk_ident=unresolved
  if [ -f .gaia/scripts/awk-interp-lib.sh ]; then
    . .gaia/scripts/awk-interp-lib.sh
    case "${GAIA_AWK_STATUS:-}" in
      0) wti_awk_ident="${GAIA_AWK_IDENT:-unresolved}" ;;
      5) wti_awk_ident=none ;;
      6) wti_awk_ident=unsanctioned ;;
    esac
  fi
  printf 'config: WTI_JOBS=%s bats-parallel-backend=%s resolved-awk=%s aggregate=%ss\n' \
    "$WTI_JOBS" "$wti_backend_found" "$wti_awk_ident" "$SECONDS"

  if [ "$wti_fail_count" -eq 0 ]; then
    printf 'all whole-tree invariants pass\n'
    return 0
  fi
  # Header and names on the same stream: split across stdout and stderr, a
  # caller capturing one of them ends on a dangling colon with no names, or
  # collects bare paths with no header. Bats cannot see the split, because `run`
  # merges both streams into $output.
  printf '%d member(s) failed:\n' "$wti_fail_count" >&2
  printf '%s' "$wti_failed" >&2
  return 1
}

main "$@"
