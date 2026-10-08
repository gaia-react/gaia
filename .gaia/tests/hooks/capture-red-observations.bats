#!/usr/bin/env bats

# Tests for the RED-capture hook (.claude/hooks/capture-red-observations.sh).
#
# The hook is the OBSERVE-AND-RECORD half of the RED-verification gate. On a
# `(pnpm|npm) test --run [scope]` PostToolUse, it re-invokes vitest with the
# json reporter, reads the per-test results, and appends every genuinely-failing
# test to the ledger (.gaia/local/red-ledger/<tree-key>/observations.jsonl). It
# only observes; it never blocks and always exits 0.
#
# vitest's config `include` glob is `./app/**/*.test.{ts,tsx}`, so the fixture
# test files under .gaia/tests/hooks/fixtures/red-ledger/ cannot be run by a
# real vitest invocation (they fall outside the include set). The deterministic
# assertions therefore feed CANNED vitest json via the hook's documented test
# seam RED_CAPTURE_JSON_OVERRIDE, while the source-file fixtures supply the real
# bodies the signal helper hashes; so the signals are genuine, not stubbed. The
# negative/robustness cases exercise the real (no-override) code path: they bail
# before vitest ever runs, so they stay fast and offline.
#
# The hook resolves the ledger via the shared red_ledger_path (tree-keyed,
# under .gaia/local/red-ledger/), so the suite runs from the repo root (like
# red-ledger-lib.bats) and asserts on that same resolved, gitignored path.
# setup/teardown stash and restore any pre-existing local ledger so a
# developer's scratch ledger is never clobbered.

# Every legacy case here reads and writes the one ledger this checkout keys, and
# its setup/teardown stash, delete and restore that file. Under `bats --jobs`
# the cases of a file run in parallel, so they would delete each other's ledger
# mid-test. Keep this file's cases serial; other files still run in parallel.
# shellcheck disable=SC2034 # read by bats itself
BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # The Node helpers this suite drives resolve `typescript` from node_modules.
  # The gate fails rather than skips on a CI runner, where the dependency is a
  # precondition the job installs; see the helper for why.
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$REPO_ROOT"
  HOOK="$REPO_ROOT/.claude/hooks/capture-red-observations.sh"
  FIXTURE_RELATIVE_DIRECTORY=".gaia/tests/hooks/fixtures/red-ledger"
  JSON_FIXTURE_RELATIVE_DIRECTORY="$FIXTURE_RELATIVE_DIRECTORY/json"
  # Ask the shipped lib where the ledger belongs (tree-keyed) rather than
  # hardcoding a second copy of the keyed literal.
  LEDGER_ABSOLUTE_PATH="$( . "$REPO_ROOT/.claude/hooks/lib/red-ledger.sh" && red_ledger_path "$REPO_ROOT" )"

  # Stash any pre-existing local ledger; restore in teardown.
  STASH=""
  if [ -f "$LEDGER_ABSOLUTE_PATH" ]; then
    STASH=$(mktemp -t red-ledger-stash-XXXXXX)
    cp "$LEDGER_ABSOLUTE_PATH" "$STASH"
  fi
  rm -f "$LEDGER_ABSOLUTE_PATH"
}

teardown() {
  rm -f "$LEDGER_ABSOLUTE_PATH"
  if [ -n "${STASH:-}" ] && [ -f "$STASH" ]; then
    mkdir -p "$(dirname "$LEDGER_ABSOLUTE_PATH")"
    cp "$STASH" "$LEDGER_ABSOLUTE_PATH"
    rm -f "$STASH"
  fi
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  [ -n "${STUB_PNPM_ARGS_FILE:-}" ] && rm -f "$STUB_PNPM_ARGS_FILE"
  return 0
}

# Build a PostToolUse Bash payload and pipe it to the hook from the repo root.
# Args: <tool_name> <command> [json_override_relpath]
run_capture() {
  local tool="$1" command="$2" override_relative_path="${3:-}"
  local payload
  payload=$(jq -n --arg t "$tool" --arg command "$command" \
    '{tool_name: $t, tool_input: {command: $command}, tool_response: {stdout: "", stderr: "", interrupted: false}}')

  # The override is set on the invocation as a whole, so it is in the
  # environment the hook inherits rather than on one side of the pipe.
  if [ -n "$override_relative_path" ]; then
    RED_CAPTURE_JSON_OVERRIDE="$REPO_ROOT/$override_relative_path" \
      invoke_hook_in "$REPO_ROOT" "$payload" "$HOOK"
  else
    invoke_hook_in "$REPO_ROOT" "$payload" "$HOOK"
  fi
}

# The same, from a subdirectory of the repository root. The agent's working
# directory is wherever the session last left it, so the capture has to record
# from a depth nobody chose.
# Args: <subdir> <tool_name> <command> [json_override_relpath]
run_capture_from() {
  local sub="$1" tool="$2" command="$3" override_relative_path="${4:-}"
  local payload
  payload=$(jq -n --arg t "$tool" --arg command "$command" \
    '{tool_name: $t, tool_input: {command: $command}, tool_response: {stdout: "", stderr: "", interrupted: false}}')
  mkdir -p "$REPO_ROOT/$sub"
  if [ -n "$override_relative_path" ]; then
    RED_CAPTURE_JSON_OVERRIDE="$REPO_ROOT/$override_relative_path" \
      invoke_hook_in "$REPO_ROOT/$sub" "$payload" "$HOOK"
  else
    invoke_hook_in "$REPO_ROOT/$sub" "$payload" "$HOOK"
  fi
}

# Count ledger lines (0 when the file is absent).
ledger_lines() {
  [ -f "$LEDGER_ABSOLUTE_PATH" ] && wc -l < "$LEDGER_ABSOLUTE_PATH" | tr -d ' ' || echo 0
}

# A fake `pnpm` ahead of the real one on PATH. It records every argv word it
# receives to STUB_PNPM_ARGS_FILE (one per line) and, when STUB_PNPM_JSON_SOURCE
# is set, copies that canned json to whatever path `--outputFile=` names. This
# drives the hook's real (non-override) scope-parsing code and lets a test
# assert the exact tokens that reached `vitest --run` -- in particular, that a
# redirection token never reaches that argv -- without a real vitest
# invocation and without touching this checkout's own node_modules, which a
# concurrently-running agent in this worktree also depends on.
stub_pnpm() {
  STUB_BIN=$(mktemp -d)
  cat > "$STUB_BIN/pnpm" <<'SH'
#!/bin/sh
: > "$STUB_PNPM_ARGS_FILE"
output_file=""
for argument in "$@"; do
  printf '%s\n' "$argument" >> "$STUB_PNPM_ARGS_FILE"
  case "$argument" in
    --outputFile=*) output_file="${argument#--outputFile=}" ;;
  esac
done
if [ -n "$output_file" ] && [ -n "${STUB_PNPM_JSON_SOURCE:-}" ]; then
  cp "$STUB_PNPM_JSON_SOURCE" "$output_file"
fi
exit 0
SH
  chmod +x "$STUB_BIN/pnpm"
  PATH="$STUB_BIN:$PATH"
  export PATH
  STUB_PNPM_ARGS_FILE=$(mktemp -t red-capture-stub-args-XXXXXX)
  export STUB_PNPM_ARGS_FILE
}

# Runs a real scope arg with REDIRECTION_TOKEN appended, via the stub pnpm, and
# asserts the token never reaches vitest's argv while the real scope arg does.
assert_scope_survives_redirect() {
  local redir="$1"
  stub_pnpm
  STUB_PNPM_JSON_SOURCE="$REPO_ROOT/$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  export STUB_PNPM_JSON_SOURCE
  run_capture "Bash" "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts $redir"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  grep -qF -- "$FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" "$STUB_PNPM_ARGS_FILE"
  grep -E '[<>]' "$STUB_PNPM_ARGS_FILE" && return 1
  return 0
}

# Runs a real scope arg with a SPACED redirection (operator and target as two
# whitespace-separated tokens, e.g. "2> err.log") appended, via the stub pnpm,
# and asserts the scope arg reaches vitest's argv while the target's exact
# line does not. Unlike assert_scope_survives_redirect above, a spaced
# redirection's target carries no angle bracket, so "no `<`/`>` in the args"
# cannot see it leaking as a bogus extra scope token; asserting the target's
# exact line is absent is the check that can.
assert_spaced_redirect_target_absent() {
  local redir="$1" target="$2"
  stub_pnpm
  STUB_PNPM_JSON_SOURCE="$REPO_ROOT/$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  export STUB_PNPM_JSON_SOURCE
  run_capture "Bash" "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts $redir"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  grep -qF -- "$FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" "$STUB_PNPM_ARGS_FILE"
  grep -qxF "$target" "$STUB_PNPM_ARGS_FILE" && return 1
  return 0
}

# --- failing run records one RED per genuinely-failing test -------------------

@test "assertion-fail run appends exactly one RED for the failing test" {
  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]

  line=$(cat "$LEDGER_ABSOLUTE_PATH")
  [ "$(printf '%s' "$line" | jq -r '.schema')" = "1" ]
  [ "$(printf '%s' "$line" | jq -r '.file')" = "$FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" ]
  [ "$(printf '%s' "$line" | jq -r '.fullName')" = "fails on assertion" ]
  [ "$(printf '%s' "$line" | jq -r '.failureKind')" = "assertion" ]
  [[ "$(printf '%s' "$line" | jq -r '.signal')" == sha256:* ]]
  [[ "$(printf '%s' "$line" | jq -r '.observedAt')" == *T*Z ]]
}

@test "still records a RED when the working directory is a subdirectory" {
  # This hook is the FEEDER for the RED-before-GREEN commit gate, and that gate
  # now enforces from a subdirectory. The signal helper reads the test file at a
  # repo-relative path and returns 0 with no output when it cannot see it, so a
  # cwd-resolved read here records nothing and says nothing. Feeder silent plus
  # gate active is the worst of the two states: every new test denied, with no
  # way to satisfy the demand.
  run_capture_from "app" "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  line=$(cat "$LEDGER_ABSOLUTE_PATH")
  [ "$(printf '%s' "$line" | jq -r '.fullName')" = "fails on assertion" ]
  grep -qE '^sha256:' <<<"$(printf '%s' "$line" | jq -r '.signal')"
}

@test "recorded signal matches the helper's signal for that test" {
  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  [ "$status" -eq 0 ]

  recorded=$(printf '%s' "$(cat "$LEDGER_ABSOLUTE_PATH")" | jq -r '.signal')
  expected=$(cd "$REPO_ROOT" && node .gaia/scripts/red-ledger/extract-test-signals.mjs \
    "$FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" \
    | jq -r 'select(.fullName == "fails on assertion") | .signal')
  [ -n "$expected" ]
  [ "$recorded" = "$expected" ]
}

@test "the passing test in the same file is NOT recorded" {
  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  [ "$status" -eq 0 ]
  # Only one line, and it is the failing one; the passing test never appears.
  [ "$(ledger_lines)" -eq 1 ]
  run grep -c '"fullName":"passes fine"' "$LEDGER_ABSOLUTE_PATH"
  [ "$output" = "0" ]
}

# --- failureKind classification -----------------------------------------------

@test "failureKind is runtime for a missing-implementation error" {
  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/runtime-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/runtime-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  [ "$(cat "$LEDGER_ABSOLUTE_PATH" | jq -r '.failureKind')" = "runtime" ]
  [ "$(cat "$LEDGER_ABSOLUTE_PATH" | jq -r '.fullName')" = "calls a not-yet-implemented function" ]
}

# --- no RED for passing-only and collection-error runs ------------------------

@test "passing-only run writes no ledger lines" {
  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/two-tests.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/passing-only.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "collection-error run writes no ledger lines (coarse false-RED guard)" {
  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/broken.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/collection-error.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

# --- scope match: only `(pnpm|npm) test … --run …` acts -----------------------

@test "bare pnpm test (no --run) exits 0 and writes nothing" {
  # No override: must bail at the scope check before vitest is ever invoked.
  run_capture "Bash" "pnpm test"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "unrelated command (git status) exits 0 and writes nothing" {
  run_capture "Bash" "git status"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "pnpm typecheck exits 0 and writes nothing" {
  run_capture "Bash" "pnpm typecheck"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "an empty scope skips the capture (no full-suite re-run, writes nothing) and says so" {
  # No override and no scope arg after `test`: the hook must SKIP the capture
  # rather than re-run the whole vitest suite, and must say so in a
  # model-visible diagnostic naming the scoped command. It bails before vitest
  # is ever invoked, so it stays fast and offline and records nothing.
  run_capture "Bash" "pnpm test --run"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$output"
  jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF -- 'pnpm test --run <test-file>'
  # No temp vitest json was produced (the skip happens before the mktemp).
  local ledger_directory
  ledger_directory=$(dirname "$LEDGER_ABSOLUTE_PATH")
  run bash -c "ls '$ledger_directory/.tmp'/vitest-*.json 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "an unscoped run piped to tail still announces the skip" {
  stub_pnpm
  run_capture "Bash" "pnpm test --run | tail -5"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  [ ! -s "$STUB_PNPM_ARGS_FILE" ]
  jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF -- 'pnpm test --run <test-file>'
}

@test "commands that never reach the scope check emit no diagnostic" {
  # Guard, not RED: the diagnostic is branch-local to the empty-scope skip, and
  # must stay silent on every command that returns before reaching it.
  for command in "git status" "pnpm test" "pnpm typecheck" 'gh pr create --body "see `pnpm test --run` output"'; do
    run_capture "Bash" "$command"
    [ "$status" -eq 0 ] || return 1
    [ -z "$output" ] || return 1
  done
}

@test "a scoped run emits no skip diagnostic" {
  stub_pnpm
  STUB_PNPM_JSON_SOURCE="$REPO_ROOT/$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  export STUB_PNPM_JSON_SOURCE
  run_capture "Bash" "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts"
  [ "$status" -eq 0 ]
  grep -qF -- 'RED capture skipped' <<<"$output" && return 1
  true
}

@test "a scoped invocation still parses its scope (the skip is no-scope only)" {
  # A parseable scope is unaffected by the skip: with the override seam supplying
  # canned json, the scoped path records exactly as before. This guards that the
  # skip changed ONLY the no-scope fallback, not the scoped behavior.
  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
}

@test "a --body string mentioning 'pnpm test --run' exits 0 and writes nothing" {
  # Command-position anchoring: the phrase appears inside a PR-body argument,
  # not as a `pnpm`/`npm` command word, so no spurious full-suite vitest re-run
  # fires and nothing is recorded.
  run_capture "Bash" 'gh pr create --body "see `pnpm test --run` output"'
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "a non-Bash tool call exits 0 and writes nothing" {
  run_capture "Edit" "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

# --- robustness: malformed input, empty command -------------------------------

@test "malformed stdin (not json) exits 0 and writes nothing" {
  invoke_hook_in "$REPO_ROOT" 'not json at all' "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "empty command exits 0 and writes nothing" {
  run_capture "Bash" ""
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}


@test "a second failing run appends rather than overwriting" {
  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]

  run_capture "Bash" \
    "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/runtime-fail.test.ts" \
    "$JSON_FIXTURE_RELATIVE_DIRECTORY/runtime-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 2 ]
}

@test "a leftover tempfile at the historical mktemp name does not disable capture" {
  # Regression guard: BSD mktemp only substitutes a TRAILING run of X's, so
  # the hook's old "vitest-XXXXXX.json" template resolved to that literal
  # name and a leftover file there made every later mktemp call fail, which
  # silently disabled capture until the leftover was removed by hand. Uses
  # stub_pnpm (not RED_CAPTURE_JSON_OVERRIDE) so this drives the hook's real
  # mktemp call rather than the override seam that bypasses it.
  local temporary_directory
  temporary_directory="$(dirname "$LEDGER_ABSOLUTE_PATH")/.tmp"
  mkdir -p "$temporary_directory"
  touch "$temporary_directory/vitest-XXXXXX.json"

  stub_pnpm
  STUB_PNPM_JSON_SOURCE="$REPO_ROOT/$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json"
  export STUB_PNPM_JSON_SOURCE
  run_capture "Bash" "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]

  rm -f "$temporary_directory/vitest-XXXXXX.json"
}

# --- redirection tokens do not leak into the scope arg (gaia-react/gaia#2225) -
#
# These drive the REAL (non-override) scope-parsing code: the override seam
# short-circuits scope computation entirely, so a redirection-filtering
# regression would be invisible to a test built on it.

@test "a narrow scope survives a trailing stderr-redirect token (2>&1)" {
  assert_scope_survives_redirect '2>&1'
}

@test "a narrow scope survives a trailing stdout-redirect token (1>out.log)" {
  assert_scope_survives_redirect '1>out.log'
}

@test "a narrow scope survives a trailing append-redirect token (>>append.log)" {
  assert_scope_survives_redirect '>>append.log'
}

@test "a narrow scope survives a trailing stderr-to-devnull token (2>/dev/null)" {
  assert_scope_survives_redirect '2>/dev/null'
}

@test "a narrow scope survives a trailing input-redirect token (<input)" {
  assert_scope_survives_redirect '<input'
}

@test "a narrow scope survives a trailing heredoc-marker token (<<EOF)" {
  assert_scope_survives_redirect '<<EOF'
}

@test "an unscoped run with only a stderr-redirect token hits the no-scope skip (2>&1)" {
  # No real scope token, only a redirection: after the fix the scope walk
  # yields nothing (the redirection is filtered rather than read as a bogus
  # scope path), so this falls into the SAME designed "no scope parsed" skip
  # as a bare `--run`, rather than a scoped re-run against a nonexistent file.
  # `stub_pnpm` here (rather than the ledger-only checks used elsewhere in
  # this file) is load-bearing: the real vitest binary resolves a bogus
  # pattern to zero matches just as fast as the skip exits, so a ledger-only
  # assertion cannot tell the skip from a real re-run that happened to match
  # nothing -- it stays green on both sides of this fix. Asserting the stub
  # was never invoked is the one check that distinguishes them.
  stub_pnpm
  run_capture "Bash" "pnpm test --run 2>&1"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  [ ! -s "$STUB_PNPM_ARGS_FILE" ]
}

@test "an unscoped run with only a stdout-redirect token hits the no-scope skip (>out)" {
  stub_pnpm
  run_capture "Bash" "pnpm test --run >out"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  [ ! -s "$STUB_PNPM_ARGS_FILE" ]
}

# --- spaced redirections: operator and target are TWO whitespace-separated
# tokens (gaia-react/gaia#2225 residual). awk word-splits $test_segment, so a
# spaced redirection's operator and target never travel together the way the
# attached forms above (1>out.log, <<EOF, …) do. Asserting only "no `<`/`>`
# in the args" (as assert_scope_survives_redirect does) cannot see the
# target leaking as a bogus extra scope token, so these assert the target's
# exact line is absent from the stub's recorded argv.

@test "a narrow scope survives a trailing spaced stdout-redirect (> out.log)" {
  assert_spaced_redirect_target_absent '> out.log' 'out.log'
}

@test "a narrow scope survives a trailing spaced stderr-redirect (2> err.log)" {
  assert_spaced_redirect_target_absent '2> err.log' 'err.log'
}

@test "a narrow scope survives a leading spaced input-redirect (< input)" {
  assert_spaced_redirect_target_absent '< input' 'input'
}

@test "an unscoped run with only a spaced stdout-redirect hits the no-scope skip (> out)" {
  stub_pnpm
  run_capture "Bash" "pnpm test --run > out"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  [ ! -s "$STUB_PNPM_ARGS_FILE" ]
}

# --- package scope: the owning package decides where the json re-run happens ---
#
# These cases run the hook against a fixture repository, not this checkout, with
# the real (non-override) re-run path. `pnpm` and `vitest` are stubs on PATH:
# the pnpm shim honors only `-C <dir> exec <command> ...`, and the vitest stub
# records the directory and scope it was invoked with, then reports one failing
# test whose file name is absolute, as a real vitest report's is.

PACKAGE_TEST_BODY='import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'

make_package_fixture() {
  FIXTURE=$(cd "$BATS_TEST_TMPDIR" && pwd -P)/package-fixture
  mkdir -p "$FIXTURE/.gaia/scripts" "$FIXTURE/frontend/app/utils" "$FIXTURE/app/utils"
  git -C "$FIXTURE" init --quiet --initial-branch=main
  git -C "$FIXTURE" config user.email "test@example.com"
  git -C "$FIXTURE" config user.name "Test"
  git -C "$FIXTURE" config commit.gpgsign false
  ln -s "$REPO_ROOT/.gaia/scripts/red-ledger" "$FIXTURE/.gaia/scripts/red-ledger"
  printf '%s' "$PACKAGE_TEST_BODY" >"$FIXTURE/frontend/app/utils/x.test.ts"
  printf '%s' "$PACKAGE_TEST_BODY" >"$FIXTURE/app/utils/x.test.ts"
  echo "# readme" >"$FIXTURE/README.md"
  git -C "$FIXTURE" add README.md
  git -C "$FIXTURE" commit --quiet -m init
  FIXTURE_LEDGER="$( . "$REPO_ROOT/.claude/hooks/lib/red-ledger.sh" && red_ledger_path "$FIXTURE" )"

  STUB_BIN=$(mktemp -d)
  cat >"$STUB_BIN/pnpm" <<'SH'
#!/bin/sh
[ "$1" = "-C" ] || exit 64
directory="$2"
shift 2
[ "$1" = "exec" ] || exit 64
shift
cd "$directory" || exit 65
exec "$@"
SH
  cat >"$STUB_BIN/vitest" <<'SH'
#!/bin/sh
output_file=""
scope=""
for argument in "$@"; do
  case "$argument" in
    --outputFile=*) output_file="${argument#--outputFile=}" ;;
    --*) ;;
    *) scope="$argument" ;;
  esac
done
printf 'cwd=%s\nscope=%s\n' "$(pwd -P)" "$scope" >>"$STUB_VITEST_LOG"
cat >"$output_file" <<JSON
{"testResults":[{"name":"$(pwd -P)/$scope","status":"failed","message":"","assertionResults":[{"title":"adds two numbers","fullName":"adds two numbers","status":"failed","failureMessages":["AssertionError: expected 1 to be 2"]}]}]}
JSON
exit 1
SH
  chmod +x "$STUB_BIN/pnpm" "$STUB_BIN/vitest"
  PATH="$STUB_BIN:$PATH"
  STUB_VITEST_LOG="$BATS_TEST_TMPDIR/vitest.log"
  export PATH STUB_VITEST_LOG
}

# Drive the hook for <command> with payload cwd <directory>, in the fixture.
run_capture_in_fixture() {
  local directory="$1" command="$2" payload
  payload=$(jq -nc --arg c "$command" --arg d "$directory" \
    '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}, tool_response:{stdout:"", stderr:"", interrupted:false}}')
  invoke_hook_in "$directory" "$payload" "$HOOK"
}

fixture_ledger_lines() {
  [ -f "$FIXTURE_LEDGER" ] && wc -l <"$FIXTURE_LEDGER" | tr -d ' ' || echo 0
}

# The RED the capture recorded is keyed by the repo-relative path the commit
# gate computes for the staged file, and the stub saw the package directory and
# the package-relative scope.
assert_frontend_capture() {
  [ "$status" -eq 0 ]
  [ "$(fixture_ledger_lines)" -eq 1 ]
  [ "$(jq -r '.file' "$FIXTURE_LEDGER")" = "frontend/app/utils/x.test.ts" ]
  grep -qxF -- "cwd=$FIXTURE/frontend" "$STUB_VITEST_LOG"
  grep -qxF -- "scope=app/utils/x.test.ts" "$STUB_VITEST_LOG"
}

@test "package scope: the root proxy 'pnpm test --run frontend/...' re-runs in frontend/ with a package-relative scope" {
  make_package_fixture
  run_capture_in_fixture "$FIXTURE" "pnpm test --run frontend/app/utils/x.test.ts"
  assert_frontend_capture
}

@test "package scope: 'pnpm -C frontend test --run app/...' from the root records the repo-relative key" {
  make_package_fixture
  run_capture_in_fixture "$FIXTURE" "pnpm -C frontend test --run app/utils/x.test.ts"
  assert_frontend_capture
}

@test "package scope: 'pnpm --filter frontend test --run app/...' resolves the package through the registry" {
  make_package_fixture
  run_capture_in_fixture "$FIXTURE" "pnpm --filter frontend test --run app/utils/x.test.ts"
  assert_frontend_capture
}

@test "package scope: 'pnpm test --run app/...' from inside frontend/ is keyed frontend/app/..." {
  make_package_fixture
  run_capture_in_fixture "$FIXTURE/frontend" "pnpm test --run app/utils/x.test.ts"
  assert_frontend_capture
}

@test "package scope: the recorded key is the one the commit gate computes, so the retried commit is allowed" {
  make_package_fixture
  git -C "$FIXTURE" add frontend/app/utils/x.test.ts
  local commit_payload
  commit_payload=$(jq -nc '{tool_name:"Bash", tool_input:{command:"git commit -m change"}}')
  invoke_hook_in "$FIXTURE" "$commit_payload" "$REPO_ROOT/.claude/hooks/red-verify-commit-check.sh"
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"

  run_capture_in_fixture "$FIXTURE" "pnpm test --run frontend/app/utils/x.test.ts"
  assert_frontend_capture

  invoke_hook_in "$FIXTURE" "$commit_payload" "$REPO_ROOT/.claude/hooks/red-verify-commit-check.sh"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

@test "package scope: a root app/ path is not a frontend package path, so nothing is keyed under frontend/" {
  make_package_fixture
  run_capture_in_fixture "$FIXTURE" "pnpm test --run app/utils/x.test.ts"
  [ "$status" -eq 0 ]
  grep -qxF -- "cwd=$FIXTURE/frontend" "$STUB_VITEST_LOG" && return 1
  if [ -f "$FIXTURE_LEDGER" ]; then
    grep -qF -- '"file":"frontend/' "$FIXTURE_LEDGER" && return 1
  fi
  true
}

@test "package scope: a literal path-dot registry keeps today's layout, the root app/ test is keyed app/..." {
  make_package_fixture
  write_packages_today "$FIXTURE"
  run_capture_in_fixture "$FIXTURE" "pnpm test --run app/utils/x.test.ts"
  [ "$status" -eq 0 ]
  [ "$(fixture_ledger_lines)" -eq 1 ]
  [ "$(jq -r '.file' "$FIXTURE_LEDGER")" = "app/utils/x.test.ts" ]
  grep -qxF -- "cwd=$FIXTURE" "$STUB_VITEST_LOG"
  grep -qxF -- "scope=app/utils/x.test.ts" "$STUB_VITEST_LOG"
}

@test "package scope: an unparseable registry records nothing and blocks with the gaia-packages reason" {
  make_package_fixture
  write_package_registry "$FIXTURE" '{'
  run_capture_in_fixture "$FIXTURE" "pnpm test --run frontend/app/utils/x.test.ts"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<<"$output")" = block ]
  jq -r '.reason' <<<"$output" | grep -qF -- 'gaia-packages: .gaia/packages.json is malformed'
  [ "$(fixture_ledger_lines)" -eq 0 ]
  [ ! -e "$STUB_VITEST_LOG" ]
}

@test "package scope: a registered package with no descriptor records nothing and blocks with the gaia-packages reason" {
  make_package_fixture
  write_package_registry "$FIXTURE" '[{"name":"frontend","path":"frontend"}]'
  run_capture_in_fixture "$FIXTURE" "pnpm test --run frontend/app/utils/x.test.ts"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<<"$output")" = block ]
  jq -r '.reason' <<<"$output" | grep -qF -- 'gaia-packages: frontend/gaia.package.json is missing'
  [ "$(fixture_ledger_lines)" -eq 0 ]
}

@test "package scope: a --filter name that is no registered package records nothing and says why" {
  make_package_fixture
  run_capture_in_fixture "$FIXTURE" "pnpm --filter nonesuch test --run app/utils/x.test.ts"
  [ "$status" -eq 0 ]
  jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF -- "'nonesuch' is not a registered package"
  [ "$(fixture_ledger_lines)" -eq 0 ]
}

# --- the failure event: a failing run's Bash call errors ----------------------
#
# A vitest run with a failing test exits non-zero, and Claude Code reports a
# non-zero Bash call through PostToolUseFailure, not PostToolUse. The RED run is
# the one this hook exists to observe, so it has to be registered on that event
# too. The failure payload carries `error` and `is_interrupt` in place of
# `tool_response`, and that event accepts no `decision: "block"`, so the hook
# answers it through additionalContext keyed to the event it received.

# A PostToolUseFailure Bash payload, as Claude Code sends it for a failing run.
# Args: <command> [cwd]
failure_payload() {
  jq -nc --arg command "$1" --arg directory "${2:-}" \
    '{hook_event_name:"PostToolUseFailure", tool_name:"Bash", tool_input:{command:$command},
      tool_use_id:"toolu_test", error:"Command failed with exit code 1", is_interrupt:false}
     + (if $directory == "" then {} else {cwd:$directory} end)'
}

@test "failure event: both settings files register the capture on PostToolUseFailure for Bash" {
  hook_registered "$REPO_ROOT/.claude/settings.json" \
    '.hooks.PostToolUseFailure[] | select(.matcher == "Bash")' capture-red-observations.sh
  hook_registered "$REPO_ROOT/frontend/.claude/settings.json" \
    '.hooks.PostToolUseFailure[] | select(.matcher == "Bash")' capture-red-observations.sh
}

@test "failure event: both settings files still register the capture on PostToolUse for Bash" {
  hook_registered "$REPO_ROOT/.claude/settings.json" \
    '.hooks.PostToolUse[] | select(.matcher == "Bash")' capture-red-observations.sh
  hook_registered "$REPO_ROOT/frontend/.claude/settings.json" \
    '.hooks.PostToolUse[] | select(.matcher == "Bash")' capture-red-observations.sh
}

@test "failure event: a failing run's payload records the RED" {
  RED_CAPTURE_JSON_OVERRIDE="$REPO_ROOT/$JSON_FIXTURE_RELATIVE_DIRECTORY/assertion-fail.json" \
    invoke_hook_in "$REPO_ROOT" \
    "$(failure_payload "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts")" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  [ "$(jq -r '.fullName' "$LEDGER_ABSOLUTE_PATH")" = "fails on assertion" ]
}

@test "failure event: a failing package run re-runs in the package and records the repo-relative key" {
  make_package_fixture
  invoke_hook_in "$FIXTURE" "$(failure_payload "pnpm -C frontend test --run app/utils/x.test.ts" "$FIXTURE")" "$HOOK"
  assert_frontend_capture
}

@test "failure event: the unscoped-run skip is announced under the event it received" {
  invoke_hook_in "$REPO_ROOT" "$(failure_payload "pnpm test --run")" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUseFailure"' <<<"$output"
  jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF -- 'pnpm test --run <test-file>'
}

@test "failure event: an unusable registry says why as context, not as an unsupported block" {
  make_package_fixture
  write_package_registry "$FIXTURE" '{'
  invoke_hook_in "$FIXTURE" "$(failure_payload "pnpm test --run frontend/app/utils/x.test.ts" "$FIXTURE")" "$HOOK"
  [ "$status" -eq 0 ]
  jq -e 'has("decision") | not' <<<"$output"
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUseFailure"' <<<"$output"
  jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF -- 'gaia-packages: .gaia/packages.json is malformed'
  [ "$(fixture_ledger_lines)" -eq 0 ]
}

# --- a re-run that cannot start a browser says so ----------------------------

# A fake `pnpm` that prints STUB_PNPM_OUTPUT_SOURCE and, when set, copies
# STUB_PNPM_JSON_SOURCE to the --outputFile path before exiting 1. The fixtures
# are captured from Vitest browser mode run with PLAYWRIGHT_BROWSERS_PATH
# pointed at a directory with no Chromium in it: that run still writes a
# parseable report, with zero tests, next to the browser-launch error text.
stub_failing_pnpm() {
  STUB_BIN=$(mktemp -d)
  cat > "$STUB_BIN/pnpm" <<'SH'
#!/bin/sh
output_file=""
for argument in "$@"; do
  case "$argument" in
    --outputFile=*) output_file="${argument#--outputFile=}" ;;
  esac
done
if [ -n "$output_file" ] && [ -n "${STUB_PNPM_JSON_SOURCE:-}" ]; then
  cp "$STUB_PNPM_JSON_SOURCE" "$output_file"
fi
[ -z "${STUB_PNPM_OUTPUT_SOURCE:-}" ] || cat "$STUB_PNPM_OUTPUT_SOURCE"
exit 1
SH
  chmod +x "$STUB_BIN/pnpm"
  PATH="$STUB_BIN:$PATH"
  export PATH
}

@test "a re-run that cannot launch Chromium emits context naming pnpm install:browsers" {
  stub_failing_pnpm
  STUB_PNPM_OUTPUT_SOURCE="$BATS_TEST_DIRNAME/fixtures/no-chromium-vitest-output.txt"
  STUB_PNPM_JSON_SOURCE="$BATS_TEST_DIRNAME/fixtures/no-chromium-vitest-report.json"
  export STUB_PNPM_OUTPUT_SOURCE STUB_PNPM_JSON_SOURCE
  run_capture "Bash" "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$output"
  context=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$output")
  grep -qF -- 'pnpm install:browsers' <<<"$context"
  grep -qF -- 'no failing (RED) result was recorded' <<<"$context"
}

@test "a re-run with no report and the launch error also names pnpm install:browsers" {
  stub_failing_pnpm
  STUB_PNPM_OUTPUT_SOURCE="$BATS_TEST_DIRNAME/fixtures/no-chromium-vitest-output.txt"
  export STUB_PNPM_OUTPUT_SOURCE
  run_capture "Bash" "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts"
  [ "$status" -eq 0 ]
  jq -r '.hookSpecificOutput.additionalContext' <<<"$output" | grep -qF -- 'pnpm install:browsers'
}

@test "a re-run that yields no report for another reason stays silent" {
  stub_failing_pnpm
  run_capture "Bash" "pnpm test --run $FIXTURE_RELATIVE_DIRECTORY/mixed-pass-fail.test.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "hook-payload.sh missing: exit 0 with empty stdout, writes nothing" {
  local scratch="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch/.claude/hooks"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$scratch/.claude/hooks/lib"
  cp "$HOOK" "$scratch/.claude/hooks/capture-red-observations.sh"
  rm -f "$scratch/.claude/hooks/lib/hook-payload.sh"

  local payload
  payload=$(jq -n '{tool_name: "Bash", tool_input: {command: "pnpm test --run"}, tool_response: {stdout: "", stderr: "", interrupted: false}}')
  invoke_hook_in "$REPO_ROOT" "$payload" "$scratch/.claude/hooks/capture-red-observations.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "a payload with no hook_event_name reports PostToolUse; PostToolUseFailure is kept" {
  run_capture "Bash" "pnpm test --run"
  [ "$status" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$output"

  local failure_payload
  failure_payload=$(jq -n '{hook_event_name: "PostToolUseFailure", tool_name: "Bash", tool_input: {command: "pnpm test --run"}}')
  invoke_hook_in "$REPO_ROOT" "$failure_payload" "$HOOK"
  [ "$status" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PostToolUseFailure"' <<<"$output"
}
