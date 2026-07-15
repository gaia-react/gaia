#!/usr/bin/env bats

# Tests for .claude/hooks/block-env-read.sh.
#
# Read(.env) in settings.json already enforces against the Read tool and the
# Bash file commands Claude Code recognizes (cat/head/tail/sed) targeting a
# file literally named .env, at any depth. This hook closes the residual
# gaps that rule leaves open: variant dotenv files (.env.local, .env.*, not
# .env.example) unmatched by Read(.env); Bash sourcing, redirection, and
# non-recognized readers against a dotenv path; and bare environment dumps
# (env/printenv/...) that read the shell environment rather than a file. The
# guard is heuristic defense-in-depth, not a sandbox: it always exits 0,
# carrying the allow/deny decision in stdout JSON.

# shellcheck disable=SC2317
# SC2317 (command appears unreachable) is a structural false positive on every
# @test block below: bats invokes each test body through its own runner, which
# static shellcheck cannot see, so it marks the blocks unreachable. The directive
# is file-wide because the false positive is intrinsic to the bats structure, not
# to any single test, and it masks no genuine signal: SC2317 cannot reason about
# an indirectly-invoked bats suite at all.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-env-read.sh"
  WRITE_HOOK_ABS="$HOOKS_SRC/block-env-write.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Quote-safe delivery (mandatory): several payloads below carry Bash commands
# that contain single quotes of their own (grep '.env' .gitignore, env
# SECRET=hunter2 cat .env.local). Re-wrapping $json in an outer
# single-quoted `bash -c '...'` string would let those embedded quotes
# terminate the wrapper early. Passing $json and the hook path as positional
# args instead means no re-quoting happens.
run_hook_read() {
  local path="$1"
  local json
  json=$(jq -n --arg p "$path" '{tool_name: "Read", tool_input: {file_path: $p}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_bash() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_write_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg t "$tool" --arg p "$path" '{tool_name: $t, tool_input: {file_path: $p}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$WRITE_HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  ! grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# --- Read-tool denies (UAT-001, UAT-002) ---

@test "Read .env.local is denied" {
  run_hook_read ".env.local"
  assert_denied
}

@test "Read .env.production is denied" {
  run_hook_read ".env.production"
  assert_denied
}

@test "Read a nested packages/api/.env.production is denied" {
  run_hook_read "packages/api/.env.production"
  assert_denied
}

# --- Read-tool allow (UAT-003) ---

@test "Read .env.example is allowed" {
  run_hook_read ".env.example"
  assert_allowed
}

# --- Bash denies: recognized readers against variants (UAT-001, UAT-002) ---

@test "cat .env.local is denied" {
  run_hook_bash "cat .env.local"
  assert_denied
}

@test "cat .env.production is denied" {
  run_hook_bash "cat .env.production"
  assert_denied
}

@test "cat a nested packages/api/.env.production is denied" {
  run_hook_bash "cat packages/api/.env.production"
  assert_denied
}

# --- Bash denies: residual read paths (UAT-004) ---

@test "source .env is denied" {
  run_hook_bash "source .env"
  assert_denied
}

@test ". ./.env is denied" {
  run_hook_bash ". ./.env"
  assert_denied
}

@test "x=\$(<.env) is denied" {
  # The single-quoting is deliberate: the payload must reach the hook verbatim
  # so it classifies the literal command text. Never double-quote it, which
  # would expand $(<.env) here and defeat the test.
  # shellcheck disable=SC2016
  run_hook_bash 'x=$(<.env)'
  assert_denied
}

@test "xxd .env is denied" {
  run_hook_bash "xxd .env"
  assert_denied
}

@test "true && cat .env.local is denied (compound-command segment walk)" {
  run_hook_bash "true && cat .env.local"
  assert_denied
}

@test "cd /tmp; cat .env.local is denied (semicolon segment walk)" {
  run_hook_bash "cd /tmp; cat .env.local"
  assert_denied
}

@test "false || cat .env.local is denied (or segment walk)" {
  run_hook_bash "false || cat .env.local"
  assert_denied
}

# --- Bash denies: bare environment dumps (UAT-005) ---

@test "bare env is denied" {
  run_hook_bash "env"
  assert_denied
}

@test "bare printenv is denied" {
  run_hook_bash "printenv"
  assert_denied
}

@test "printenv NODE_ENV is denied (printenv has no runner form)" {
  run_hook_bash "printenv NODE_ENV"
  assert_denied
}

# --- Bash allows: env as a runner (UAT-005) ---

@test "env NODE_ENV=production node app.js is allowed" {
  run_hook_bash "env NODE_ENV=production node app.js"
  assert_allowed
}

# --- Bash allows: false-positive guards (UAT-006) ---

@test "pnpm dev is allowed" {
  run_hook_bash "pnpm dev"
  assert_allowed
}

@test "pnpm i && pnpm dev is allowed (benign compound command)" {
  run_hook_bash "pnpm i && pnpm dev"
  assert_allowed
}

@test "cat app/services/env.ts is allowed" {
  run_hook_bash "cat app/services/env.ts"
  assert_allowed
}

@test "cat README.md is allowed" {
  run_hook_bash "cat README.md"
  assert_allowed
}

@test "cp .env.example .env is allowed" {
  run_hook_bash "cp .env.example .env"
  assert_allowed
}

@test "grep '.env' .gitignore is allowed (pattern, not a file read)" {
  run_hook_bash "grep '.env' .gitignore"
  assert_allowed
}

@test "ls -la .env is allowed (non-reading)" {
  run_hook_bash "ls -la .env"
  assert_allowed
}

@test "cat .env.example is allowed (UAT-003)" {
  run_hook_bash "cat .env.example"
  assert_allowed
}

# --- Self-leak (UAT-009) ---

@test "env SECRET=hunter2 cat .env.local is denied without leaking the inline value" {
  run_hook_bash "env SECRET=hunter2 cat .env.local"
  assert_denied
  grep -qF -- "hunter2" <<<"$output" && return 1
  grep -qF -- "env SECRET=hunter2 cat .env.local" <<<"$output" && return 1
  return 0
}

# --- UAT-007: Edit/Write dimension, driven against the existing write hook ---

@test "Edit on .env.local is denied by block-env-write.sh (UAT-007)" {
  run_write_hook_edit "Edit" ".env.local"
  assert_denied
}

@test "Write on .env.example is allowed by block-env-write.sh (UAT-007)" {
  run_write_hook_edit "Write" ".env.example"
  assert_allowed
}

# --- Structural ---

@test "block-env-read.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json is valid JSON" {
  run jq empty "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-env-read.sh under the Read matcher (UAT-008)" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Read") | .hooks[] | select(.command == ".claude/hooks/block-env-read.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-env-read.sh under the Bash matcher (UAT-008)" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == ".claude/hooks/block-env-read.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "permissions.deny still contains the exact .env backstop entries" {
  # Read(.env) blocks reads; Edit(.env) blocks every file-writing tool (Write,
  # Edit, MultiEdit, NotebookEdit), so a separate Write(.env) deny is redundant
  # and is intentionally absent.
  run jq -e '.permissions.deny | index("Read(.env)")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
  run jq -e '.permissions.deny | index("Edit(.env)")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "permissions.deny adds no .env.example deny and no .env.* glob" {
  run jq -e '[.permissions.deny[] | select(contains(".env.example") or contains(".env.*"))] | length == 0' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "a benign Bash command allows without short-circuiting the chain (UAT-008)" {
  run_hook_bash "pnpm dev"
  assert_allowed
}

@test "hook header documents the corrected posture (UAT-010)" {
  grep -qF -- "defense-in-depth" "$HOOK_ABS"
  grep -qF -- "not a sandbox" "$HOOK_ABS"
  grep -qF -- "sandbox.filesystem" "$HOOK_ABS"
  grep -qiF -- "variant" "$HOOK_ABS"
  grep -qF -- "Serena" "$HOOK_ABS"
}
