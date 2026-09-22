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

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # The Node helpers this suite drives resolve `typescript` from node_modules.
  # The gate fails rather than skips on a CI runner, where the dependency is a
  # precondition the job installs; see the helper for why.
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$REPO_ROOT"
  HOOK="$REPO_ROOT/.claude/hooks/capture-red-observations.sh"
  FIX_REL=".gaia/tests/hooks/fixtures/red-ledger"
  JSON_REL="$FIX_REL/json"
  # Ask the shipped lib where the ledger belongs (tree-keyed) rather than
  # hardcoding a second copy of the keyed literal.
  LEDGER_ABS="$( . "$REPO_ROOT/.claude/hooks/lib/red-ledger.sh" && red_ledger_path "$REPO_ROOT" )"

  # Stash any pre-existing local ledger; restore in teardown.
  STASH=""
  if [ -f "$LEDGER_ABS" ]; then
    STASH=$(mktemp -t red-ledger-stash-XXXXXX)
    cp "$LEDGER_ABS" "$STASH"
  fi
  rm -f "$LEDGER_ABS"
}

teardown() {
  rm -f "$LEDGER_ABS"
  if [ -n "${STASH:-}" ] && [ -f "$STASH" ]; then
    mkdir -p "$(dirname "$LEDGER_ABS")"
    cp "$STASH" "$LEDGER_ABS"
    rm -f "$STASH"
  fi
  [ -n "${STUB_BIN:-}" ] && rm -rf "$STUB_BIN"
  [ -n "${STUB_PNPM_ARGS_FILE:-}" ] && rm -f "$STUB_PNPM_ARGS_FILE"
  return 0
}

# Build a PostToolUse Bash payload and pipe it to the hook from the repo root.
# Args: <tool_name> <command> [json_override_relpath]
run_capture() {
  local tool="$1" cmd="$2" override_rel="${3:-}"
  local payload
  payload=$(jq -n --arg t "$tool" --arg c "$cmd" \
    '{tool_name: $t, tool_input: {command: $c}, tool_response: {stdout: "", stderr: "", interrupted: false}}')

  # The override is set on the invocation as a whole, so it is in the
  # environment the hook inherits rather than on one side of the pipe.
  if [ -n "$override_rel" ]; then
    RED_CAPTURE_JSON_OVERRIDE="$REPO_ROOT/$override_rel" \
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
  local sub="$1" tool="$2" cmd="$3" override_rel="${4:-}"
  local payload
  payload=$(jq -n --arg t "$tool" --arg c "$cmd" \
    '{tool_name: $t, tool_input: {command: $c}, tool_response: {stdout: "", stderr: "", interrupted: false}}')
  mkdir -p "$REPO_ROOT/$sub"
  if [ -n "$override_rel" ]; then
    RED_CAPTURE_JSON_OVERRIDE="$REPO_ROOT/$override_rel" \
      invoke_hook_in "$REPO_ROOT/$sub" "$payload" "$HOOK"
  else
    invoke_hook_in "$REPO_ROOT/$sub" "$payload" "$HOOK"
  fi
}

# Count ledger lines (0 when the file is absent).
ledger_lines() {
  [ -f "$LEDGER_ABS" ] && wc -l < "$LEDGER_ABS" | tr -d ' ' || echo 0
}

# A fake `pnpm` ahead of the real one on PATH. It records every argv word it
# receives to STUB_PNPM_ARGS_FILE (one per line) and, when STUB_PNPM_JSON_SRC
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
out_file=""
for a in "$@"; do
  printf '%s\n' "$a" >> "$STUB_PNPM_ARGS_FILE"
  case "$a" in
    --outputFile=*) out_file="${a#--outputFile=}" ;;
  esac
done
if [ -n "$out_file" ] && [ -n "${STUB_PNPM_JSON_SRC:-}" ]; then
  cp "$STUB_PNPM_JSON_SRC" "$out_file"
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
  STUB_PNPM_JSON_SRC="$REPO_ROOT/$JSON_REL/assertion-fail.json"
  export STUB_PNPM_JSON_SRC
  run_capture "Bash" "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts $redir"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  grep -qF -- "$FIX_REL/mixed-pass-fail.test.ts" "$STUB_PNPM_ARGS_FILE"
  grep -E '[<>]' "$STUB_PNPM_ARGS_FILE" && return 1
  return 0
}

# --- failing run records one RED per genuinely-failing test -------------------

@test "assertion-fail run appends exactly one RED for the failing test" {
  run_capture "Bash" \
    "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts" \
    "$JSON_REL/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]

  line=$(cat "$LEDGER_ABS")
  [ "$(printf '%s' "$line" | jq -r '.schema')" = "1" ]
  [ "$(printf '%s' "$line" | jq -r '.file')" = "$FIX_REL/mixed-pass-fail.test.ts" ]
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
    "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts" \
    "$JSON_REL/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  line=$(cat "$LEDGER_ABS")
  [ "$(printf '%s' "$line" | jq -r '.fullName')" = "fails on assertion" ]
  grep -qE '^sha256:' <<<"$(printf '%s' "$line" | jq -r '.signal')"
}

@test "recorded signal matches the helper's signal for that test" {
  run_capture "Bash" \
    "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts" \
    "$JSON_REL/assertion-fail.json"
  [ "$status" -eq 0 ]

  recorded=$(printf '%s' "$(cat "$LEDGER_ABS")" | jq -r '.signal')
  expected=$(cd "$REPO_ROOT" && node .gaia/scripts/red-ledger/extract-test-signals.mjs \
    "$FIX_REL/mixed-pass-fail.test.ts" \
    | jq -r 'select(.fullName == "fails on assertion") | .signal')
  [ -n "$expected" ]
  [ "$recorded" = "$expected" ]
}

@test "the passing test in the same file is NOT recorded" {
  run_capture "Bash" \
    "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts" \
    "$JSON_REL/assertion-fail.json"
  [ "$status" -eq 0 ]
  # Only one line, and it is the failing one; the passing test never appears.
  [ "$(ledger_lines)" -eq 1 ]
  run grep -c '"fullName":"passes fine"' "$LEDGER_ABS"
  [ "$output" = "0" ]
}

# --- failureKind classification -----------------------------------------------

@test "failureKind is runtime for a missing-implementation error" {
  run_capture "Bash" \
    "pnpm test --run $FIX_REL/runtime-fail.test.ts" \
    "$JSON_REL/runtime-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  [ "$(cat "$LEDGER_ABS" | jq -r '.failureKind')" = "runtime" ]
  [ "$(cat "$LEDGER_ABS" | jq -r '.fullName')" = "calls a not-yet-implemented function" ]
}

# --- no RED for passing-only and collection-error runs ------------------------

@test "passing-only run writes no ledger lines" {
  run_capture "Bash" \
    "pnpm test --run $FIX_REL/two-tests.test.ts" \
    "$JSON_REL/passing-only.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "collection-error run writes no ledger lines (coarse false-RED guard)" {
  run_capture "Bash" \
    "pnpm test --run $FIX_REL/broken.test.ts" \
    "$JSON_REL/collection-error.json"
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

@test "an unparseable/empty scope skips the capture (no full-suite re-run, writes nothing)" {
  # No override and no scope arg after `test`: the hook must SKIP the capture
  # rather than re-run the whole vitest suite. It bails before vitest is ever
  # invoked, so it stays fast and offline and records nothing. A missing capture
  # only means the commit check may later deny (the safe direction).
  run_capture "Bash" "pnpm test --run"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  # No temp vitest json was produced (the skip happens before the mktemp).
  local ledger_dir
  ledger_dir=$(dirname "$LEDGER_ABS")
  run bash -c "ls '$ledger_dir/.tmp'/vitest-*.json 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
}

@test "a scoped invocation still parses its scope (the skip is no-scope only)" {
  # A parseable scope is unaffected by the skip: with the override seam supplying
  # canned json, the scoped path records exactly as before. This guards that the
  # skip changed ONLY the no-scope fallback, not the scoped behavior.
  run_capture "Bash" \
    "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts" \
    "$JSON_REL/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
}

@test "a --body string mentioning 'pnpm test --run' exits 0 and writes nothing" {
  # Command-position anchoring: the phrase appears inside a PR-body argument,
  # not as a `pnpm`/`npm` command word, so no spurious full-suite vitest re-run
  # fires and nothing is recorded. (Regression guard for the bare-test false
  # positive that this hook shared the token grammar with.)
  run_capture "Bash" 'gh pr create --body "see `pnpm test --run` output"'
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "a non-Bash tool call exits 0 and writes nothing" {
  run_capture "Edit" "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts" \
    "$JSON_REL/assertion-fail.json"
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
    "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts" \
    "$JSON_REL/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]

  run_capture "Bash" \
    "pnpm test --run $FIX_REL/runtime-fail.test.ts" \
    "$JSON_REL/runtime-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 2 ]
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
# tokens (gaia-react/gaia#2225 residual). awk word-splits $test_seg, so a
# spaced redirection's operator and target never travel together the way the
# attached forms above (1>out.log, <<EOF, …) do. Asserting only "no `<`/`>`
# in the args" (as assert_scope_survives_redirect does) cannot see the
# target leaking as a bogus extra scope token, so these assert the target's
# exact line is absent from the stub's recorded argv.

@test "a narrow scope survives a trailing spaced stdout-redirect (> out.log)" {
  stub_pnpm
  STUB_PNPM_JSON_SRC="$REPO_ROOT/$JSON_REL/assertion-fail.json"
  export STUB_PNPM_JSON_SRC
  run_capture "Bash" "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts > out.log"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  grep -qF -- "$FIX_REL/mixed-pass-fail.test.ts" "$STUB_PNPM_ARGS_FILE"
  grep -qxF "out.log" "$STUB_PNPM_ARGS_FILE" && return 1
  return 0
}

@test "a narrow scope survives a trailing spaced stderr-redirect (2> err.log)" {
  stub_pnpm
  STUB_PNPM_JSON_SRC="$REPO_ROOT/$JSON_REL/assertion-fail.json"
  export STUB_PNPM_JSON_SRC
  run_capture "Bash" "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts 2> err.log"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  grep -qF -- "$FIX_REL/mixed-pass-fail.test.ts" "$STUB_PNPM_ARGS_FILE"
  grep -qxF "err.log" "$STUB_PNPM_ARGS_FILE" && return 1
  return 0
}

@test "a narrow scope survives a leading spaced input-redirect (< input)" {
  stub_pnpm
  STUB_PNPM_JSON_SRC="$REPO_ROOT/$JSON_REL/assertion-fail.json"
  export STUB_PNPM_JSON_SRC
  run_capture "Bash" "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts < input"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 1 ]
  grep -qF -- "$FIX_REL/mixed-pass-fail.test.ts" "$STUB_PNPM_ARGS_FILE"
  grep -qxF "input" "$STUB_PNPM_ARGS_FILE" && return 1
  return 0
}

@test "an unscoped run with only a spaced stdout-redirect hits the no-scope skip (> out)" {
  stub_pnpm
  run_capture "Bash" "pnpm test --run > out"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
  [ ! -s "$STUB_PNPM_ARGS_FILE" ]
}
