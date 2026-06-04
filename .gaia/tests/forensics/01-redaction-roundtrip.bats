#!/usr/bin/env bats
# UAT-003: absolute paths converted to repo-relative, token-shaped values replaced with <redacted>
# UAT-010: body post-redaction is byte-identical for local save and GH issue surfaces

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIB="$HERE/lib"
FIXTURES="$HERE/fixtures"

setup() {
  # Source the redact library (defines redact_body)
  # shellcheck source=lib/redact.sh
  source "$LIB/redact.sh"

  # Use a synthetic project root for path-conversion tests
  FAKE_ROOT="/Users/testuser/Development/my-project"
}

# ---------------------------------------------------------------------------
# Path conversion; Rule A (under project root)
# ---------------------------------------------------------------------------

@test "UAT-003: absolute path under project root becomes repo-relative" {
  local input="The failing file is $FAKE_ROOT/.claude/hooks/wiki-session-stop.sh"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" == "The failing file is .claude/hooks/wiki-session-stop.sh" ]]
}

@test "UAT-003: multiple absolute paths under project root all converted" {
  local input="Files: $FAKE_ROOT/app/i18n.ts and $FAKE_ROOT/wiki/.state.json"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" == "Files: app/i18n.ts and wiki/.state.json" ]]
}

# ---------------------------------------------------------------------------
# Path conversion; Rule B (outside project root, machine-leak fallback)
# ---------------------------------------------------------------------------

@test "UAT-003: absolute path outside project root collapses to filename only" {
  local input="Config at /Users/testuser/.config/other-tool.json"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" == "Config at other-tool.json" ]]
}

@test "UAT-003: /home/ path outside project root collapses to filename only" {
  local input="File at /home/runner/.ssh/known_hosts"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" == "File at known_hosts" ]]
}

# ---------------------------------------------------------------------------
# Token patterns; GitHub tokens (pattern 1)
# Synthetic tokens constructed at test runtime; never stored in fixture files.
# ---------------------------------------------------------------------------

@test "UAT-003: gho_ GitHub OAuth token is redacted" {
  # Construct a synthetic token-shaped string at runtime
  local fake_token="gho_$(python3 -c 'print("A"*20)' 2>/dev/null || printf 'AAAAAAAAAAAAAAAAAAAA')"
  local input="Token: $fake_token in the env"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
  [[ "$result" == *"<redacted>"* ]]
}

@test "UAT-003: ghp_ GitHub PAT is redacted" {
  local fake_token="ghp_$(python3 -c 'print("B"*20)' 2>/dev/null || printf 'BBBBBBBBBBBBBBBBBBBB')"
  local input="GITHUB_TOKEN=$fake_token"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
}

@test "UAT-003: sk-ant- Anthropic API key is redacted" {
  local fake_key="sk-ant-api03-$(python3 -c 'print("C"*20)' 2>/dev/null || printf 'CCCCCCCCCCCCCCCCCCCC')"
  local input="ANTHROPIC_API_KEY=$fake_key"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_key"* ]]
}

@test "UAT-003: sk- OpenAI key is redacted (and sk-ant- takes priority)" {
  local fake_openai="sk-$(python3 -c 'print("D"*20)' 2>/dev/null || printf 'DDDDDDDDDDDDDDDDDDDD')"
  local fake_anthropic="sk-ant-$(python3 -c 'print("E"*20)' 2>/dev/null || printf 'EEEEEEEEEEEEEEEEEEEE')"
  local result_openai
  result_openai="$(redact_body "$FAKE_ROOT" "key=$fake_openai")"
  [[ "$result_openai" != *"$fake_openai"* ]]

  local result_anthropic
  result_anthropic="$(redact_body "$FAKE_ROOT" "key=$fake_anthropic")"
  [[ "$result_anthropic" != *"$fake_anthropic"* ]]
}

@test "UAT-003: glpat- GitLab PAT is redacted" {
  local fake_token="glpat-$(python3 -c 'print("F"*20)' 2>/dev/null || printf 'FFFFFFFFFFFFFFFFFFFF')"
  local input="GITLAB_TOKEN=$fake_token"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
}

@test "UAT-003: xoxb- Slack token is redacted" {
  local fake_token="xoxb-$(python3 -c 'print("G"*10)' 2>/dev/null || printf 'GGGGGGGGGG')"
  local input="SLACK_TOKEN=$fake_token"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
}

# ---------------------------------------------------------------------------
# Env-var value scrub (step 3)
# ---------------------------------------------------------------------------

@test "UAT-003: env-var name is preserved but value is scrubbed" {
  local input="HOME=/Users/testuser"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  # Name preserved
  [[ "$result" == *"HOME="* ]]
  # Value scrubbed
  [[ "$result" != *"/Users/testuser"* ]]
  [[ "$result" == *"<redacted>"* ]]
}

@test "UAT-003: ANTHROPIC_API_KEY env-var name preserved, value scrubbed" {
  local input="ANTHROPIC_API_KEY=some-value-here"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" == *"ANTHROPIC_API_KEY=<redacted>"* ]]
}

# ---------------------------------------------------------------------------
# Idempotency; running redact twice yields same output
# ---------------------------------------------------------------------------

@test "UAT-003: redaction is idempotent (double-pass equals single-pass)" {
  local input="The file at $FAKE_ROOT/app/i18n.ts and HOME=/Users/testuser"
  local first_pass
  first_pass="$(redact_body "$FAKE_ROOT" "$input")"
  local second_pass
  second_pass="$(redact_body "$FAKE_ROOT" "$first_pass")"
  [[ "$first_pass" == "$second_pass" ]]
}

# ---------------------------------------------------------------------------
# Golden-file roundtrip for the secrets fixture
# ---------------------------------------------------------------------------

@test "UAT-010: secrets fixture after redaction matches golden byte-for-byte" {
  local input_file="$FIXTURES/input-with-secrets.txt"
  local golden_file="$FIXTURES/golden-secrets-redacted.md"

  [[ -f "$input_file" ]] || skip "input-with-secrets.txt not found"
  [[ -f "$golden_file" ]] || skip "golden-secrets-redacted.md not found"

  local input
  input="$(cat "$input_file")"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  local golden
  golden="$(cat "$golden_file")"

  [[ "$result" == "$golden" ]]
}

@test "UAT-010: init fixture (no secrets) is unchanged through redaction" {
  local input_file="$FIXTURES/input-init-failure.txt"
  local golden_file="$FIXTURES/golden-init-redacted.md"

  [[ -f "$input_file" ]] || skip "input-init-failure.txt not found"
  [[ -f "$golden_file" ]] || skip "golden-init-redacted.md not found"

  local input
  input="$(cat "$input_file")"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  local golden
  golden="$(cat "$golden_file")"

  [[ "$result" == "$golden" ]]
}
