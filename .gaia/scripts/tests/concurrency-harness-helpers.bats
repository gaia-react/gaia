#!/usr/bin/env bats
# The delivery primitives in .gaia/tests/concurrency/lib/concurrency-harness.sh:
# `gaia_deliver_hook` and the `run_with` runner it composes with.
#
# Why these are pinned here rather than in the concurrency meter itself: the
# meter's scenario list is one `@test` per scenario
# (.gaia/tests/concurrency/README.md), so a primitive's own unit coverage does
# not belong mixed into that list. This sits beside bats-files-helper.bats,
# which pins the other cross-suite bats primitive for the same reason.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  . "$REPO_ROOT/.gaia/tests/concurrency/lib/concurrency-harness.sh"

  # A stand-in hook: echoes what it was handed on stdin, plus one environment
  # variable, so a test can tell "delivered" from "never ran".
  HOOK="$BATS_TEST_TMPDIR/hook.sh"
  cat > "$HOOK" <<'SH'
printf 'PAYLOAD=[%s] STUB=[%s]\n' "$(cat)" "${STUBVAR:-unset}"
SH
}

# --- gaia_deliver_hook -----------------------------------------------------

@test "gaia_deliver_hook delivers the payload on stdin byte-exact" {
  run gaia_deliver_hook '{"a":1}' "$HOOK"
  [ "$status" -eq 0 ]
  grep -qF -- 'PAYLOAD=[{"a":1}]' <<<"$output"
}

@test "gaia_deliver_hook delivers a payload carrying quotes and shell metacharacters" {
  # The whole reason the payload is positional rather than interpolated: any of
  # these would terminate a quoted wrapper early and deliver something else.
  payload='it'"'"'s {"k":"v"} $(boom) `boom` "quoted"'
  run gaia_deliver_hook "$payload" "$HOOK"
  [ "$status" -eq 0 ]
  grep -qF -- 'PAYLOAD=[it'"'"'s {"k":"v"} $(boom) `boom` "quoted"]' <<<"$output"
}

@test "gaia_deliver_hook propagates the hook's own exit status" {
  printf 'exit 7\n' > "$HOOK"
  run gaia_deliver_hook 'x' "$HOOK"
  [ "$status" -eq 7 ]
}

# --- run_with, the happy path ----------------------------------------------

@test "run_with applies an assignment and runs the command" {
  run run_with STUBVAR=applied -- gaia_deliver_hook '{"b":2}' "$HOOK"
  [ "$status" -eq 0 ]
  grep -qF -- 'PAYLOAD=[{"b":2}]' <<<"$output"
  grep -qF -- 'STUB=[applied]' <<<"$output"
}

@test "run_with applies a value containing whitespace and quotes" {
  run run_with STUBVAR="a b'\"c" -- gaia_deliver_hook 'x' "$HOOK"
  [ "$status" -eq 0 ]
  grep -qF -- 'STUB=[a b'"'"'"c]' <<<"$output"
}

@test "run_with leaks no assignment into the caller" {
  # Deliberately NOT wrapped in `run`. bats' `run` executes its command inside a
  # command-substitution subshell, which isolates the export on its own however
  # `run_with` is written, so a `run`-wrapped version of this test passes even
  # against a `run_with` whose own `( )` has been removed. It is this suite's
  # only coverage of the containment, and the meter depends on it: C5-01, C5-04
  # and C7-02 each carry later assertions inside the same @test body that a
  # leaked HOME or PATH would silently change.
  run_with STUBVAR=leaked -- gaia_deliver_hook 'x' "$HOOK" >/dev/null

  [ -z "${STUBVAR:-}" ] || return 1
  # The helper's own loop variables are contained by the same `( )`.
  [ -z "${_rw_found:-}" ] || return 1
  [ -z "${_rw_arg:-}" ] || return 1
  return 0
}

@test "run_with composes inside run_in without losing either the cwd or the env" {
  dir="$BATS_TEST_TMPDIR/sub"
  mkdir -p "$dir"
  printf 'printf "CWD=[%%s] STUB=[%%s]\\n" "$(pwd -P)" "${STUBVAR:-unset}"\n' > "$HOOK"

  run run_in "$dir" -- run_with STUBVAR=nested -- gaia_deliver_hook 'x' "$HOOK"
  [ "$status" -eq 0 ]
  grep -qF -- "CWD=[$(cd "$dir" && pwd -P)]" <<<"$output"
  grep -qF -- 'STUB=[nested]' <<<"$output"
}
