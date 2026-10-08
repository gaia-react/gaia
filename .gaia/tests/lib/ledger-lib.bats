#!/usr/bin/env bats
# Unit tests for `.gaia/scripts/spec/ledger-lib.sh`, the shared helpers behind
# the single ledger-update chokepoint and the archive sweeps.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  LIB="$REPO_ROOT/.gaia/scripts/spec/ledger-lib.sh"
  [ -f "$LIB" ]
  # shellcheck source=/dev/null
  . "$LIB"
  NOW_EPOCH=1800000000
}

_iso_days_before_now() {
  local epoch=$((NOW_EPOCH - $1 * 86400))
  date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

@test "kind_for_id: SPEC ids are spec, PLAN ids are plan" {
  [ "$(gaia_ledger_kind_for_id SPEC-001)" = "spec" ]
  [ "$(gaia_ledger_kind_for_id PLAN-123)" = "plan" ]
}

@test "kind_for_id: anything else prints nothing and returns 2" {
  for bad in FOO-1 plan-001 SPEC- PLAN-1x SPEC-001-extra " SPEC-001" ""; do
    run gaia_ledger_kind_for_id "$bad"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
  done
}

@test "array_key: specs and plans" {
  [ "$(gaia_ledger_array_key spec)" = "specs" ]
  [ "$(gaia_ledger_array_key plan)" = "plans" ]
}

@test "array_key: unknown kind prints nothing and fails" {
  run gaia_ledger_array_key bogus
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "status_allowed: spec accepts draft ready merged abandoned" {
  for value in draft ready merged abandoned; do
    gaia_ledger_status_allowed spec "$value"
  done
}

@test "status_allowed: plan rejects draft, accepts ready merged abandoned" {
  run gaia_ledger_status_allowed plan draft
  [ "$status" -eq 1 ]
  for value in ready merged abandoned; do
    gaia_ledger_status_allowed plan "$value"
  done
}

@test "status_allowed: off-vocabulary values and unknown kinds are rejected" {
  for value in shipped allocated "" bogus; do
    run gaia_ledger_status_allowed spec "$value"
    [ "$status" -eq 1 ]
    run gaia_ledger_status_allowed plan "$value"
    [ "$status" -eq 1 ]
  done
  run gaia_ledger_status_allowed bogus ready
  [ "$status" -eq 1 ]
}

@test "directory: resolves the main-checkout specs and plans directories" {
  . "$REPO_ROOT/.gaia/scripts/ledger-path-lib.sh"
  sandbox="$(cd "$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")" && pwd -P)"
  git -C "$sandbox" init --quiet --initial-branch=main
  run gaia_ledger_directory spec "$sandbox"
  [ "$status" -eq 0 ]
  [ "$output" = "$sandbox/.gaia/local/specs" ]
  run gaia_ledger_directory plan "$sandbox"
  [ "$status" -eq 0 ]
  [ "$output" = "$sandbox/.gaia/local/plans" ]
}

@test "directory: unknown kind, or resolver functions absent, prints nothing and fails" {
  run gaia_ledger_directory bogus "$BATS_TEST_TMPDIR"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  run bash -c ". '$LIB'; gaia_ledger_directory spec '$BATS_TEST_TMPDIR'"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "age_past_window: exactly at the boundary is past, one day inside is not" {
  gaia_ledger_age_past_window "$(_iso_days_before_now 30)" "$NOW_EPOCH" 30
  run gaia_ledger_age_past_window "$(_iso_days_before_now 29)" "$NOW_EPOCH" 30
  [ "$status" -eq 1 ]
}

@test "age_past_window: fractional-second timestamps parse" {
  gaia_ledger_age_past_window "2020-01-01T00:00:00.123Z" "$NOW_EPOCH" 30
}

@test "age_past_window: empty, garbage, and non-positive now never reap" {
  run gaia_ledger_age_past_window "" "$NOW_EPOCH" 30
  [ "$status" -eq 1 ]
  run gaia_ledger_age_past_window "not-a-date" "$NOW_EPOCH" 30
  [ "$status" -eq 1 ]
  run gaia_ledger_age_past_window "2020-01-01T00:00:00Z" 0 30
  [ "$status" -eq 1 ]
  run gaia_ledger_age_past_window "2020-01-01T00:00:00Z" "" 30
  [ "$status" -eq 1 ]
}
