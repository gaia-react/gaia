#!/usr/bin/env bats

# Tests for .claude/hooks/block-secrets-write.sh.
#
# The guard is a write-time heuristic, not a sandbox: it scans the content an
# Edit/Write/MultiEdit is about to introduce and denies four shapes of obvious
# committed secret (AWS access-key id, GitHub PAT, PEM private-key header, and a
# dotenv-style assignment to a suspicious name). It always exits 0, carrying the
# allow/deny decision in stdout JSON.
#
# The dotenv rule is the only one with an allowlist, because it is the only one
# that matches on a *name* rather than on secret-shaped material: a line whose
# name ends in _TOKEN/_SECRET/_KEY/_PASSWORD is suspicious, so the value decides.
# The allowlist therefore carries the whole weight of the rule's false-positive
# behavior, and the deny cases below are what pin down that widening it does not
# hollow it out.
#
# Writing this file is itself subject to the guard, so every secret-shaped
# fixture is concatenated at runtime from fragments that match no pattern as
# written. Do not "tidy" those into single literals; the guard will deny the
# edit that does it.

# shellcheck disable=SC2317
# SC2317 (command appears unreachable) is a structural false positive on every
# @test block below: bats invokes each test body through its own runner, which
# static shellcheck cannot see, so it marks the blocks unreachable. The directive
# is file-wide because the false positive is intrinsic to the bats structure, not
# to any single test, and it masks no genuine signal: SC2317 cannot reason about
# an indirectly-invoked bats suite at all.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-secrets-write.sh"
}

# Quote-safe delivery: the payloads below carry shell snippets with quotes of
# their own, so $json and the hook path go in as positional args rather than
# being re-wrapped in an outer quoted string.
run_hook_write() {
  local body="$1"
  local json
  json=$(jq -n --arg c "$body" '{tool_name: "Write", tool_input: {content: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_edit() {
  local body="$1"
  local json
  json=$(jq -n --arg s "$body" '{tool_name: "Edit", tool_input: {new_string: $s}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  ! grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# --- The three secret-shaped patterns still deny ---

@test "an AWS access-key id is denied" {
  local aws_id="AKIA""IOSFODNN7EXAMPLE"
  run_hook_write "const id = '$aws_id'"
  assert_denied
}

@test "a GitHub personal-access-token is denied" {
  local pat="ghp""_0123456789abcdefghij"
  run_hook_write "const token = '$pat'"
  assert_denied
}

@test "a PEM private-key header is denied" {
  local pem="-----BEGIN RSA PRIVATE ""KEY-----"
  run_hook_write "$pem"
  assert_denied
}

# --- The dotenv rule still denies a real literal value ---

@test "a dotenv assignment with a literal value is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

@test "a dotenv assignment with a literal value is denied through Edit too" {
  run_hook_edit "$(printf 'DB_PASSWORD=%s\n' 'hunter2-not-a-placeholder')"
  assert_denied
}

@test "a literal value is denied even when a command substitution precedes it" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(whoami)-sk-live-9f3a1c4e8b7d2064')"
  assert_denied
}

# The four below pin the allowlist's command-substitution arm to "wholly a
# substitution" rather than "starts with $( and ends with )". Each is a value a
# both-ends-anchored `\$\(.+\)` would admit, because `.` matches the very `)`
# the closing anchor is supposed to certify. Together they also pin both
# anchors: the trailing one against the first three, the leading one against
# the last, which is the shape a dropped `^` would silently let through.

@test "a literal value between two command substitutions is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(true)sk-live-9f3a1c4e8b7d2064$(true)')"
  assert_denied
}

@test "a literal value is denied when it merely ends in a closing paren" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$(whoami)sk-live-9f3a1c4e8b7d2064)')"
  assert_denied
}

@test "a literal value spliced between quoted command substitutions is denied" {
  run_hook_write "$(printf 'API_KEY=%s\n' '"$(a)"sk-live-9f3a1c4e8b7d2064"$(b)"')"
  assert_denied
}

@test "a literal value is denied even when a command substitution follows it" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064$(whoami)')"
  assert_denied
}

# --- The existing allowlist arms still allow ---

@test "an empty value is allowed" {
  run_hook_write "$(printf 'API_KEY=\n')"
  assert_allowed
}

@test "a bare \$VAR value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '$MY_API_KEY')"
  assert_allowed
}

@test "a braced \${VAR} value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' '${MY_API_KEY}')"
  assert_allowed
}

@test "a named placeholder value is allowed" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'placeholder')"
  assert_allowed
}

@test "content with no secret shape at all is allowed" {
  run_hook_write "export function add(a, b) { return a + b }"
  assert_allowed
}

# --- A computed value is allowed: the source line holds no literal secret ---
#
# A value that is wholly a command substitution is resolved at run time, so the
# source line carries nothing to leak. Denying it taught callers to launder the
# assignment through a throwaway variable or an off-target name, which is
# unexplained residue in exchange for no security.
#
# The arm reads shape, not meaning, and the deny cases above are the price of
# keeping that shape honest. A nested `$(op read op://vault/$(hostname))` is
# denied, and `$(echo <a-literal-secret>)` is allowed: no regex tells those
# apart from `$(mint_key)` without reading the command. Neither is pinned here,
# because neither is behavior worth freezing.

@test "a value that is wholly a command substitution is allowed" {
  run_hook_write "$(printf 'AUDIT_KEY="%s"\n' '$(gaia_audit_key "$BASE_SHA")')"
  assert_allowed
}

@test "an unquoted command substitution value is allowed" {
  run_hook_write "$(printf 'SESSION_TOKEN=%s\n' '$(mint_token)')"
  assert_allowed
}

@test "a command substitution is allowed through Edit too" {
  run_hook_edit "$(printf 'AUDIT_KEY="%s"\n' '$(gaia_audit_key "$BASE_SHA")')"
  assert_allowed
}
