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
# rather than `check-*` alone: five members live outside that one glob. The
# `.bats` family is deliberately not swept even though WTI_BATS names a member
# from it, because the only glob that would reach it, .gaia/tests/lib/*.bats,
# enumerates every ordinary suite in that directory and would need an exclusion
# entry per suite saying nothing. The one bats member is named directly instead.
#
# Runtime, measured on the tree at the time of writing: the sixteen scripts
# total ~27s, of which check-script-capabilities.sh alone is ~15s (it walks the
# invocation closure of every allowlisted script), shell-lint ~10s, and the
# shard suite ~19s; the whole set measures ~62-66s end to end. That is why there is
# one tier rather than a fast default plus a named
# slower tier. A split is worth its second name only once the honest set is
# slow enough that people skip it, and an aggregate slow enough to skip is
# worse than none; a minute against the price of an audit round is not that.
# Re-measure before adding a member that changes the order of magnitude.
#
# The staleness lever: nothing above used to notice a member added without
# this figure catching up, which is exactly what happened here (this comment
# said "fifteen" while WTI_SCRIPTS already held sixteen). main() checks
# WTI_SCRIPTS's live count against WTI_SCRIPTS_COUNT_ASOF below and refuses to
# run when they disagree, so adding or removing a member forces this paragraph
# to be re-measured and both numbers updated together, rather than drifting
# unnoticed again.
#
# No member is ever skipped. A missing member path, and a bats member with no
# `bats` on PATH, both count as failures rather than passing quietly, because a
# member that silently drops out reproduces the defect this script exists to
# end.
#
# Members are invoked from the current directory, so run it from the repository
# root. That is also what lets the sibling bats suite exercise the aggregation
# against a fixture tree of stubs instead of paying the real ~62-66s.

set -uo pipefail

readonly PROG="whole-tree-invariants"

# Members invoked as `bash <path>`.
readonly WTI_SCRIPTS='.gaia/scripts/check-audit-base-derivation.sh
.gaia/scripts/check-audit-key-callers.sh
.gaia/scripts/check-hook-scope-manifest.sh
.gaia/scripts/check-main-root-derivation.sh
.gaia/scripts/check-registry-completeness.sh
.gaia/scripts/check-registry-settings-permissions.sh
.gaia/scripts/check-registry-source-literals.sh
.gaia/scripts/check-resolver-singleton.sh
.gaia/scripts/check-script-capabilities.sh
.gaia/scripts/check-step-body-extractor-roster.sh
.gaia/scripts/check-wiki-state-collision.sh
.gaia/scripts/audit-rules-changed-complete.sh
.gaia/scripts/audit-machinery-complete.sh
.gaia/scripts/lint-shipped-issue-refs.sh
.gaia/scripts/verify-audit-roster.sh
.gaia/tests/shell-lint.sh'

# The staleness lever's baseline: WTI_SCRIPTS's own member count at the time
# the runtime paragraph above was last measured. main() compares the live
# count against this and refuses to run on a mismatch, per that paragraph.
readonly WTI_SCRIPTS_COUNT_ASOF=16

# Members invoked as `bats <path>`. The shard partition is a whole-tree
# invariant in the same sense as the scripts above: its input is every .bats
# file's weight, so adding or growing one anywhere can repack a leg and leave
# the workflow's per-leg apt-install step pointing at the wrong shard.
readonly WTI_BATS='.gaia/tests/lib/audit-ci-shards.bats'

# Deliberately NOT members, `<path>|<reason>`. Each answers no to the
# membership question above, and each is here so the answer is written down
# rather than left as an omission the sibling suite cannot tell from one.
readonly WTI_EXCLUDED='.gaia/scripts/check-debt-issue-metadata.sh|argument-driven per-filing validator; its --issue and --sweep modes read the tracker over the network
.gaia/scripts/check-registry-runtime.sh|reads the gitignored .gaia/local/ runtime tree, reports and never blocks, and is meaningless on a fresh checkout
.gaia/scripts/check-updates.sh|SessionStart update probe that writes a cache; network-dependent and asserts no invariant
.gaia/scripts/lint-git-path-quoting.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-grep-ere-escapes.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-errexit-status-read.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-hook-array-guard.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/scripts/lint-workflow-run-interpolation.sh|runs transitively, shell-lint.sh invokes it and shell-lint.sh is itself a member
.gaia/tests/bats-shards.sh|harness plumbing, it partitions suites into shards rather than asserting anything; the partition itself is the bats member above
.gaia/tests/install-bats.sh|harness plumbing, it installs the pinned bats and asserts no invariant
.gaia/tests/run-bats-parallel.sh|harness plumbing, the hand-run entry point for the same partition
.gaia/scripts/verify-cli-bundle-fresh.sh|rebuilds the CLI via pnpm bundle; a build step needing installed dependencies, not a read of the tree
.gaia/scripts/verify-required-checks.sh|reads the live GitHub ruleset over the network, so its subject is repository configuration rather than the tree
.gaia/tests/whole-tree-invariants.sh|this runner; a member of itself would recurse
.gaia/scripts/check-hook-capabilities.sh|excluded on cost: 66-70s median standalone gate-mode cost, measured on the manifest-complete tree over two independent n=3 samples on the same host (medians 66.4s and 70.3s; the gap is host load, and the cost is fork-bound, so a runner figure will differ again); it runs instead in its own dedicated gated job in .github/workflows/audit-ci-tests.yml'

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

# run_member <path> <interpreter...>
run_member() {
  local path="$1"
  shift
  printf '\n===== %s\n' "$path"
  if [ ! -f "$path" ]; then
    printf 'missing: %s (expected relative to the repository root)\n' "$path" >&2
    record_result "$path" 1
    return
  fi
  # `</dev/null` is load-bearing rather than tidy. Both member loops below read
  # their list from a heredoc, so an unredirected member inherits that heredoc
  # as its stdin: one `read`, or an `xargs`/`jq` with no input argument, and the
  # member eats the remaining member paths, the loop ends early, and the runner
  # reports every-member-passed having run one. That is the silent drop-out the
  # header promises cannot happen, and it leaves no FAIL line and no skip notice.
  "$@" "$path" </dev/null
  record_result "$path" "$?"
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
  # stops the run here instead of drifting unnoticed.
  local live_count
  live_count="$( printf '%s\n' "$WTI_SCRIPTS" | grep -c . )"
  if [ "$live_count" -ne "$WTI_SCRIPTS_COUNT_ASOF" ]; then
    printf '%s: WTI_SCRIPTS holds %s members but the runtime paragraph above was last measured at %s; re-measure it and update both numbers.\n' \
      "$PROG" "$live_count" "$WTI_SCRIPTS_COUNT_ASOF" >&2
    return 2
  fi

  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    run_member "$path" bash
  done <<EOF
$WTI_SCRIPTS
EOF

  local have_bats=1
  command -v bats >/dev/null 2>&1 || have_bats=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ "$have_bats" -eq 0 ]; then
      printf '\n===== %s\n' "$path"
      printf 'bats not found on PATH; run bash .gaia/tests/install-bats.sh\n' >&2
      record_result "$path" 1
      continue
    fi
    run_member "$path" bats
  done <<EOF
$WTI_BATS
EOF

  printf '\n===== %s\n' "$PROG"
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
