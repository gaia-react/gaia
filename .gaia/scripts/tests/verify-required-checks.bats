#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0 (the negative `run !` assertions below).
bats_require_minimum_version 1.5.0
#
# Tests for `.gaia/scripts/verify-required-checks.sh` (#807).
#
# The script never talks to `gh` in these tests: `--ruleset-contexts` injects
# the live-required set and `--workflows-dir` points at a fixture directory,
# so the suite is fully offline and deterministic.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): macOS's system
# `/bin/bash` (3.2) does not fail a bats @test on a false bare `[[ ... ]]`
# that isn't the test's last command, so non-final substring/prefix checks
# below use `grep -qF` via the `assert_contains` helper, not `[[ ]]`.

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../verify-required-checks.sh"
  [ -x "$SCRIPT" ] || skip "verify-required-checks.sh not executable"
  FIX="$THIS_DIR/fixtures/verify-required-checks"
  FULL_RULESET="GAIA-Audit
bats (.github/audit)
Run Chromatic
Unanswered newly-shipping files
Vitest and Playwright"
}

# ---------------------------------------------------------------------------
# Usage errors (exit 2)
# ---------------------------------------------------------------------------

@test "usage error: unknown flag exits 2" {
  run "$SCRIPT" --not-a-real-flag foo
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Clean pass: every declared-required context is in the live ruleset
# ---------------------------------------------------------------------------

@test "clean pass: exits 0 when every required context is present" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$FULL_RULESET") \
    --workflows-dir "$FIX/workflows-clean"
  [ "$status" -eq 0 ]
  assert_contains "all declared-required contexts confirmed"
}

@test "clean pass: does not print a MISSING section" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$FULL_RULESET") \
    --workflows-dir "$FIX/workflows-clean"
  local prior_output="$output"
  run ! grep -qF "MISSING" <<<"$prior_output"
}

@test "clean pass: advisory section lists a non-required job by name" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$FULL_RULESET") \
    --workflows-dir "$FIX/workflows-clean"
  assert_contains "shellcheck (tracked *.sh)"
}

@test "clean pass: advisory section omits a required job" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$FULL_RULESET") \
    --workflows-dir "$FIX/workflows-clean"
  # "Vitest and Playwright" is declared-required, so it must not appear as
  # an advisory bullet even though it's a real job in the fixture.
  local prior_output="$output"
  run ! grep -qF -- "- Vitest and Playwright" <<<"$prior_output"
}

@test "--ruleset-contexts - reads the live-required set from stdin" {
  run bash -c "printf '%s\n' \"$FULL_RULESET\" | \"$SCRIPT\" --repo gaia-react/gaia --branch main --ruleset-contexts - --workflows-dir \"$FIX/workflows-clean\""
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Drift: a declared-required context is missing from the live ruleset
# ---------------------------------------------------------------------------

@test "drift: exits 1 when a required context is missing live" {
  local partial="bats (.github/audit)
Run Chromatic
Unanswered newly-shipping files
Vitest and Playwright"
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$partial") \
    --workflows-dir "$FIX/workflows-clean"
  [ "$status" -eq 1 ]
}

@test "drift: reports exactly the missing context by name" {
  local partial="bats (.github/audit)
Run Chromatic
Unanswered newly-shipping files
Vitest and Playwright"
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$partial") \
    --workflows-dir "$FIX/workflows-clean"
  assert_contains "MISSING"
  assert_contains "GAIA-Audit"
}

@test "drift: an empty live ruleset reports every declared-required context missing" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '') \
    --workflows-dir "$FIX/workflows-clean"
  [ "$status" -eq 1 ]
  assert_contains "GAIA-Audit"
  assert_contains "bats (.github/audit)"
  assert_contains "Run Chromatic"
  assert_contains "Unanswered newly-shipping files"
  assert_contains "Vitest and Playwright"
}

# ---------------------------------------------------------------------------
# Workflows dir edge cases
# ---------------------------------------------------------------------------

@test "no advisory section when the workflows dir has no job files" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$FULL_RULESET") \
    --workflows-dir "$FIX/workflows-empty"
  [ "$status" -eq 0 ]
  local prior_output="$output"
  run ! grep -qF "Advisory" <<<"$prior_output"
}

@test "a missing workflows dir does not error, only skips the advisory scan" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$FULL_RULESET") \
    --workflows-dir "$FIX/does-not-exist"
  [ "$status" -eq 0 ]
}
