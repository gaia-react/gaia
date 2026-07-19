#!/usr/bin/env bats

# Tests for the RED-ledger foundation: the Node signal helper
# (.gaia/scripts/red-ledger/extract-test-signals.mjs) and the shared shell lib
# (.claude/hooks/lib/red-ledger.sh) that both RED hooks source.
#
# The signal helper parses a TS/TSX test file and emits one
# {"fullName","signal"} line per test/it call. The shell lib provides the
# ledger path, repo-relative path normalization, and a thin wrapper that runs
# the helper. These tests exercise both against the fixture test files under
# fixtures/red-ledger/.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # This suite runs the Node signal helper, which resolves `typescript` from
  # node_modules; skip where deps aren't installed (e.g. the lean
  # audit-ci-tests CI box) so `bats .gaia/tests/hooks/` stays green there.
  [ -d "$REPO_ROOT/node_modules/typescript" ] || skip "typescript not installed (node-dependent RED suite)"
  HELPER="$REPO_ROOT/.gaia/scripts/red-ledger/extract-test-signals.mjs"
  LIB="$REPO_ROOT/.claude/hooks/lib/red-ledger.sh"
  # shellcheck disable=SC2034  # unused fixture-path var; pre-existing dead code, kept (not deleted) per surgical-changes policy
  FIX="$BATS_TEST_DIRNAME/fixtures/red-ledger"

  # Repo-relative fixture paths (helper + lib expect repo-relative input run
  # from the repo root).
  FIX_REL=".gaia/tests/hooks/fixtures/red-ledger"
}

# Run the Node helper from the repo root with a repo-relative fixture path.
run_helper() {
  run bash -c "cd '$REPO_ROOT' && node '$HELPER' '$1'"
}

# Source the lib in a clean shell and run a function, from the repo root.
run_lib() {
  run bash -c "cd '$REPO_ROOT' && set -uo pipefail && . '$LIB' && $1"
}

# --- signal helper: fullName ---

@test "helper emits the bare title for a top-level test" {
  run_helper "$FIX_REL/top-level.test.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fullName":"adds two numbers"'* ]]
}

@test "helper joins nested describe titles with the test title" {
  run_helper "$FIX_REL/nested-describe.test.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fullName":"outer inner does a thing"'* ]]
}

# --- signal helper: distinct tests, distinct signals ---

@test "two tests in one file yield two lines with distinct signals" {
  run_helper "$FIX_REL/two-tests.test.ts"
  [ "$status" -eq 0 ]
  # Two output lines.
  [ "$(printf '%s\n' "$output" | grep -c '"fullName"')" -eq 2 ]
  local sig1 sig2
  sig1=$(printf '%s\n' "$output" | sed -n '1p' | sed -E 's/.*"signal":"([^"]+)".*/\1/')
  sig2=$(printf '%s\n' "$output" | sed -n '2p' | sed -E 's/.*"signal":"([^"]+)".*/\1/')
  [ -n "$sig1" ]
  [ -n "$sig2" ]
  [ "$sig1" != "$sig2" ]
}

@test "every signal carries the sha256: prefix" {
  run_helper "$FIX_REL/two-tests.test.ts"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"signal":"sha256:'* ]]
}

# --- signal helper: stability under reformatting, change on edit ---

@test "reformatting-only edit yields the same signal" {
  run_helper "$FIX_REL/stable-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_a
  sig_a=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper "$FIX_REL/stable-b.test.ts"
  [ "$status" -eq 0 ]
  local sig_b
  sig_b=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_a" ]
  [ "$sig_a" = "$sig_b" ]
}

@test "changing an assertion literal yields a different signal" {
  run_helper "$FIX_REL/stable-a.test.ts"
  [ "$status" -eq 0 ]
  local sig_a
  sig_a=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  run_helper "$FIX_REL/changed.test.ts"
  [ "$status" -eq 0 ]
  local sig_changed
  sig_changed=$(printf '%s\n' "$output" | sed -E 's/.*"signal":"([^"]+)".*/\1/')

  [ -n "$sig_a" ]
  [ "$sig_a" != "$sig_changed" ]
}

# --- signal helper: kind classification ---

@test "helper tags an expectTypeOf-only test kind=type-only" {
  run_helper "$FIX_REL/kind-type-only.test.ts"
  [ "$status" -eq 0 ]
  local kind
  kind=$(printf '%s\n' "$output" \
    | jq -r 'select(.fullName=="type proof via expectTypeOf") | .kind')
  [ "$kind" = "type-only" ]
}

@test "helper tags a @ts-expect-error-only test kind=type-only" {
  run_helper "$FIX_REL/kind-type-only.test.ts"
  [ "$status" -eq 0 ]
  local kind
  kind=$(printf '%s\n' "$output" \
    | jq -r 'select(.fullName=="type proof via ts-expect-error") | .kind')
  [ "$kind" = "type-only" ]
}

@test "helper tags a plain runtime test kind=runtime" {
  run_helper "$FIX_REL/top-level.test.ts"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r '.kind')" = "runtime" ]
}

@test "helper tags both mixed runtime+type tests kind=runtime" {
  run_helper "$FIX_REL/kind-mixed.test.ts"
  [ "$status" -eq 0 ]
  # Two tests, and every one classifies runtime (a runtime assertion present
  # alongside a type-level proof is still runtime, never type-only).
  [ "$(printf '%s\n' "$output" | grep -c '"fullName"')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | jq -r '.kind' | sort -u)" = "runtime" ]
}

# --- signal helper: exit codes ---

@test "helper exits 0 with no output on a valid file with no tests" {
  run_helper "$FIX_REL/no-tests.test.ts"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "helper exits non-zero with a stderr message on a broken file" {
  run_helper "$FIX_REL/broken.test.ts"
  [ "$status" -ne 0 ]
  [[ "$output" == *"extract-test-signals"* ]]
}

@test "helper exits non-zero when the argument is missing" {
  run bash -c "cd '$REPO_ROOT' && node '$HELPER'"
  [ "$status" -ne 0 ]
}

@test "helper resolves typescript from node_modules" {
  run bash -c "cd '$REPO_ROOT' && node -e 'require(\"typescript\")'"
  [ "$status" -eq 0 ]
}

# --- shell lib: red_ledger_path ---

@test "red_ledger_path echoes the gitignored ledger location" {
  run_lib 'red_ledger_path'
  [ "$status" -eq 0 ]
  [ "$output" = ".gaia/local/red-ledger/observations.jsonl" ]
}

# --- shell lib: red_ledger_repo_rel ---

@test "red_ledger_repo_rel strips the repo-root prefix from an absolute path" {
  run_lib "red_ledger_repo_rel '$REPO_ROOT/$FIX_REL/top-level.test.ts'"
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX_REL/top-level.test.ts" ]
}

@test "red_ledger_repo_rel strips a leading ./" {
  run_lib "red_ledger_repo_rel './$FIX_REL/top-level.test.ts'"
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX_REL/top-level.test.ts" ]
}

@test "red_ledger_repo_rel is idempotent on an already-relative path" {
  run_lib "red_ledger_repo_rel '$FIX_REL/top-level.test.ts'"
  [ "$status" -eq 0 ]
  [ "$output" = "$FIX_REL/top-level.test.ts" ]
}

# --- shell lib: red_ledger_signals ---

@test "red_ledger_signals returns the helper NDJSON for a valid fixture" {
  run_lib "red_ledger_signals '$FIX_REL/top-level.test.ts'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"fullName":"adds two numbers"'* ]]
  [[ "$output" == *'"signal":"sha256:'* ]]
}

@test "red_ledger_signals propagates the helper non-zero exit on a broken file" {
  run_lib "red_ledger_signals '$FIX_REL/broken.test.ts'"
  [ "$status" -ne 0 ]
}

# --- double-sourcing is safe ---

@test "sourcing the lib twice is a no-op" {
  run bash -c "cd '$REPO_ROOT' && set -uo pipefail && . '$LIB' && . '$LIB' && red_ledger_path"
  [ "$status" -eq 0 ]
  [ "$output" = ".gaia/local/red-ledger/observations.jsonl" ]
}
