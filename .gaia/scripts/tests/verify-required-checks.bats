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
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../verify-required-checks.sh"
  WORKFLOWS_DIRECTORY="$THIS_DIRECTORY/../../../.github/workflows"
  # Built at runtime so this file never names the deleted workflow literally.
  DELETED_WORKFLOW="code-review-audit"".yml"
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
  missing_bullets=$(awk '/^MISSING/{inside_missing_section=1;next} inside_missing_section && /^  - /{bullet_count++} END{print bullet_count+0}' <<<"$output")
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

# The declared contexts must each be posted by something that still exists

# declared_contexts: the contexts the script declares, one per line, read off
# its own drift report against an empty live ruleset.
declared_contexts() {
  "$SCRIPT" --repo gaia-react/gaia --branch main --ruleset-contexts <(printf '') \
    | sed -n 's/^  - //p'
}

# unmapped_contexts <workflows-dir>: the declared contexts other than
# GAIA-Audit (a status posted locally, so no job carries it) that no job
# `name:` under <workflows-dir> equals. Prints one per line; empty means every
# one maps.
unmapped_contexts() {
  local workflows_directory="$1" job_names context
  job_names="$(awk '/^    name:/ { sub(/^    name:[ ]*/, ""); gsub(/^["'"'"']|["'"'"']$/, ""); print }' \
    "$workflows_directory"/*.yml)"
  while IFS= read -r context; do
    [ "$context" = "GAIA-Audit" ] && continue
    grep -qxF -- "$context" <<<"$job_names" || printf '%s\n' "$context"
  done < <(declared_contexts)
}

@test "the maintainer Claude review workflow is gone" {
  [ ! -e "$WORKFLOWS_DIRECTORY/${DELETED_WORKFLOW}" ]
}

@test "the declared contexts are exactly the five the maintainer ruleset requires" {
  local actual expected
  actual="$(declared_contexts | LC_ALL=C sort)"
  expected="$(printf '%s\n' "GAIA-Audit" "Audit CI Tests" "Run Chromatic" "Vitest and Playwright" "Vitest (.gaia/cli)" | LC_ALL=C sort)"
  [ -n "$actual" ]
  [ "$actual" = "$expected" ]
}

@test "every declared context except GAIA-Audit equals a job name in a real workflow" {
  local unmapped
  unmapped="$(unmapped_contexts "$WORKFLOWS_DIRECTORY")"
  [ -z "$unmapped" ] || { printf 'declared context with no job: %s\n' "$unmapped" >&2; return 1; }
}

@test "the context-to-job check fails when a job name is removed" {
  local fixture="$BATS_TEST_TMPDIR/workflows" name
  mkdir -p "$fixture"
  for name in audit-ci-tests chromatic cli-tests tests; do
    cp "$WORKFLOWS_DIRECTORY/${name}.yml" "$fixture/"
  done
  # Control: the untouched copy maps every context, so the failure below is
  # caused by the removal and not by a fixture that never mapped.
  [ -z "$(unmapped_contexts "$fixture")" ]
  sed -i.bak '/^    name: Run Chromatic$/d' "$fixture/chromatic.yml"
  local unmapped
  unmapped="$(unmapped_contexts "$fixture")"
  [ "$unmapped" = "Run Chromatic" ]
}

@test "audit-ci-tests.yml triggers on pull_request, covers every shard, and names no deleted workflow" {
  local workflow="$WORKFLOWS_DIRECTORY/audit-ci-tests.yml" shard shard_count=0
  grep -qE '^  pull_request:' "$workflow"
  while IFS= read -r shard; do
    [ -n "$shard" ] || continue
    shard_count=$((shard_count + 1))
    grep -E '^ +shard: \[' "$workflow" | grep -qE "[[,] ?${shard}[],]" \
      || { printf 'matrix is missing shard %s\n' "$shard" >&2; return 1; }
  done < <(bash "$THIS_DIRECTORY/../../tests/bats-shards.sh" shards)
  [ "$shard_count" -gt 0 ]
  ! grep -qF -- "$DELETED_WORKFLOW" "$workflow"
}
