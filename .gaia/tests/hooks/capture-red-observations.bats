#!/usr/bin/env bats

# Tests for the RED-capture hook (.claude/hooks/capture-red-observations.sh).
#
# The hook is the OBSERVE-AND-RECORD half of the RED-verification gate. On a
# `(pnpm|npm) test --run [scope]` PostToolUse, it re-invokes vitest with the
# json reporter, reads the per-test results, and appends every genuinely-failing
# test to the ledger (.gaia/local/red-ledger/observations.jsonl). It only
# observes; it never blocks and always exits 0.
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
# The hook hard-codes the ledger at .gaia/local/red-ledger/observations.jsonl
# relative to pwd, so the suite runs from the repo root (like
# red-ledger-lib.bats) and asserts on that gitignored path. setup/teardown
# stash and restore any pre-existing local ledger so a developer's scratch
# ledger is never clobbered.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK="$REPO_ROOT/.claude/hooks/capture-red-observations.sh"
  FIX_REL=".gaia/tests/hooks/fixtures/red-ledger"
  JSON_REL="$FIX_REL/json"
  LEDGER_REL=".gaia/local/red-ledger/observations.jsonl"
  LEDGER_ABS="$REPO_ROOT/$LEDGER_REL"

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
  return 0
}

# Build a PostToolUse Bash payload and pipe it to the hook from the repo root.
# Args: <tool_name> <command> [json_override_relpath]
run_capture() {
  local tool="$1" cmd="$2" override_rel="${3:-}"
  local payload
  payload=$(jq -n --arg t "$tool" --arg c "$cmd" \
    '{tool_name: $t, tool_input: {command: $c}, tool_response: {stdout: "", stderr: "", interrupted: false}}')

  # Export the override so it reaches the hook on the RIGHT side of the pipe
  # (a `VAR=x cmd | hook` prefix would set it on the left command, not the hook).
  local env_prefix=""
  if [ -n "$override_rel" ]; then
    env_prefix="export RED_CAPTURE_JSON_OVERRIDE='$REPO_ROOT/$override_rel'; "
  fi
  run bash -c "cd '$REPO_ROOT' && ${env_prefix}printf '%s' '$payload' | bash '$HOOK'"
}

# Count ledger lines (0 when the file is absent).
ledger_lines() {
  [ -f "$LEDGER_ABS" ] && wc -l < "$LEDGER_ABS" | tr -d ' ' || echo 0
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

@test "a non-Bash tool call exits 0 and writes nothing" {
  run_capture "Edit" "pnpm test --run $FIX_REL/mixed-pass-fail.test.ts" \
    "$JSON_REL/assertion-fail.json"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

# --- robustness: malformed input, empty command -------------------------------

@test "malformed stdin (not json) exits 0 and writes nothing" {
  run bash -c "cd '$REPO_ROOT' && printf 'not json at all' | bash '$HOOK'"
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

@test "empty command exits 0 and writes nothing" {
  run_capture "Bash" ""
  [ "$status" -eq 0 ]
  [ "$(ledger_lines)" -eq 0 ]
}

# --- append-only: a second failing run appends, never truncates ---------------

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
