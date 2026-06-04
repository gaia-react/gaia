#!/usr/bin/env bats
# Tests for `.github/forensics/run-quality-gate.sh`.
#
# Strategy: shim `pnpm` with a wrapper whose per-subcommand exit code is
# driven by env vars (PNPM_INSTALL_EXIT, PNPM_TYPECHECK_EXIT, etc). The
# shim also prints configurable stdout/stderr so the log-excerpt path
# can be exercised. Each test verifies the JSON summary, the exit code,
# and the halt-on-first-failure invariant.
#
# Coverage targets:
#   - Halts on the FIRST failing step (no later step runs).
#   - JSON summary names the failed step + non-zero exit_code + excerpt.
#   - Excerpt is ≤2000 chars and ≤50 lines.
#   - All-green path emits the steps_run array and exits 0.
#   - Knip is in scope (failure → demote, identical to lint/test).

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  RUNNER="$THIS_DIR/../run-quality-gate.sh"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/bin"
  PNPM_LOG="$SANDBOX/pnpm.log"
  export PNPM_LOG

  # pnpm shim. Subcommand-aware: dispatches on $1 (install / typecheck /
  # lint / test / knip). Exit code controlled per-step via env vars
  # (default 0). Stdout content controlled via PNPM_<STEP>_STDOUT
  # (default empty). Records every invocation to $PNPM_LOG.
  cat > "$SANDBOX/bin/pnpm" <<'SHIM'
#!/usr/bin/env bash
{
  printf 'pnpm'
  for a in "$@"; do
    printf ' %q' "$a"
  done
  printf '\n'
} >> "$PNPM_LOG"

step="$1"
case "$step" in
  install)   exit_var="PNPM_INSTALL_EXIT";   stdout_var="PNPM_INSTALL_STDOUT" ;;
  typecheck) exit_var="PNPM_TYPECHECK_EXIT"; stdout_var="PNPM_TYPECHECK_STDOUT" ;;
  lint)      exit_var="PNPM_LINT_EXIT";      stdout_var="PNPM_LINT_STDOUT" ;;
  test)      exit_var="PNPM_TEST_EXIT";      stdout_var="PNPM_TEST_STDOUT" ;;
  knip)      exit_var="PNPM_KNIP_EXIT";      stdout_var="PNPM_KNIP_STDOUT" ;;
  *)         echo "shim: unknown subcommand: $step" >&2; exit 99 ;;
esac

exit_code="${!exit_var:-0}"
stdout_content="${!stdout_var:-}"
[ -n "$stdout_content" ] && printf '%s\n' "$stdout_content"
exit "$exit_code"
SHIM
  chmod +x "$SANDBOX/bin/pnpm"

  PATH="$SANDBOX/bin:$PATH"
  export PATH

  SUMMARY="$SANDBOX/summary.json"
  export SUMMARY
}

# Helper: count pnpm-shim invocations by subcommand (matches the line
# `pnpm <subcommand> ...`).
pnpm_log_count() {
  if [ ! -f "$PNPM_LOG" ]; then
    printf '0'
    return
  fi
  grep -cE "^pnpm ${1}( |$)" "$PNPM_LOG" || true
}

# ---------------------------------------------------------------------------
# Usage / argument validation
# ---------------------------------------------------------------------------

@test "usage error with no args" {
  run "$RUNNER"
  [ "$status" -eq 2 ]
}

@test "usage error with too many args" {
  run "$RUNNER" a b
  [ "$status" -eq 2 ]
}

@test "errors when summary file's parent dir does not exist" {
  run "$RUNNER" "$BATS_TEST_TMPDIR/no-such-dir/out.json"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# All-green path
# ---------------------------------------------------------------------------

@test "all-green: exits 0 and writes passed-true summary" {
  run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 0 ]
  [ -f "$SUMMARY" ]
  grep -qF '"passed": true' "$SUMMARY"
}

@test "all-green: summary names every step in steps_run" {
  run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 0 ]
  grep -qF '"install"' "$SUMMARY"
  grep -qF '"typecheck"' "$SUMMARY"
  grep -qF '"lint"' "$SUMMARY"
  grep -qF '"test"' "$SUMMARY"
  grep -qF '"knip"' "$SUMMARY"
}

@test "all-green: each pnpm step is invoked exactly once, in order" {
  run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 0 ]
  [ "$(pnpm_log_count install)" = "1" ]
  [ "$(pnpm_log_count typecheck)" = "1" ]
  [ "$(pnpm_log_count lint)" = "1" ]
  [ "$(pnpm_log_count test)" = "1" ]
  [ "$(pnpm_log_count knip)" = "1" ]
  # Order: install before typecheck before lint before test before knip.
  install_line=$(grep -nE '^pnpm install( |$)' "$PNPM_LOG" | head -1 | cut -d: -f1)
  typecheck_line=$(grep -nE '^pnpm typecheck( |$)' "$PNPM_LOG" | head -1 | cut -d: -f1)
  lint_line=$(grep -nE '^pnpm lint( |$)' "$PNPM_LOG" | head -1 | cut -d: -f1)
  test_line=$(grep -nE '^pnpm test( |$)' "$PNPM_LOG" | head -1 | cut -d: -f1)
  knip_line=$(grep -nE '^pnpm knip( |$)' "$PNPM_LOG" | head -1 | cut -d: -f1)
  [ "$install_line" -lt "$typecheck_line" ]
  [ "$typecheck_line" -lt "$lint_line" ]
  [ "$lint_line" -lt "$test_line" ]
  [ "$test_line" -lt "$knip_line" ]
}

@test "all-green: install uses --frozen-lockfile" {
  run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 0 ]
  grep -qE '^pnpm install --frozen-lockfile' "$PNPM_LOG"
}

@test "all-green: test step uses --run (vitest non-watch)" {
  run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 0 ]
  grep -qE '^pnpm test --run' "$PNPM_LOG"
}

# ---------------------------------------------------------------------------
# Halt-on-first-fail per step
# ---------------------------------------------------------------------------

@test "fail at install: halts immediately, no later steps run" {
  PNPM_INSTALL_EXIT=1 run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  [ "$(pnpm_log_count install)" = "1" ]
  [ "$(pnpm_log_count typecheck)" = "0" ]
  [ "$(pnpm_log_count lint)" = "0" ]
  [ "$(pnpm_log_count test)" = "0" ]
  [ "$(pnpm_log_count knip)" = "0" ]
  grep -qF '"passed": false' "$SUMMARY"
  grep -qF '"failed_step": "install"' "$SUMMARY"
}

@test "fail at typecheck: install ran, typecheck ran, nothing after" {
  PNPM_TYPECHECK_EXIT=2 run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  [ "$(pnpm_log_count install)" = "1" ]
  [ "$(pnpm_log_count typecheck)" = "1" ]
  [ "$(pnpm_log_count lint)" = "0" ]
  [ "$(pnpm_log_count test)" = "0" ]
  [ "$(pnpm_log_count knip)" = "0" ]
  grep -qF '"failed_step": "typecheck"' "$SUMMARY"
  grep -qF '"exit_code": 2' "$SUMMARY"
}

@test "fail at lint: nothing after lint runs" {
  PNPM_LINT_EXIT=1 run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  [ "$(pnpm_log_count lint)" = "1" ]
  [ "$(pnpm_log_count test)" = "0" ]
  [ "$(pnpm_log_count knip)" = "0" ]
  grep -qF '"failed_step": "lint"' "$SUMMARY"
}

@test "fail at test: knip never runs" {
  PNPM_TEST_EXIT=1 run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  [ "$(pnpm_log_count test)" = "1" ]
  [ "$(pnpm_log_count knip)" = "0" ]
  grep -qF '"failed_step": "test"' "$SUMMARY"
}

@test "fail at knip: knip failure is treated identically to lint/test" {
  PNPM_KNIP_EXIT=1 run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  [ "$(pnpm_log_count knip)" = "1" ]
  grep -qF '"passed": false' "$SUMMARY"
  grep -qF '"failed_step": "knip"' "$SUMMARY"
  grep -qF '"exit_code": 1' "$SUMMARY"
}

# ---------------------------------------------------------------------------
# Log excerpt fidelity
# ---------------------------------------------------------------------------

@test "failure summary includes a log_excerpt field" {
  PNPM_LINT_STDOUT="error TS2304: cannot find name foo" PNPM_LINT_EXIT=1 \
    run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  grep -qF '"log_excerpt":' "$SUMMARY"
  grep -qF 'cannot find name foo' "$SUMMARY"
}

@test "log excerpt is bounded to <= 2000 chars" {
  # Generate a 4000-char single-line payload; the runner should clip it.
  big=""
  i=0
  while [ "$i" -lt 4000 ]; do
    big="${big}x"
    i=$((i + 1))
  done
  PNPM_TEST_STDOUT="$big" PNPM_TEST_EXIT=1 run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  # Pull just the log_excerpt string value via awk; verify length.
  excerpt_len=$(awk 'BEGIN { RS = ""; FS = "\"log_excerpt\": \"" } NR==1 { sub(/".*/, "", $2); print length($2) }' "$SUMMARY")
  [ "$excerpt_len" -le 2000 ]
}

@test "log excerpt is bounded to <= 50 lines" {
  # 200 short lines; runner trims to last 50.
  many=""
  i=0
  while [ "$i" -lt 200 ]; do
    many="${many}line-${i}"$'\n'
    i=$((i + 1))
  done
  PNPM_TEST_STDOUT="$many" PNPM_TEST_EXIT=1 run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  # The excerpt is JSON-escaped so each newline shows as \n; count those.
  newline_count=$(awk 'BEGIN { RS = ""; FS = "\"log_excerpt\": \"" } NR==1 { sub(/".*/, "", $2); n = gsub(/\\n/, "&", $2); print n }' "$SUMMARY")
  [ "$newline_count" -le 50 ]
  # And the LAST line (line-199) must be retained, tail-50, not head-50.
  grep -qF 'line-199' "$SUMMARY"
  # An EARLY line dropped by the tail trim must NOT be present.
  ! grep -qF 'line-0\\n' "$SUMMARY"
}

# ---------------------------------------------------------------------------
# JSON shape sanity
# ---------------------------------------------------------------------------

@test "summary is parseable as JSON (jq) on pass" {
  command -v jq >/dev/null || skip "jq not installed"
  run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 0 ]
  run jq -e '.passed == true' "$SUMMARY"
  [ "$status" -eq 0 ]
}

@test "summary is parseable as JSON (jq) on fail" {
  command -v jq >/dev/null || skip "jq not installed"
  PNPM_LINT_STDOUT="boom" PNPM_LINT_EXIT=1 run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  run jq -e '.passed == false and .failed_step == "lint" and .exit_code == 1' "$SUMMARY"
  [ "$status" -eq 0 ]
}

@test "summary JSON-escapes embedded quotes and backslashes" {
  command -v jq >/dev/null || skip "jq not installed"
  PNPM_LINT_STDOUT='msg with "quote" and \backslash' PNPM_LINT_EXIT=1 \
    run "$RUNNER" "$SUMMARY"
  [ "$status" -eq 1 ]
  run jq -er '.log_excerpt' "$SUMMARY"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"quote"'* ]]
  [[ "$output" == *'\backslash'* ]]
}
