#!/usr/bin/env bash
# Run all distribution-validation scenarios, report pass/fail.
# Walks .gaia/tests/distribution/*.sh in lexicographic order, excluding
# run-all.sh itself and anything under lib/. Naming
# convention is NN-name.sh so order is deterministic.
#
# Scenarios are independent (each builds its own staging tree in its own
# mktemp directories), so they run in two phases:
#
#   1. Every scenario without the exclusive marker, concurrently, at most
#      DISTRIBUTION_JOBS at a time: the host's CPU count by default, and 1
#      runs them serially.
#   2. Every scenario whose header carries the line
#      `# distribution-runner: exclusive`, one at a time, alone on the host.
#
# The marker is for a scenario that runs the scaffold's own test suite. Vitest
# already spreads one such run across every core, and its per-test timeouts
# (5s by default) are tuned for a host it has to itself: two of them side by
# side, or one beside the concurrent phase, time out on tests that pass alone.
# A scenario that only installs or runs the CLI does not need it.
#
# Each scenario runs in a separate `bash` subprocess, so one scenario's
# `set -e` exit does not abort the run, with its output captured to a log. A
# progress line prints as each scenario finishes; once all have, every log
# prints in scenario order under its `=== name ===` header, then the summary.
#
# Exits 0 if all PASS, 1 if any FAIL or if no scenarios were found, 2 when
# DISTRIBUTION_JOBS is not a positive integer.
set -u

DISTRIBUTION_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXCLUSIVE_MARKER='# distribution-runner: exclusive'

job_limit="${DISTRIBUTION_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
case "$job_limit" in
  '' | *[!0-9]* | 0 | 0*)
    echo "DISTRIBUTION_JOBS must be a positive integer, got: $job_limit" >&2
    exit 2
    ;;
esac

shopt -s nullglob
candidates=("$DISTRIBUTION_DIRECTORY"/*.sh)
shopt -u nullglob

scenarios=()
for scenario in ${candidates[@]+"${candidates[@]}"}; do
  name="$(basename "$scenario")"
  [ "$name" = "run-all.sh" ] && continue
  scenarios+=("$scenario")
done

if [ ${#scenarios[@]} -eq 0 ]; then
  echo "No scenarios found in $DISTRIBUTION_DIRECTORY" >&2
  exit 1
fi

concurrent_indexes=()
exclusive_indexes=()
for index in "${!scenarios[@]}"; do
  if grep -qxF "$EXCLUSIVE_MARKER" "${scenarios[index]}"; then
    exclusive_indexes+=("$index")
  else
    concurrent_indexes+=("$index")
  fi
done

LOG_DIRECTORY="$(mktemp -d -t gaia-dist-run-all-XXXXXX)"

running_pids=()
running_indexes=()
started_at=()
statuses=()

# Prints PID and every process descended from it.
# shellcheck disable=SC2329 # reached only through stop_running_scenarios
process_tree() {
  local child
  printf '%s\n' "$1"
  for child in $(pgrep -P "$1" 2>/dev/null); do
    process_tree "$child"
  done
}

# A non-interactive shell starts background jobs with SIGINT ignored, and
# every process a scenario starts (pnpm, vitest, the browser) inherits that,
# so Ctrl-C alone would leave each running scenario's whole tree behind. The
# tree is collected before anything is signalled: a parent killed first
# orphans its children out of reach of `pgrep -P`. `set -m` would reach the
# tree through process groups instead, but its setpgid race intermittently
# writes a spurious "Operation not permitted" line into a scenario's log.
# shellcheck disable=SC2329 # invoked through the INT/TERM trap
stop_running_scenarios() {
  local pid tree_pid tree=()
  for pid in ${running_pids[@]+"${running_pids[@]}"}; do
    while IFS= read -r tree_pid; do
      tree+=("$tree_pid")
    done < <(process_tree "$pid")
  done
  [ ${#tree[@]} -gt 0 ] && kill -TERM "${tree[@]}" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$LOG_DIRECTORY"
  exit 130
}
trap stop_running_scenarios INT TERM
trap 'rm -rf "$LOG_DIRECTORY"' EXIT

# Collect every finished scenario, recording its exit status and printing
# its progress line. Leaves only the still-running ones in the arrays.
reap_finished_scenarios() {
  local position pid index status verdict
  local remaining_pids=() remaining_indexes=()
  for position in ${running_pids[@]+"${!running_pids[@]}"}; do
    pid="${running_pids[$position]}"
    index="${running_indexes[$position]}"
    if kill -0 "$pid" 2>/dev/null; then
      remaining_pids+=("$pid")
      remaining_indexes+=("$index")
      continue
    fi
    wait "$pid"
    status=$?
    statuses[index]="$status"
    verdict=PASS
    [ "$status" -eq 0 ] || verdict=FAIL
    printf 'done  %s  %s (%ss)\n' "$verdict" "$(basename "${scenarios[index]}")" "$((SECONDS - started_at[index]))"
  done
  running_pids=(${remaining_pids[@]+"${remaining_pids[@]}"})
  running_indexes=(${remaining_indexes[@]+"${remaining_indexes[@]}"})
}

# run_scenarios LIMIT INDEX... : runs the named scenarios at most LIMIT at a
# time and returns once every one of them has finished.
run_scenarios() {
  local limit="$1" index
  shift
  for index in "$@"; do
    while [ ${#running_pids[@]} -ge "$limit" ]; do
      reap_finished_scenarios
      [ ${#running_pids[@]} -ge "$limit" ] && sleep 1
    done
    started_at[index]="$SECONDS"
    bash "${scenarios[index]}" > "$LOG_DIRECTORY/$index.log" 2>&1 < /dev/null &
    running_pids+=("$!")
    running_indexes+=("$index")
  done
  while [ ${#running_pids[@]} -gt 0 ]; do
    reap_finished_scenarios
    [ ${#running_pids[@]} -gt 0 ] && sleep 1
  done
}

printf 'Running %s scenarios up to %s at a time, then %s exclusive scenarios one at a time\n' \
  "${#concurrent_indexes[@]}" "$job_limit" "${#exclusive_indexes[@]}"
run_scenarios "$job_limit" ${concurrent_indexes[@]+"${concurrent_indexes[@]}"}
run_scenarios 1 ${exclusive_indexes[@]+"${exclusive_indexes[@]}"}

results=()
overall=0

for index in "${!scenarios[@]}"; do
  name="$(basename "${scenarios[index]}")"
  printf '\n=== %s ===\n' "$name"
  cat "$LOG_DIRECTORY/$index.log"
  if [ "${statuses[index]}" -eq 0 ]; then
    results+=("PASS  $name")
  else
    results+=("FAIL  $name")
    overall=1
  fi
done

printf '\n=== Summary ===\n'
for result in ${results[@]+"${results[@]}"}; do
  printf '%s\n' "$result"
done

exit "$overall"
