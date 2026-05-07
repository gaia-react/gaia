#!/usr/bin/env bash
# Shared primitives for .claude-tests/distribution scenarios.
#
# Sourced by every scenario at the top:
#   source "$(dirname "$0")/lib/lib.sh"
#
# Convention: scenarios set `set -euo pipefail` themselves. This file
# intentionally does NOT enable `set -e` — sourcing would inherit it into
# the caller, which is fine, but explicit-in-scenario is the convention.
#
# API (frozen — see plan README):
#   PROJECT_ROOT  - absolute path to GAIA repo root (git rev-parse --show-toplevel)
#   pass MSG      - prints "PASS  <basename of $0>: MSG" to stdout; returns 0
#   fail MSG      - prints "FAIL  <basename of $0>: MSG" to stderr; returns 1
#   log MSG       - prints "  - MSG" to stderr (non-failing diagnostic)
#   require_cmd CMD [MESSAGE]  - exits 1 if CMD is not on PATH

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
