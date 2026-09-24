#!/usr/bin/env bats
#
# Requires Bats >= 1.5.0 (the negative `run !` assertions below).
bats_require_minimum_version 1.5.0
#
# Tests for `.gaia/scripts/verify-required-checks.sh`.
#
# The script never talks to `gh` in these tests: `--ruleset-contexts` injects
# the live-required set, so the suite is fully offline and deterministic.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIR/../verify-required-checks.sh"
  [ -x "$SCRIPT" ] || skip "verify-required-checks.sh not executable"
  FULL_RULESET="GAIA-Audit
Audit CI Tests
Run Chromatic
Vitest and Playwright
Vitest (.gaia/cli)"
}

# Usage errors (exit 2)

@test "usage error: unknown flag exits 2" {
  run "$SCRIPT" --not-a-real-flag foo
  [ "$status" -eq 2 ]
}

@test "usage error: a value-taking flag with no value exits 2, does not hang" {
  # No `timeout(1)` on stock macOS, so bound it by hand: background the call,
  # poll briefly for exit, and kill it if it is still alive (a hang, not a
  # usage error).
  "$SCRIPT" --repo >"$BATS_TEST_TMPDIR/out" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 1
  fi
  local exit_status=0
  wait "$pid" || exit_status=$?
  [ "$exit_status" -eq 2 ]
}

# Clean pass: every declared-required context is in the live ruleset

@test "clean pass: exits 0 when every required context is present" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$FULL_RULESET")
  [ "$status" -eq 0 ]
  assert_contains "all declared-required contexts confirmed"
}

@test "clean pass: does not print a MISSING section" {
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$FULL_RULESET")
  local prior_output="$output"
  run ! grep -qF "MISSING" <<<"$prior_output"
}

@test "--ruleset-contexts - reads the live-required set from stdin" {
  run bash -c "printf '%s\n' \"$FULL_RULESET\" | \"$SCRIPT\" --repo gaia-react/gaia --branch main --ruleset-contexts -"
  [ "$status" -eq 0 ]
}

# Drift: a declared-required context is missing from the live ruleset

@test "drift: exits 1 when a required context is missing live" {
  local partial="Audit CI Tests
Run Chromatic
Vitest and Playwright
Vitest (.gaia/cli)"
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$partial")
  [ "$status" -eq 1 ]
}

@test "drift: reports exactly the missing context by name" {
  local partial="Audit CI Tests
Run Chromatic
Vitest and Playwright
Vitest (.gaia/cli)"
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '%s\n' "$partial")
  assert_contains "MISSING"
  assert_contains "GAIA-Audit"
  # "exactly" is only true while `partial` above stays in sync with
  # REQUIRED_CONTEXTS: a context added to the script but not to `partial` would
  # leave both drift tests green while they silently degrade to "at least one
  # missing", retiring the specific-context reporting they exist to guard.
  # Pin the count so that desync fails loudly instead.
  local missing_bullets
  missing_bullets=$(awk '/^MISSING/{f=1;next} f && /^  - /{c++} END{print c+0}' <<<"$output")
  [ "$missing_bullets" -eq 1 ]
}

@test "drift: an empty live ruleset reports every declared-required context missing" {
  # Injected-empty path (--ruleset-contexts <(printf '')): a real, legitimate
  # empty answer. Distinct from the gh-api-failure path below, which must NOT
  # be treated as a legitimate empty answer.
  run "$SCRIPT" --repo gaia-react/gaia --branch main \
    --ruleset-contexts <(printf '')
  [ "$status" -eq 1 ]
  assert_contains "GAIA-Audit"
  assert_contains "Audit CI Tests"
  assert_contains "Run Chromatic"
  assert_contains "Vitest and Playwright"
  assert_contains "Vitest (.gaia/cli)"
}

# gh api failure on the live ruleset read (exit 2, not a drift verdict) (#809)

@test "gh api failure reading the live ruleset exits 2 with a loud diagnostic, not a false drift verdict" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$SCRIPT" --repo gaia-react/gaia --branch main
  [ "$status" -eq 2 ]
  assert_contains "could not read the live ruleset"
}
