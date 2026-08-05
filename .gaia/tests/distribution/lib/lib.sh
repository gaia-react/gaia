#!/usr/bin/env bash
# Shared primitives for .gaia/tests/distribution scenarios.
#
# Sourced by every scenario at the top:
#   source "$(dirname "$0")/lib/lib.sh"
#
# Convention: scenarios set `set -euo pipefail` themselves. This file
# intentionally does NOT enable `set -e`; sourcing would inherit it into
# the caller, which is fine, but explicit-in-scenario is the convention.
#
# API:
#   PROJECT_ROOT  - absolute path to GAIA repo root (git rev-parse --show-toplevel)
#   pass MSG      - prints "PASS  <basename of $0>: MSG" to stdout; returns 0
#   fail MSG      - prints "FAIL  <basename of $0>: MSG" to stderr; returns 1
#   log MSG       - prints "  - MSG" to stderr (non-failing diagnostic)
#   require_cmd CMD [MESSAGE]  - exits 1 if CMD is not on PATH
#   capture_cli_stderr PATH    - declares PATH as this scenario's stderr capture file
#   run_cli CMD [ARG...]       - runs CMD with stderr captured; stdout passes through
#   fail_with_stderr MSG       - reports the captured stderr, then fails and exits 1

# Resolve once; export so all functions can reference.
PROJECT_ROOT="$(git rev-parse --show-toplevel)"
export PROJECT_ROOT

# pass MSG  -> stdout: "PASS  <basename of $0>: MSG"; returns 0
pass() {
  printf 'PASS  %s: %s\n' "$(basename "$0")" "$*"
  return 0
}

# fail MSG  -> stderr: "FAIL  <basename of $0>: MSG"; returns 1
fail() {
  printf 'FAIL  %s: %s\n' "$(basename "$0")" "$*" >&2
  return 1
}

# log MSG   -> stderr: "  - MSG" (non-failing diagnostic)
log() {
  printf '  - %s\n' "$*" >&2
}

# require_cmd CMD MESSAGE
# If CMD not on PATH, prints MESSAGE to stderr and exits 1.
# Used at the top of scenarios that need git/tar/rsync/pnpm.
require_cmd() {
  local cmd="$1"
  local message="${2:-required command not found: $cmd}"
  command -v "$cmd" >/dev/null 2>&1 || {
    printf '%s\n' "$message" >&2
    exit 1
  }
}

# --- CLI stderr diagnostics ------------------------------------------------
#
# A scenario that asserts a CLI call SUCCEEDS has to keep the call's stderr off
# stdout, because stdout is the JSON (or the emptiness) it is about to assert
# on. Dropping stderr with `2>/dev/null` leaves the failure branch with nothing
# to report but the exit code, which is the one fact the branch being taken
# already implies; on a runner nobody is sitting in front of, that costs a local
# reproduction to learn anything at all.
#
# So capture it. These three functions are the whole mechanism:
#
#   capture_cli_stderr "$FIXTURES/cli-stderr.txt"   # once, after the scratch dir exists
#   out="$(cd "$SCAFFOLD" && run_cli "$GAIA" scaffold component Foo)" \
#     || fail_with_stderr "gaia scaffold component exited non-zero on staged tree"
#
# The capture path is the caller's, not this library's: every scenario already
# owns a scratch dir removed by its own `trap … EXIT`, and a trap installed here
# would be silently replaced by the scenario's own.
#
# WHY NOT RE-RUN THE COMMAND UNSUPPRESSED. Reporting the bytes the FAILING run
# emitted is the point. A re-run is a second, different execution: it can
# succeed (leaving the failure unexplained), fail differently, or double the
# side effects on the one path already going wrong.
#
# CALL ORDER IS LOAD-BEARING, which is why `fail_with_stderr` exists rather than
# an inline group at each call site. The stderr report runs BEFORE `fail`, never
# after: `fail` returns 1 rather than exiting, and the `||` right-hand side is
# the LAST command of its AND-OR list, so `set -e` is NOT suppressed there and
# aborts the scenario the moment `fail` returns. Anything sequenced after `fail`
# is dead code, which is how a diagnostic that looks present prints nothing.
# (`fail_with_stderr`'s own trailing `exit 1` is unreachable for that reason and
# is kept as the statement of intent, matching every other failure branch.)

# capture_cli_stderr PATH
# Declares PATH as this scenario's capture file and truncates it. Call once,
# after the scratch directory holding PATH exists.
capture_cli_stderr() {
  CLI_STDERR="$1"
  : > "$CLI_STDERR"
}

# run_cli CMD [ARG...]
# Runs CMD with stderr redirected to the capture file; stdout passes through for
# the caller to capture. Returns CMD's exit status.
run_cli() {
  "$@" 2> "${CLI_STDERR:?run_cli requires capture_cli_stderr to have been called}"
}

# fail_with_stderr MSG
# The failure branch every success-asserting `run_cli` call uses: report what
# the failing run wrote to stderr, then fail, then exit.
fail_with_stderr() {
  if [ -s "${CLI_STDERR:?fail_with_stderr requires capture_cli_stderr to have been called}" ]; then
    printf -- '--- gaia stderr ---\n' >&2
    cat "$CLI_STDERR" >&2
    printf -- '--- end gaia stderr ---\n' >&2
  else
    printf -- '(gaia wrote nothing to stderr)\n' >&2
  fi
  fail "$1"
  exit 1
}
