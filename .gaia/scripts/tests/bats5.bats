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

@test "bats5 drops --jobs and warns when no parallel runner is installed" {
  recorded="${BATS_TEST_TMPDIR}/args"
  bats() { printf '%s\n' "$*" >"$recorded"; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  bats5_parallel_runner_available() { return 1; }
  run --separate-stderr bats5 --jobs 8 one.bats two.bats
  [ "$status" -eq 0 ]
  grep -qxF 'one.bats two.bats' "$recorded"
  [[ "$stderr" == *"GNU parallel"* ]] || return 1
}

@test "bats5 forwards --jobs when a parallel runner is installed" {
  recorded="${BATS_TEST_TMPDIR}/args"
  bats() { printf '%s\n' "$*" >"$recorded"; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  bats5_parallel_runner_available() { return 0; }
  bats5 --jobs 8 one.bats
  grep -qxF -- '--jobs 8 one.bats' "$recorded"
}

@test "bats5 does not leak its helper locals into the caller" {
  bats() { :; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  bats5 noop
  [ -z "${candidate_directory+set}" ]
  [ -z "${resolved_bash+set}" ]
  [ -z "${major+set}" ]
}

# The runner driving this suite may itself set the gates, so each test below
# clears them first: a pass has to come from bats5, not from the environment
# it inherited.
_clear_git_config_env() {
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
    GIT_CONFIG_KEY_1 GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2 \
    GIT_CONFIG_KEY_3 GIT_CONFIG_VALUE_3
}

@test "bats5 hands bats the git maintenance gates" {
  _clear_git_config_env
  recorded="${BATS_TEST_TMPDIR}/env"
  bats() { env >"$recorded"; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  bats5 noop
  grep -qxF 'GIT_CONFIG_COUNT=4' "$recorded"
  grep -qxF 'GIT_CONFIG_KEY_0=gc.auto' "$recorded"
  grep -qxF 'GIT_CONFIG_VALUE_0=0' "$recorded"
  grep -qxF 'GIT_CONFIG_KEY_1=maintenance.auto' "$recorded"
  grep -qxF 'GIT_CONFIG_VALUE_1=false' "$recorded"
  grep -qxF 'GIT_CONFIG_KEY_2=gc.autoDetach' "$recorded"
  grep -qxF 'GIT_CONFIG_VALUE_2=false' "$recorded"
  grep -qxF 'GIT_CONFIG_KEY_3=maintenance.autoDetach' "$recorded"
  grep -qxF 'GIT_CONFIG_VALUE_3=false' "$recorded"
}

@test "bats5 appends its gates after an ambient git config entry and keeps it" {
  _clear_git_config_env
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/ambient/hooks
  recorded="${BATS_TEST_TMPDIR}/env"
  bats() { env >"$recorded"; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  bats5 noop
  grep -qxF 'GIT_CONFIG_COUNT=5' "$recorded"
  grep -qxF 'GIT_CONFIG_KEY_0=core.hooksPath' "$recorded"
  grep -qxF 'GIT_CONFIG_VALUE_0=/ambient/hooks' "$recorded"
  grep -qxF 'GIT_CONFIG_KEY_1=gc.auto' "$recorded"
  grep -qxF 'GIT_CONFIG_KEY_4=maintenance.autoDetach' "$recorded"
  [ "$GIT_CONFIG_COUNT" = 1 ]
}

@test "bats5 leaves no git maintenance gate in the caller's shell" {
  _clear_git_config_env
  bats() { :; }
  # shellcheck disable=SC1090
  source "$SCRIPT"
  bats5 noop
  [ -z "${GIT_CONFIG_COUNT+set}" ]
  [ -z "${GIT_CONFIG_KEY_0+set}" ]
  [ -z "${GIT_CONFIG_VALUE_0+set}" ]
}
