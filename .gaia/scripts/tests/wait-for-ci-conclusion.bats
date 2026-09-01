#!/usr/bin/env bats
#
# Tests for .github/actions/gaia-ci-merge-and-watch/lib/wait-for-ci.sh: the
# post-merge CI poller whose one-line JSON `conclusion` is the composite
# action's own contract with its caller.
#
# The class under test is a deadline branch reachable from two conditions
# reporting only one of them. `gh run list` failing and `gh run list` returning
# an empty list both leave the poll loop with nothing terminal to report, and
# the script used to answer `timeout` for both. The repairs are opposites, a
# longer deadline against a working token, so the two states are split and the
# script is pinned here on which one it emits.
#
# The poller talks to the network through `gh` and nothing else, so every test
# drives it against a `gh` stub earlier on PATH. The stub answers the branch
# protection probe with a failure, which is the unconfigured-protection shape
# the script already tolerates, and answers `run list` per GH_RUN_MODE. Modes
# that change answer between polls count their invocations in a state file, so
# a test can pin which poll decides the verdict.
#
# TIMEOUT_SECONDS and SLEEP_SECONDS are the script's own documented overrides.
# They are set to seconds here rather than the production 5400/30 so a suite
# that has to actually exhaust a deadline runs in about as long as the deadline
# it sets. The deadline is measured from process start, so it has to stay clear
# of the script's own startup and of the stub spawns: a deadline short enough to
# be exhausted before the first poll sends every test down the no-poll path,
# where the verdict is whatever the script does having asked nothing. Every test
# that exhausts a deadline therefore asserts polls were actually made, so that
# harness failure reds instead of deciding the assertion.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.github/actions/gaia-ci-merge-and-watch/lib/wait-for-ci.sh"

  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  STUB_STATE="$BATS_TEST_TMPDIR/state"
  mkdir -p "$STUB_DIR" "$STUB_STATE"
  write_gh_stub

  PATH="$STUB_DIR:$PATH"
  export PATH STUB_STATE
  export GITHUB_REPOSITORY="gaia-react/gaia"
  export DEFAULT_BRANCH="main"
  export TIMEOUT_SECONDS=3
  export SLEEP_SECONDS=1
}

# The stub's `run list` arm writes to stdout what the real `gh --json` call
# would, and its failure arm writes to stderr and exits non-zero, because the
# split the script has to make is exactly between those two.
write_gh_stub() {
  cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

if [ "${1:-}" = "api" ]; then
  # No branch-protection contexts configured, the shape the script tolerates
  # with `|| true` and then skips its required-context filter for.
  exit 1
fi

if [ "${1:-}" != "run" ]; then
  echo "gh stub: unexpected subcommand: $*" >&2
  exit 2
fi

polls=0
if [ -f "$STUB_STATE/polls" ]; then
  polls="$(cat "$STUB_STATE/polls")"
fi
polls=$(( polls + 1 ))
printf '%s' "$polls" >"$STUB_STATE/polls"

emit_fail() {
  echo "gh: To get started with GitHub CLI, please run: gh auth login." >&2
  echo "gh: error connecting to api.github.com" >&2
  exit 1
}

case "${GH_RUN_MODE:-empty}" in
  fail) emit_fail ;;
  bloat)
    # One unbroken line, no newline: a line-based tail carries it whole.
    head -c "${BLOAT_BYTES:-200000}" /dev/zero | tr '\0' 'H' >&2
    exit 1
    ;;
  empty) echo '[]' ;;
  green)
    echo '[{"conclusion":"success","status":"completed","name":"Tests","url":"https://example.invalid/run/1"}]'
    ;;
  red)
    echo '[{"conclusion":"failure","status":"completed","name":"Tests","url":"https://example.invalid/run/2"}]'
    ;;
  fail-then-empty)
    if [ "$polls" -eq 1 ]; then
      emit_fail
    fi
    echo '[]'
    ;;
  empty-then-fail)
    if [ "$polls" -eq 1 ]; then
      echo '[]'
    else
      emit_fail
    fi
    ;;
  *)
    echo "gh stub: unknown GH_RUN_MODE: ${GH_RUN_MODE:-}" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$STUB_DIR/gh"
}

# Answers 0 rather than failing when the stub never ran, so a deadline eaten by
# startup reds on the poll-count assertion that names the harness rather than on
# a cat error that reads like a broken test.
polls_made() {
  if [ -f "$STUB_STATE/polls" ]; then
    cat "$STUB_STATE/polls"
  else
    printf '0'
  fi
}

@test "a query that never succeeds concludes query-failed, not timeout" {
  GH_RUN_MODE=fail run bash "$SCRIPT" deadbeef
  [ "$status" -eq 1 ]
  [ "$(polls_made)" -ge 1 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "query-failed" ]
  grep -qF -- 'timeout' <<<"$output" && return 1
  true
}

@test "query-failed carries the failing query's own stderr as evidence" {
  GH_RUN_MODE=fail run bash "$SCRIPT" deadbeef
  [ "$status" -eq 1 ]
  [ "$(polls_made)" -ge 1 ]
  # The operator's repair is chosen from this text, so the assertion is on the
  # message the script carried out of gh rather than on the field's presence.
  grep -qF -- 'gh auth login' <<<"$(jq -r '.error' <<<"$output")"
}

@test "an empty run list still concludes timeout" {
  GH_RUN_MODE=empty run bash "$SCRIPT" deadbeef
  [ "$status" -eq 1 ]
  [ "$(polls_made)" -ge 1 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "timeout" ]
  [ "$(jq -r '.run_url' <<<"$output")" = "" ]
}

@test "timeout carries no error field, so evidence marks the query failure alone" {
  GH_RUN_MODE=empty run bash "$SCRIPT" deadbeef
  [ "$(polls_made)" -ge 1 ]
  [ "$(jq -r 'has("error")' <<<"$output")" = "false" ]
}

@test "the last poll decides: a query that recovers concludes timeout" {
  # Two polls inside the deadline, the first failing and the second answering.
  # The script left off holding a readable answer, so the deadline it then hit
  # is a real timeout and reporting one is not the class this suite pins.
  GH_RUN_MODE=fail-then-empty run bash "$SCRIPT" deadbeef
  [ "$status" -eq 1 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "timeout" ]
  [ "$(polls_made)" -ge 2 ]
}

@test "the last poll decides: a query that breaks mid-watch concludes query-failed" {
  GH_RUN_MODE=empty-then-fail run bash "$SCRIPT" deadbeef
  [ "$status" -eq 1 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "query-failed" ]
  [ "$(polls_made)" -ge 2 ]
}

@test "a single huge stderr line still yields a readable query-failed verdict" {
  # The value reaches jq through argv, so an unbounded capture fails the exec
  # itself and the script dies emitting nothing: the operator loses the diagnosis
  # at exactly the moment the response body is the evidence. The fixture has to
  # clear BOTH ceilings or it proves nothing on one of the two platforms this
  # suite runs on -- Linux caps a single argument at 128 KiB (MAX_ARG_STRLEN)
  # while macOS caps the whole list at about 1 MiB -- and at 200 KiB the mutant
  # with the bound removed survives on macOS.
  BLOAT_BYTES=2000000 GH_RUN_MODE=bloat run bash "$SCRIPT" deadbeef
  [ "$status" -eq 1 ]
  [ "$(polls_made)" -ge 1 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "query-failed" ]
  # Pinned to the emitted length, not merely to "smaller than the input": a bound
  # that drifted upward would still be smaller and would still pass a comparison.
  [ "$(jq -r '.error | length' <<<"$output")" -eq 500 ]
}

@test "a green terminal run still concludes success" {
  TIMEOUT_SECONDS=60 GH_RUN_MODE=green run bash "$SCRIPT" deadbeef
  [ "$status" -eq 0 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "success" ]
}

@test "a red terminal run still concludes failure and carries the run url" {
  TIMEOUT_SECONDS=60 GH_RUN_MODE=red run bash "$SCRIPT" deadbeef
  [ "$status" -eq 0 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "failure" ]
  [ "$(jq -r '.run_url' <<<"$output")" = "https://example.invalid/run/2" ]
}

@test "the header documents every conclusion these tests drive out of the script" {
  # The header is the contract action.yml reads, so a conclusion that reaches
  # the caller without a header line is a contract change nobody downstream was
  # told about. What this pins is the header against the values driven above,
  # and only that: every conclusion but `timeout` is built inside a jq program,
  # so the emission set is not one grep over the script's text, and a further
  # conclusion added with no header line is left to review rather than caught
  # here.
  documented="$(sed -n 's/^#[[:space:]]*{"conclusion":"\([a-z-]*\)".*/\1/p' "$SCRIPT" | LC_ALL=C sort)"
  [ "$documented" = "$(printf '%s\n' failure query-failed success timeout | LC_ALL=C sort)" ]
}
