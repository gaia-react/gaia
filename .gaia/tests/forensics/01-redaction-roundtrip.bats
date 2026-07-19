#!/usr/bin/env bats
# UAT-003: absolute paths converted to repo-relative, token-shaped values replaced with <redacted>
# UAT-010: body post-redaction is byte-identical for local save and GH issue surfaces

# TST-03's recheck-halt test uses `run --separate-stderr` (bats >= 1.5.0).
bats_require_minimum_version 1.5.0

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
  local fake_token; fake_token="gho_$(python3 -c 'print("A"*20)' 2>/dev/null || printf 'AAAAAAAAAAAAAAAAAAAA')"
  local input="Token: $fake_token in the env"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
  [[ "$result" == *"<redacted>"* ]]
}

@test "UAT-003: ghp_ GitHub PAT is redacted" {
  local fake_token; fake_token="ghp_$(python3 -c 'print("B"*20)' 2>/dev/null || printf 'BBBBBBBBBBBBBBBBBBBB')"
  local input="GITHUB_TOKEN=$fake_token"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
}

@test "UAT-003: sk-ant- Anthropic API key is redacted" {
  local fake_key; fake_key="sk-ant-api03-$(python3 -c 'print("C"*20)' 2>/dev/null || printf 'CCCCCCCCCCCCCCCCCCCC')"
  local input="ANTHROPIC_API_KEY=$fake_key"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_key"* ]]
}

@test "UAT-003: sk- OpenAI key is redacted (and sk-ant- takes priority)" {
  local fake_openai; fake_openai="sk-$(python3 -c 'print("D"*20)' 2>/dev/null || printf 'DDDDDDDDDDDDDDDDDDDD')"
  local fake_anthropic; fake_anthropic="sk-ant-$(python3 -c 'print("E"*20)' 2>/dev/null || printf 'EEEEEEEEEEEEEEEEEEEE')"
  local result_openai
  result_openai="$(redact_body "$FAKE_ROOT" "key=$fake_openai")"
  [[ "$result_openai" != *"$fake_openai"* ]]

  local result_anthropic
  result_anthropic="$(redact_body "$FAKE_ROOT" "key=$fake_anthropic")"
  [[ "$result_anthropic" != *"$fake_anthropic"* ]]
}

@test "UAT-003: glpat- GitLab PAT is redacted" {
  local fake_token; fake_token="glpat-$(python3 -c 'print("F"*20)' 2>/dev/null || printf 'FFFFFFFFFFFFFFFFFFFF')"
  local input="GITLAB_TOKEN=$fake_token"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
}

@test "UAT-003: xoxb- Slack token is redacted" {
  local fake_token; fake_token="xoxb-$(python3 -c 'print("G"*10)' 2>/dev/null || printf 'GGGGGGGGGG')"
  local input="SLACK_TOKEN=$fake_token"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
}

# ---------------------------------------------------------------------------
# SEC-1: fine-grained GitHub PAT (github_pat_...)
# Synthetic body is lowercase, so no other pattern (AWS, generic) catches it
# pre-fix; this test is red until pattern 1 gains the github_pat_ pass.
# ---------------------------------------------------------------------------

@test "SEC-1: github_pat_ fine-grained PAT is redacted" {
  local fake_token; fake_token="github_pat_$(python3 -c 'print("a"*30)' 2>/dev/null || printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')"
  local input="Found in shell environment: $fake_token was present"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
  [[ "$result" == *"<redacted>"* ]]
}

# ---------------------------------------------------------------------------
# SEC-3: JWT, Bearer, Slack xapp-, connection-string credentials
# Each is placed mid-line with no token|key|secret keyword nearby, so the
# generic fallback cannot mask a missing dedicated pass; each is red pre-fix.
# ---------------------------------------------------------------------------

@test "SEC-3: JWT triple-segment token is redacted" {
  local jwt="eyJhbGci.eyJzdW0iOne.abcdefghij0123"
  local input="Session JWT was $jwt in the log"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$jwt"* ]]
  [[ "$result" == *"<redacted>"* ]]
}

@test "SEC-3: Bearer token value is redacted, label preserved" {
  local tok
  tok="$(python3 -c 'print("a"*24)' 2>/dev/null || printf 'aaaaaaaaaaaaaaaaaaaaaaaa')"
  local input="Authorization: Bearer $tok"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"Bearer $tok"* ]]
  [[ "$result" == *"Bearer <redacted>"* ]]
}

@test "SEC-3: xapp- Slack app-level token is redacted" {
  local fake_token; fake_token="xapp-$(python3 -c 'print("1-" + "G"*12)' 2>/dev/null || printf '1-GGGGGGGGGGGG')"
  local input="Slack app credential $fake_token present"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"$fake_token"* ]]
  [[ "$result" == *"<redacted>"* ]]
}

@test "SEC-3: connection-string credentials are redacted, scheme and host preserved" {
  local input="DB at postgres://dbuser:s3cr3tpass@db.example.com:5432/mydb"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"dbuser:s3cr3tpass"* ]]
  [[ "$result" == *"postgres://<redacted>@db.example.com"* ]]
}

# ---------------------------------------------------------------------------
# SEC-4: bare home dir (/Users/<name>, /home/<name>, /root) collapses to <home>
# ---------------------------------------------------------------------------

@test "SEC-4: bare /Users/<name> home dir collapses to <home>" {
  local input="User home is /Users/alice and nothing else"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"/Users/alice"* ]]
  [[ "$result" == *"<home>"* ]]
}

@test "SEC-4: bare /home/<name> home dir collapses to <home>" {
  local input="The account lives at /home/bob today"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"/home/bob"* ]]
  [[ "$result" == *"<home>"* ]]
}

@test "SEC-4: /root path with trailing component collapses (no /root survives)" {
  local input="Running as root from /root/.ssh/id_rsa"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" == *"id_rsa"* ]]
  # Discriminating assertion last (bats keys off the final command's status):
  # /root must not survive after SEC-4's /root trailing collapse.
  [[ "$result" == "Running as root from id_rsa" ]]
}

@test "SEC-4: bare /root collapses to <home>" {
  local input="Home directory: /root end"
  local result
  result="$(redact_body "$FAKE_ROOT" "$input")"
  [[ "$result" != *"/root"* ]]
  [[ "$result" == *"<home>"* ]]
}

# ---------------------------------------------------------------------------
# TST-03: sanity-recheck halt path (survivor -> non-zero exit, empty stdout)
# Override sed with cat so the forward passes no-op and a raw token reaches
# the recheck untouched; the recheck greps still fire and must halt.
# ---------------------------------------------------------------------------

@test "TST-03: recheck halts with no partial body when a token survives the forward passes" {
  sed() { cat; }
  local fake_token; fake_token="gho_$(python3 -c 'print("Z"*24)' 2>/dev/null || printf 'ZZZZZZZZZZZZZZZZZZZZZZZZ')"
  run --separate-stderr redact_body "$FAKE_ROOT" "leaked credential: $fake_token"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"REDACTION BUG"* ]]
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
  # TST-04: the mid-line HOME=/Users/testuser must not survive (env-scrub is
  # line-anchored and misses it; SEC-4's bare-home collapse catches it).
  # Discriminating assertion last (bats keys off the final command's status).
  [[ "$first_pass" != *"/home/"* ]]
  [[ "$first_pass" != *"/Users/"* ]]
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
