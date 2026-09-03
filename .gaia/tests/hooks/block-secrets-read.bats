#!/usr/bin/env bats

# Tests for .claude/hooks/block-secrets-read.sh.
#
# This hook carries the obligation four permissions.deny rules used to hold:
# Read(**/*.key), Read(**/*.pem), Read(**/*credential*) and Read(**/secrets/*).
# Those rules are gone because a `**` Read() deny glob arms Claude Code's
# bypass-immune deniedPathInsideDirectory circuit breaker for every directory in
# the tree, forcing a manual approval prompt on every recursive search or copy.
# The absence of all four is asserted at the bottom of this file, because a
# well-meaning re-addition of any one of them reinstates the prompt storm.
#
# The guard is heuristic defense-in-depth, not a sandbox: it always exits 0,
# carrying the allow/deny decision in stdout JSON.

# shellcheck disable=SC2317
# SC2317 (command appears unreachable) is a structural false positive on every
# @test block below: bats invokes each test body through its own runner, which
# static shellcheck cannot see, so it marks the blocks unreachable. The directive
# is file-wide because the false positive is intrinsic to the bats structure, not
# to any single test, and it masks no genuine signal: SC2317 cannot reason about
# an indirectly-invoked bats suite at all.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-secrets-read.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

run_hook_read() {
  local path="$1"
  local json
  json=$(jq -n --arg p "$path" '{tool_name: "Read", tool_input: {file_path: $p}}')
  invoke_hook "$json" "$HOOK_ABS"
}

run_hook_bash() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook "$json" "$HOOK_ABS"
}

# --- Read-tool denies, one per path class the removed Read() globs covered ---

@test "Read certs/server.key is denied" {
  run_hook_read "certs/server.key"
  assert_denied_by_json
}

@test "Read certs/server.pem is denied" {
  run_hook_read "certs/server.pem"
  assert_denied_by_json
}

@test "Read config/aws-credentials.json is denied" {
  run_hook_read "config/aws-credentials.json"
  assert_denied_by_json
}

@test "Read secrets/prod.json is denied" {
  run_hook_read "secrets/prod.json"
  assert_denied_by_json
}

@test "Read a nested deploy/secrets/live/token.txt is denied" {
  # The replaced glob matched only a file DIRECTLY inside secrets/. Covering the
  # whole subtree is a deliberate widening: a secret one level deeper is not
  # less of a secret.
  run_hook_read "deploy/secrets/live/token.txt"
  assert_denied_by_json
}

@test "Read config/AWS_Credentials.json is denied (case-insensitive)" {
  # The replaced glob was case-sensitive. This is the second deliberate widening.
  run_hook_read "config/AWS_Credentials.json"
  assert_denied_by_json
}

# --- Read-tool allows: the near-misses a substring match would get wrong ---

@test "Read app/components/Button/index.tsx is allowed" {
  run_hook_read "app/components/Button/index.tsx"
  assert_allowed_by_json
}

@test "Read app/lib/keychain.ts is allowed (not a .key extension)" {
  run_hook_read "app/lib/keychain.ts"
  assert_allowed_by_json
}

@test "Read mysecrets/notes.md is allowed (segment-bounded, not a substring)" {
  run_hook_read "mysecrets/notes.md"
  assert_allowed_by_json
}

@test "Read secrets-old/notes.md is allowed (segment-bounded, not a prefix)" {
  run_hook_read "secrets-old/notes.md"
  assert_allowed_by_json
}

# --- Bash denies: readers against a secret path ---

@test "cat certs/server.key is denied" {
  run_hook_bash "cat certs/server.key"
  assert_denied_by_json
}

@test "grep TOKEN certs/server.pem is denied" {
  run_hook_bash "grep TOKEN certs/server.pem"
  assert_denied_by_json
}

@test "rg TOKEN secrets/prod.json is denied" {
  run_hook_bash "rg TOKEN secrets/prod.json"
  assert_denied_by_json
}

@test "grep -f certs/server.key foo.txt is denied (the pattern FILE is the secret)" {
  run_hook_bash "grep -f certs/server.key foo.txt"
  assert_denied_by_json
}

@test "x=\$(<certs/server.key) is denied (redirection)" {
  # The single-quoting is deliberate: the payload must reach the hook verbatim
  # so it classifies the literal command text. Never double-quote it, which
  # would expand the substitution here and defeat the test.
  # shellcheck disable=SC2016
  run_hook_bash 'x=$(<certs/server.key)'
  assert_denied_by_json
}

@test "true && cat certs/server.key is denied (compound-command segment walk)" {
  run_hook_bash "true && cat certs/server.key"
  assert_denied_by_json
}

@test "env FOO=1 cat certs/server.key is denied (env as a runner)" {
  run_hook_bash "env FOO=1 cat certs/server.key"
  assert_denied_by_json
}

# --- Bash allows: false-positive guards ---

@test "grep server.key .gitignore is allowed (pattern, not a file read)" {
  # The single most important allow in this file. Without grep argument
  # grammar the pattern operand reads as a path and this denies.
  run_hook_bash "grep server.key .gitignore"
  assert_allowed_by_json
}

@test "ls -la certs/server.key is allowed (non-reading)" {
  run_hook_bash "ls -la certs/server.key"
  assert_allowed_by_json
}

@test "cat mysecrets/notes.md is allowed (segment-bounded)" {
  run_hook_bash "cat mysecrets/notes.md"
  assert_allowed_by_json
}

@test "pnpm dev is allowed" {
  run_hook_bash "pnpm dev"
  assert_allowed_by_json
}

@test "cat app/services/env.ts is allowed" {
  run_hook_bash "cat app/services/env.ts"
  assert_allowed_by_json
}

@test "bare env is allowed (process dumps are the dotenv guard's remit)" {
  # This hook judges paths only. block-env-read.sh owns the dump question, and
  # duplicating it here would give one command two different refusals.
  run_hook_bash "env"
  assert_allowed_by_json
}

# --- Structural ---

@test "block-secrets-read.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers block-secrets-read.sh under the Read matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Read") | .hooks[] | select(.command | endswith("/.claude/hooks/block-secrets-read.sh\""))' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-secrets-read.sh under the Bash matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | endswith("/.claude/hooks/block-secrets-read.sh\""))' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "permissions.deny carries none of the four replaced Read() globs" {
  run jq -e '[.permissions.deny[] | select(startswith("Read("))] | length == 0' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
