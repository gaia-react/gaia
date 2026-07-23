#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-registry-runtime.sh -- Check C of
# the state-registry conformance model (foundations task 2.3, design
# analysis/registry-design.md §4.4, DECISIONS.md D-024/D-019, SPEC-061
# UAT-006). LOCAL ONLY: this suite still runs in CI (it is a bats file under
# .gaia/scripts/tests/), but what it exercises is the check's LOGIC against
# a synthetic `.gaia/local`-shaped fixture, never the real (CI-empty)
# .gaia/local/ -- Check C itself is never wired as a CI gate; see the
# check's own header comment.
#
# The contract under test throughout: ALWAYS report, NEVER delete or block
# (SPEC-061 UAT-006). Every fixture test that creates an "unknown" child
# asserts the child is still present on disk after the check runs -- that
# survival assertion IS the report-not-delete proof, not an incidental
# check.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-registry-runtime.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-registry-runtime.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-registry-runtime.sh
  source "$CHECK"
}

# run_in_repo <fn> [args...]: cwd = the real repo root regardless of where
# bats itself was invoked from, so gaia_registry_classify (via
# state-registry-lib.sh's own $PWD-based resolution) matches against THIS
# repo's real registry while the walked directory is still a synthetic
# fixture passed as an argument. Mirrors state-registry-lib.bats's own
# helper.
run_in_repo() {
  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    shift 2
    "$@"
  ' _ "$REPO_ROOT" "$CHECK" "$@"
}

@test "structural: check-registry-runtime.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_registry_runtime with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_registry_runtime >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "a non-existent local_dir reports 'nothing to report' and still returns 0" {
  run_in_repo gaia_check_registry_runtime "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 0 ]
  grep -qF "does not exist -- nothing to report" <<<"$output" || return 1
}

@test "fixture: known / residue / unknown children each classify correctly, and the unknown child SURVIVES (report-not-delete)" {
  local dir="$BATS_TEST_TMPDIR/mixed-fixture"
  mkdir -p "$dir"
  # known: an exact-match shared entry (setup-state.json)
  touch "$dir/setup-state.json"
  # known residue: a named dead-feature path
  touch "$dir/mentorship.json"
  # unknown: matches nothing in the registry
  touch "$dir/totally-unknown-thing.xyz"

  run_in_repo gaia_check_registry_runtime "$dir"
  [ "$status" -eq 0 ]
  grep -qF "CONFORMANT: setup-state.json (shared)" <<<"$output" || return 1
  grep -qF "RESIDUE: mentorship.json" <<<"$output" || return 1
  grep -qF "UNKNOWN: totally-unknown-thing.xyz" <<<"$output" || return 1
  grep -qF "summary: 1 conformant, 1 known-residue, 1 unknown" <<<"$output" || return 1

  # the report-not-delete proof: the unknown child is untouched.
  [ -e "$dir/totally-unknown-thing.xyz" ]
}

@test "fixture: recursion descends into an unrecognized top-level container to find a recognized leaf" {
  local dir="$BATS_TEST_TMPDIR/nested-fixture"
  mkdir -p "$dir/audit"
  touch "$dir/audit/abc123.ok"

  run_in_repo gaia_check_registry_runtime "$dir"
  [ "$status" -eq 0 ]
  grep -qF "CONFORMANT: audit/abc123.ok (shared)" <<<"$output" || return 1
  # the bare container itself is never reported, only the leaf underneath it
  grep -qE '^(CONFORMANT|RESIDUE|UNKNOWN): audit \(' <<<"$output" && return 1
  return 0
}

@test "fixture: a match:prefix subtree (red-ledger/) is reported once and NOT individually walked" {
  local dir="$BATS_TEST_TMPDIR/prefix-fixture"
  mkdir -p "$dir/red-ledger"
  touch "$dir/red-ledger/observations.jsonl"
  touch "$dir/red-ledger/more-data.jsonl"

  run_in_repo gaia_check_registry_runtime "$dir"
  [ "$status" -eq 0 ]
  grep -qF "CONFORMANT: red-ledger (per-tree)" <<<"$output" || return 1
  # its individual files never get their own report line
  grep -qF "red-ledger/observations.jsonl" <<<"$output" && return 1
  grep -qF "red-ledger/more-data.jsonl" <<<"$output" && return 1
  return 0
}

@test "many unknown children are all reported and all survive (never reaped, never a partial stop)" {
  local dir="$BATS_TEST_TMPDIR/many-unknown-fixture"
  mkdir -p "$dir"
  touch "$dir/unknown-one.xyz" "$dir/unknown-two.xyz" "$dir/unknown-three.xyz"

  run_in_repo gaia_check_registry_runtime "$dir"
  [ "$status" -eq 0 ]
  grep -qF "summary: 0 conformant, 0 known-residue, 3 unknown" <<<"$output" || return 1
  [ -e "$dir/unknown-one.xyz" ]
  [ -e "$dir/unknown-two.xyz" ]
  [ -e "$dir/unknown-three.xyz" ]
}
