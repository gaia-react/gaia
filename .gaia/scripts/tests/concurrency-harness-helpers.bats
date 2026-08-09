#!/usr/bin/env bats
# The delivery primitives in .gaia/tests/concurrency/lib/concurrency-harness.sh:
# `gaia_deliver_hook` and the `run_with` runner it composes with.
#
# Why these are pinned here rather than in the concurrency meter itself: the
# meter's scenario list and its `target` denominator are frozen
# (.gaia/tests/concurrency/README.md, expected-status.txt), so a primitive's own
# unit coverage cannot be added there without moving a number that moves only by
# the maintainer's word. This sits beside bats-files-helper.bats, which pins the
# other cross-suite bats primitive for the same reason.
#
# The failure mode being pinned is specific and it is NOT "the meter goes red".
# The meter cannot see this class at all. Under bats' `run` errexit is off, so a
# `run_with` that silently accepted a missing `--` would eat the command as
# environment assignments, invoke no hook, and still report status 0 with empty
# output; a scenario asserting `[ "$status" -eq 0 ]` plus an absence then passes
# against a hook that never ran. That is the vacuous green the whole primitive
# exists to prevent, so it is asserted directly here.
#
# Assertion style (`.claude/rules/bats-assertions.md`): POSIX `[ ]` and explicit
# `return 1`, never a bare `[[ ]]`, so these fail correctly under macOS's bash
# 3.2 as well as CI's bash 5.
#
# The misuse arms pin the exact status 64 rather than merely a non-zero one, and
# each names the refusal it expects. A `-ne 0` check greens on 127 or 1 as
# readily as on 64, so the documented status would drift unnoticed; and a test
# that names no message can be satisfied by a different arm firing, which is how
# a guard disappears with its own test still green. Test 11 is the exception: its
# message is bash's own `not a valid identifier` wording, which is not safe to
# pin across bash versions.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
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

# --- run_with, the misuse arms. Each must fail LOUDLY, never green ----------
#
# These are the assertions that would have caught the silent-green defect. Each
# checks the exact status AND that the command never ran, because a status check
# alone would pass on any failure including the wrong one.

@test "run_with refuses a missing -- separator rather than eating the command" {
  run run_with STUBVAR=x gaia_deliver_hook '{"c":3}' "$HOOK"
  [ "$status" -eq 64 ]
  grep -qF -- 'missing -- separator' <<<"$output"
  # The hook must not have run: its output would carry PAYLOAD=.
  grep -qF -- 'PAYLOAD=' <<<"$output" && return 1
  return 0
}

@test "run_with refuses when nothing follows the separator" {
  run run_with STUBVAR=x --
  [ "$status" -eq 64 ]
  grep -qF -- 'no command after --' <<<"$output"
}

@test "run_with refuses an empty assignment rather than running without it" {
  run run_with "" -- gaia_deliver_hook 'x' "$HOOK"
  [ "$status" -eq 64 ]
  # Name the arm. Without this the `case` arm could be deleted and this test
  # would stay green, because `export ""` fails on its own and the `|| exit 64`
  # beside it would catch that instead.
  grep -qF -- 'not an assignment' <<<"$output"
  grep -qF -- 'PAYLOAD=' <<<"$output" && return 1
  return 0
}

@test "run_with refuses a malformed assignment rather than running without it" {
  run run_with 'FOO-BAR=1' -- gaia_deliver_hook 'x' "$HOOK"
  [ "$status" -eq 64 ]
  grep -qF -- 'PAYLOAD=' <<<"$output" && return 1
  return 0
}

@test "run_with refuses a bare name rather than applying nothing" {
  # The one malformed shape `export` itself accepts: `export STUBVAR` succeeds
  # and applies no value, so without an explicit check the command would run
  # with its override silently absent, which is this suite's whole subject.
  run run_with STUBVAR -- gaia_deliver_hook 'x' "$HOOK"
  [ "$status" -eq 64 ]
  grep -qF -- 'not an assignment' <<<"$output"
  grep -qF -- 'PAYLOAD=' <<<"$output" && return 1
  return 0
}
