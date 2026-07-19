#!/usr/bin/env bats
# Tests for .gaia/scripts/bats5.sh, the bash-5 pre-flight guard for bats.
# Assertions use bash-3.2-safe forms (POSIX [ ], explicit failure) per
# .claude/rules/bats-assertions.md.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../bats5.sh"
}

@test "sourcing defines the bats5 function" {
  # shellcheck disable=SC1090
  source "$SCRIPT"
  [ -n "$(declare -F bats5)" ]
}

@test "sourcing does not auto-invoke bats" {
  marker="${BATS_TEST_TMPDIR}/called"
  bats() { echo called >>"$marker"; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  [ ! -f "$marker" ]
}

@test "bats5 forwards its arguments to bats" {
  recorded="${BATS_TEST_TMPDIR}/args"
  bats() { printf '%s\n' "$*" >"$recorded"; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  bats5 one two three
  grep -qxF 'one two three' "$recorded"
}

@test "bats5 does not leak its helper locals into the caller" {
  bats() { :; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  bats5 noop
  [ -z "${d+set}" ]
  [ -z "${resolved_bash+set}" ]
  [ -z "${major+set}" ]
}
