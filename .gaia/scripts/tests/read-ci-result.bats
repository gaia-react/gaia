#!/usr/bin/env bats
#
# Tests for .github/actions/gaia-ci-merge-and-watch/lib/read-ci-result.sh: the
# wrapper that runs wait-for-ci.sh and hands its caller a payload that is always
# readable, so a step body can filter it with jq without bracketing every read.
#
# The class under test is a guard that used to live, byte-identical, inside two
# `run:` bodies of the composite action. `run:` bodies are shell no `*.sh` glob
# reaches, so nothing linted them, nothing tested them, and a repair applied to
# one copy and not the other left the tree green (gaia-react/gaia#1704). The
# guard now has one home, and this suite is what holds it to its contract:
#
#   - a readable payload is forwarded byte-for-byte,
#   - an unreadable one is replaced by a synthesised `unknown` verdict that
#     names the status the helper exited with,
#   - the child's exit status is forwarded either way, because the step body
#     branches its error annotation on it.
#
# Two harnesses, because the two halves are reachable from different places.
# The forwarding half drives the real wait-for-ci.sh against a `gh` stub earlier
# on PATH, the same shape .gaia/scripts/tests/wait-for-ci-conclusion.bats uses,
# so the pass-through is exercised against the payloads production actually
# produces. The guard half cannot be reached that way at all: wait-for-ci.sh
# emits parseable JSON on every path it has, which is precisely why the guard is
# there for the paths it does not have (a killed process, a partial write). That
# half copies the script under test into a temp directory beside a stub sibling,
# which is not a weaker test of it: the script resolves wait-for-ci.sh by its
# own `BASH_SOURCE` directory, so the copy exercises that resolution rather than
# working around it, and the copy is taken from the tracked file on every run.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LIB_DIR="$REPO_ROOT/.github/actions/gaia-ci-merge-and-watch/lib"
  SCRIPT="$LIB_DIR/read-ci-result.sh"

  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  write_gh_stub

  PATH="$STUB_DIR:$PATH"
  export PATH
  export GITHUB_REPOSITORY="gaia-react/gaia"
  export DEFAULT_BRANCH="main"
  export TIMEOUT_SECONDS=3
  export SLEEP_SECONDS=1
}

# Answers the branch-protection probe with a failure, the unconfigured shape
# wait-for-ci.sh tolerates, and answers `run list` per GH_RUN_MODE. Only the
# modes this suite drives are implemented; wait-for-ci.sh's own conclusions are
# the sibling suite's subject, not this one's.
write_gh_stub() {
  cat >"$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

if [ "${1:-}" = "api" ]; then
  exit 1
fi

if [ "${1:-}" != "run" ]; then
  echo "gh stub: unexpected subcommand: $*" >&2
  exit 2
fi

case "${GH_RUN_MODE:-empty}" in
  empty) echo '[]' ;;
  green)
    echo '[{"conclusion":"success","status":"completed","name":"Tests","url":"https://example.invalid/run/1"}]'
    ;;
  red)
    echo '[{"conclusion":"failure","status":"completed","name":"Tests","url":"https://example.invalid/run/2"}]'
    ;;
  *)
    echo "gh stub: unknown GH_RUN_MODE: ${GH_RUN_MODE:-}" >&2
    exit 2
    ;;
esac
STUB
  chmod +x "$STUB_DIR/gh"
}

# Copies the tracked script into a temp directory beside a stub wait-for-ci.sh
# that emits $1 on stdout and exits $2, so the guard's two inputs -- what the
# child wrote and what status it left -- are both drivable.
with_stub_sibling() {
  local child_stdout="$1" child_status="$2"
  SANDBOX="$BATS_TEST_TMPDIR/lib"
  mkdir -p "$SANDBOX"
  cp "$SCRIPT" "$SANDBOX/read-ci-result.sh"
  cat >"$SANDBOX/wait-for-ci.sh" <<STUB
#!/usr/bin/env bash
printf '%s' '$child_stdout'
exit $child_status
STUB
  chmod +x "$SANDBOX/wait-for-ci.sh" "$SANDBOX/read-ci-result.sh"
}

@test "a terminal success is forwarded with wait-for-ci.sh's own exit status" {
  GH_RUN_MODE=green run bash "$SCRIPT" deadbeef

  [ "$status" -eq 0 ]
  grep -qF -- '"conclusion":"success"' <<<"$output"
}

@test "a non-zero conclusion forwards both the payload and the non-zero status" {
  GH_RUN_MODE=empty run bash "$SCRIPT" deadbeef

  [ "$status" -eq 1 ]
  grep -qF -- '"conclusion":"timeout"' <<<"$output"
}

@test "a failing run's url survives the wrapper" {
  GH_RUN_MODE=red run bash "$SCRIPT" deadbeef

  [ "$status" -eq 0 ]
  grep -qF -- 'https://example.invalid/run/2' <<<"$output"
}

@test "every forwarded payload is readable by the jq filters the step body runs" {
  GH_RUN_MODE=red run bash "$SCRIPT" deadbeef

  [ "$status" -eq 0 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "failure" ]
}

@test "a child that emits nothing yields an unknown verdict, not a jq parse error" {
  with_stub_sibling '' 137
  run bash "$SANDBOX/read-ci-result.sh" deadbeef

  [ "$status" -eq 137 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "unknown" ]
}

@test "a child that emits unparseable bytes yields an unknown verdict too" {
  with_stub_sibling 'gh: error connecting to api.github.com' 1

  run bash "$SANDBOX/read-ci-result.sh" deadbeef

  [ "$status" -eq 1 ]
  [ "$(jq -r '.conclusion' <<<"$output")" = "unknown" ]
}

@test "the synthesised verdict names the status the child exited with" {
  with_stub_sibling '' 137

  run bash "$SANDBOX/read-ci-result.sh" deadbeef

  grep -qF -- '137' <<<"$(jq -r '.error' <<<"$output")"
}

@test "the synthesised verdict carries the run_url key the step body reads" {
  with_stub_sibling 'not json' 1

  run bash "$SANDBOX/read-ci-result.sh" deadbeef

  # Asserted inside jq rather than against `jq -r`'s stdout: an unparseable
  # payload makes `jq -r` print nothing, which a comparison against the empty
  # string cannot tell apart from the key being correctly empty. `jq -e` fails
  # on the parse instead, so this reds when the guard is gone.
  jq -e '.run_url == ""' >/dev/null <<<"$output"
}

# The extraction's whole point is that the interpretation has one home. A step
# body that calls the poller directly, or re-inlines the fallback beside its own
# call, puts the copies back with nothing else going red -- which is the failure
# gaia-react/gaia#1704 was filed for, and `run:` bodies are exactly where no
# other check in this repository would see it.
#
# Stated as absences plus one presence rather than as counts: a watch step added
# later is welcome to exist, and only has to reach the poller the same way the
# existing ones do, so a cardinal here would red on a correct change.
@test "no step body reaches the poller or its fallback except through the helper" {
  local action="$REPO_ROOT/.github/actions/gaia-ci-merge-and-watch/action.yml"

  # The helper is the poller's sole caller, so action.yml names the poller
  # nowhere.
  grep -qF -- 'lib/wait-for-ci.sh' "$action" && return 1

  # And the synthesised verdict is the helper's alone; its message reappearing
  # in a `run:` body is a re-inlined copy of the guard.
  grep -qF -- 'without emitting readable JSON' "$action" && return 1

  grep -qF -- 'lib/read-ci-result.sh' "$action"
}

# The helper's guarantee covers what it prints, so it is void when the helper
# never runs: a missing file, a lost exec bit, an absent interpreter. The
# substitution yields the empty string, `jq -r` reads nothing from it and exits
# 0, and without a bracket in the caller the operator gets an annotation naming
# an empty conclusion and no cause at all. Nothing else in this repository
# executes a `run:` body, which is the blind spot gaia-react/gaia#1704 was filed
# about, so this has to run the real body rather than read it.
#
# The step set is derived from the action by its invocation line rather than
# listed here, and the count derived is checked against the count driven, so a
# watch step added or renamed later fails loudly instead of silently shrinking
# what this covers.
helper_steps() {
  awk '
    /^    - id: / { id = $0; sub(/^    - id: /, "", id) }
    /lib\/read-ci-result\.sh/ && id != "" { print id; id = "" }
  ' "$1"
}

# Pulls one step's `run:` block scalar out of the action, undenting the eight
# spaces the block carries, so the body runs as the shell it is on a runner.
extract_run_body() {
  awk -v want="$2" '
    $0 == "    - id: " want { in_step = 1; next }
    in_step && /^    - / { exit }
    in_step && $0 == "      run: |" { in_run = 1; next }
    in_run {
      if ($0 != "" && $0 !~ /^        /) exit
      sub(/^        /, "")
      print
    }
  ' "$1"
}

@test "a helper that never runs still leaves the operator a named cause" {
  local action="$REPO_ROOT/.github/actions/gaia-ci-merge-and-watch/action.yml"
  local steps expected driven=0

  steps="$(helper_steps "$action")"
  [ -n "$steps" ]
  expected="$(printf '%s\n' "$steps" | grep -c .)"

  # Present but not executable: the shape that yields an empty capture and a
  # non-zero status with the helper never printing anything.
  local libdir="$BATS_TEST_TMPDIR/deadlib"
  mkdir -p "$libdir/lib"
  printf '#!/usr/bin/env bash\nprintf notreached\n' >"$libdir/lib/read-ci-result.sh"
  chmod 000 "$libdir/lib/read-ci-result.sh"

  local step body_file
  for step in $steps; do
    body_file="$BATS_TEST_TMPDIR/$step.sh"
    extract_run_body "$action" "$step" >"$body_file"

    # A short extraction reads exactly like a body with no defect in it, so what
    # was extracted is asserted before it is trusted.
    grep -qF -- 'lib/read-ci-result.sh' "$body_file"

    GITHUB_ACTION_PATH="$libdir" \
      MERGE_SHA=deadbeef REVERT_MERGE_SHA=deadbeef \
      GITHUB_OUTPUT="$BATS_TEST_TMPDIR/$step.out" \
      run bash "$body_file"

    [ "$status" -ne 0 ]
    # The cause, not merely a non-zero exit: the regression this pins failed the
    # step while reporting an empty conclusion and no detail.
    grep -qF -- "ended as 'unknown'" <<<"$output"
    grep -qF -- 'without running' <<<"$output"

    driven=$(( driven + 1 ))
  done

  [ "$driven" -eq "$expected" ]
}
