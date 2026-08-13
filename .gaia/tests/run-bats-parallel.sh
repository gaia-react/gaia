#!/usr/bin/env bash
# run-bats-parallel.sh: run this repo's bats suites concurrently in one
# invocation, capture each to its own log, and replay the logs in a fixed
# order.
#
# The hand-run entry point for this repo's bats suites. This and
# `.github/workflows/audit-ci-tests.yml` consume the same partition
# from `.gaia/tests/bats-shards.sh`: each shard leg of the CI matrix calls
# `bats-shards.sh run <shard-id>` on its own box, while a hand run forks
# every one of them on this one. Sharing the partition is what makes a hand run a
# meaningful pre-push signal rather than a differently grouped approximation
# of what CI will do. The shards are concurrency-safe in a shared workspace,
# so forking them collapses the wall clock to roughly the slowest shard
# instead of their sum.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.
#
# Usage:
#   bash .gaia/tests/run-bats-parallel.sh [--table <file>] [--log-dir <dir>]
#
#   --table <file>    Tab-delimited suite table to run instead of the built-in
#                     one. Test seam only: .gaia/tests/lib/run-bats-parallel.bats
#                     is the only caller that passes it.
#   --log-dir <dir>   Where per-suite logs land. Omitted, the runner creates a
#                     fresh unique directory of its own.
#
# Exit codes:
#   0  every suite exited 0
#   1  at least one suite exited non-zero (after full log replay)
#   2  usage / precondition error (unreadable, empty or malformed table;
#      missing log)
#
# Table format, one suite per line, exactly three tab-separated fields:
#
#   <slug><TAB><label><TAB><command words, space separated>
#
# <slug> names the log file, <label> is the human-readable name in the group
# header and the failure summary. The command field is split on whitespace into
# an argv array, so a command must contain NO quoting, NO globbing, and NO
# argument containing a space. There is deliberately no `eval` here: the table is
# data, and word-splitting a fixed data field is the whole of the parsing.
#
# The default log directory is unique per invocation, which matters concretely:
# this runner's own bats suite lives in `.gaia/tests/lib/`, which is the `lib`
# shard the runner forks, so a hand run of the whole table has an inner
# invocation (this suite, exercised via its own --table fixtures) running
# concurrently with the outer live one. A shared default would let the
# fail-closed missing-log rule below red on that overlap. The runner also
# never removes a directory it did not create.
#
# Portability: linted by `.gaia/tests/shell-lint.sh` at the `style` floor, runs
# on CI's bash 5 (via .gaia/tests/lib/run-bats-parallel.bats, its own guard
# suite) and on macOS `/bin/bash` 3.2.57. No `mapfile`, no `declare -A`, no
# `${var^^}`, no `wait -n`.
set -euo pipefail

# Where the sharder is looked up. Location-independent on purpose: it is what
# lets the guard suite drive a copy of this script that sits beside a stub
# sharder, or beside no sharder at all.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TABLE_FILE=''
LOG_DIR=''

usage() {
  printf 'Usage: bash .gaia/tests/run-bats-parallel.sh [--table <file>] [--log-dir <dir>]\n'
}

die_usage() {
  printf 'run-bats-parallel: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# Built-in suite table, one row per shard id the sharder prints, in the order
# it prints them and therefore the order the logs replay in. The ids are asked
# for rather than restated: a second copy would drift from the partition CI
# runs, silently and in the direction of running less. The bats suite in
# .gaia/tests/lib/run-bats-parallel.bats sources this file and calls this
# function to read the table back out, so it stays a function with no side
# effects beyond its stdout.
#
# Capture the id list and check the status BEFORE printing anything: a sharder
# that dies part-way must contribute no rows at all, so main()'s empty-table
# guard turns it into exit 2. Streaming the lookup into rows would emit
# whatever the sharder managed before dying, and the run would then report a
# green over less work than it claims. Returning non-zero instead is no help:
# main() reads this through a process substitution, which hides a function's
# exit status from `set -e`. Printing nothing is what fails closed.
#
# The command field stays repo-relative rather than interpolating $HERE. It is
# data that survives `read -ra` word-splitting with no quote processing, so an
# absolute path breaks the moment a checkout lives under a path containing a
# space; the table's "run me from the repo root" contract holds instead.
builtin_table() {
  local ids rc id
  rc=0
  ids="$(bash "$HERE/bats-shards.sh" shards)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 0
  fi
  while IFS= read -r id; do
    if [ -n "$id" ]; then
      printf '%s\tshard %s\tbash .gaia/tests/bats-shards.sh run %s\n' "$id" "$id" "$id"
    fi
  done <<<"$ids"
}

# Reads the table on stdin into the parallel slugs/labels/cmds arrays. Runs in
# the current shell so the arrays survive; a pipeline would lose them.
slugs=()
labels=()
cmds=()
parse_table() {
  local line lineno slug label cmd
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    # A whitespace-only line carries no suite. Blank lines are skipped, never
    # counted, so a table of nothing but blanks reaches the empty-table guard.
    if [ -z "${line//[[:space:]]/}" ]; then
      continue
    fi
    IFS=$'\t' read -r slug label cmd <<<"$line"
    if [ -z "$slug" ] || [ -z "$label" ] || [ -z "${cmd//[[:space:]]/}" ]; then
      printf 'run-bats-parallel: malformed table row %s: %s\n' "$lineno" "$line" >&2
      exit 2
    fi
    slugs+=("$slug")
    labels+=("$label")
    cmds+=("$cmd")
  done
}

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --table)
        [ $# -ge 2 ] || die_usage '--table needs a value'
        TABLE_FILE="$2"
        shift 2
        ;;
      --log-dir)
        [ $# -ge 2 ] || die_usage '--log-dir needs a value'
        LOG_DIR="$2"
        shift 2
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        die_usage "unknown argument: $1"
        ;;
    esac
  done

  if [ -n "$TABLE_FILE" ]; then
    [ -r "$TABLE_FILE" ] || die_usage "table not readable: $TABLE_FILE"
    parse_table <"$TABLE_FILE"
  else
    parse_table < <(builtin_table)
  fi

  local count
  count=${#slugs[@]}
  # Fail closed on an empty table. A green "all passed" over zero suites is the
  # lie-green class .gaia/scripts/lint-diff-name-only-quoting.sh hard-errors on
  # for its own empty scan set, and .gaia/tests/shell-lint.sh for its discovery.
  if [ "$count" -eq 0 ]; then
    printf 'run-bats-parallel: suite table yielded zero suites, refusing to report success\n' >&2
    exit 2
  fi

  if [ -n "$LOG_DIR" ]; then
    # Caller-supplied: used as-is, created if absent, and never removed.
    mkdir -p "$LOG_DIR"
  else
    LOG_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/bats-parallel.XXXXXX")
  fi

  local i argv log pids
  pids=()
  i=0
  while [ "$i" -lt "$count" ]; do
    log="$LOG_DIR/${slugs[$i]}.log"
    # No eval: the command field is word-split by `read -ra`, which performs no
    # globbing and no quote processing, then invoked as an argv array.
    read -ra argv <<<"${cmds[$i]}"
    # Each suite runs in its own subshell, which stamps its own elapsed seconds
    # so the summary reports real per-suite time. Waiting in table order would
    # otherwise charge every suite the elapsed time of the slowest one before it.
    (
      suite_start=$(date +%s)
      suite_rc=0
      # Fail closed rather than run nothing. parse_table already rejects an
      # empty command field, so this cannot fire today; without it, an empty
      # argv would degenerate to a bare redirection that truncates the log and
      # exits 0, reporting a pass over zero work -- the same lie-green the
      # empty-table guard above refuses, one level down.
      if [ "${#argv[@]}" -eq 0 ]; then
        printf 'run-bats-parallel: suite %s resolved an empty command, refusing to report success\n' "${slugs[$i]}" >&2
        exit 2
      fi
      ${argv[@]+"${argv[@]}"} >"$log" 2>&1 || suite_rc=$?
      printf '%s\n' "$(($(date +%s) - suite_start))" >"$LOG_DIR/${slugs[$i]}.secs"
      exit "$suite_rc"
    ) &
    pids+=("$!")
    i=$((i + 1))
  done

  # Collect PER PID. A bare `wait` returns only the LAST job's status and would
  # green a failure in any other suite; that is the exact bug the adversarial
  # fixtures F1/F2 in .gaia/tests/lib/run-bats-parallel.bats exist to catch.
  # `|| suite_rc=$?` rather than `if ! wait ...`, because inside an `if !` body
  # $? is the negated status (0), not the command's. Nothing aborts early: every
  # suite is waited on and every log replays even when the first one failed.
  local rc suite_rc failed codes
  rc=0
  failed=()
  codes=()
  i=0
  while [ "$i" -lt "$count" ]; do
    suite_rc=0
    wait "${pids[$i]}" || suite_rc=$?
    codes+=("$suite_rc")
    if [ "$suite_rc" -ne 0 ]; then
      rc=1
      failed+=("${labels[$i]}")
    fi
    i=$((i + 1))
  done

  # Replay in TABLE order, never completion order.
  i=0
  while [ "$i" -lt "$count" ]; do
    log="$LOG_DIR/${slugs[$i]}.log"
    if [ ! -f "$log" ]; then
      printf 'run-bats-parallel: missing log for suite %s at %s\n' "${slugs[$i]}" "$log" >&2
      exit 2
    fi
    printf '::group::%s\n' "${labels[$i]}"
    cat "$log"
    printf '::endgroup::\n'
    i=$((i + 1))
  done

  # Per-suite timing, recovering the per-suite breakdown that running every
  # shard through one invocation would otherwise lose.
  local secs_file secs
  printf '\nPer-suite results:\n'
  i=0
  while [ "$i" -lt "$count" ]; do
    secs_file="$LOG_DIR/${slugs[$i]}.secs"
    secs='?'
    if [ -f "$secs_file" ]; then
      secs=$(cat "$secs_file")
    fi
    printf '  %s: %s in %ss\n' "${labels[$i]}" "${codes[$i]}" "$secs"
    i=$((i + 1))
  done

  if [ "$rc" -ne 0 ]; then
    local joined
    joined=''
    i=0
    while [ "$i" -lt "${#failed[@]}" ]; do
      if [ -z "$joined" ]; then
        joined="${failed[$i]}"
      else
        joined="$joined, ${failed[$i]}"
      fi
      i=$((i + 1))
    done
    printf '::error::bats suites failed: %s\n' "$joined"
    exit 1
  fi
}

# Sourcing guard: the bats suite sources this file to read builtin_table back out
# without running any suite. Direct invocation is unaffected.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
