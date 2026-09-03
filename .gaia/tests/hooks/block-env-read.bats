#!/usr/bin/env bats

# Tests for .claude/hooks/block-env-read.sh.
#
# This hook is the WHOLE read-side guard for dotenv paths: settings.json carries
# no Read() deny rule behind it. It covers the Read tool and the Bash readers
# (including the grep family) against .env and every variant (.env.local,
# .env.*, not .env.example); sourcing; redirection; `env FOO=1 <reader>`; and
# bare environment dumps (env/printenv/...) that read the shell environment
# rather than a file. The guard is heuristic defense-in-depth, not a sandbox: it
# always exits 0, carrying the allow/deny decision in stdout JSON.
#
# The settings.json assertions at the bottom pin the absence of every Read()
# deny rule. That absence is load-bearing rather than incidental: a single
# Read() rule re-arms Claude Code's bypass-immune deniedPathInsideDirectory
# circuit breaker, which forces a manual approval prompt on every recursive
# search or copy in the tree.

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
  HOOK_ABS="$HOOKS_SRC/block-env-read.sh"
  WRITE_HOOK_ABS="$HOOKS_SRC/block-env-write.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Several payloads below carry Bash commands with single quotes of their own
# (grep '.env' .gitignore, env SECRET=hunter2 cat .env.local), so delivery goes
# through `invoke_hook` (helpers/run-hook.sh) rather than any local variant.
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

run_write_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg t "$tool" --arg p "$path" '{tool_name: $t, tool_input: {file_path: $p}}')
  invoke_hook "$json" "$WRITE_HOOK_ABS"
}



# --- Read-tool denies (UAT-001, UAT-002) ---

@test "Read .env.local is denied" {
  run_hook_read ".env.local"
  assert_denied_by_json
}

@test "Read .env.production is denied" {
  run_hook_read ".env.production"
  assert_denied_by_json
}

@test "Read a nested packages/api/.env.production is denied" {
  run_hook_read "packages/api/.env.production"
  assert_denied_by_json
}

# --- Read-tool allow (UAT-003) ---

@test "Read .env.example is allowed" {
  run_hook_read ".env.example"
  assert_allowed_by_json
}

# --- Bash denies: recognized readers against variants (UAT-001, UAT-002) ---

@test "cat .env.local is denied" {
  run_hook_bash "cat .env.local"
  assert_denied_by_json
}

@test "cat .env.production is denied" {
  run_hook_bash "cat .env.production"
  assert_denied_by_json
}

@test "cat a nested packages/api/.env.production is denied" {
  run_hook_bash "cat packages/api/.env.production"
  assert_denied_by_json
}

# --- Bash denies: residual read paths (UAT-004) ---

@test "source .env is denied" {
  run_hook_bash "source .env"
  assert_denied_by_json
}

@test ". ./.env is denied" {
  run_hook_bash ". ./.env"
  assert_denied_by_json
}

@test "x=\$(<.env) is denied" {
  # The single-quoting is deliberate: the payload must reach the hook verbatim
  # so it classifies the literal command text. Never double-quote it, which
  # would expand $(<.env) here and defeat the test.
  # shellcheck disable=SC2016
  run_hook_bash 'x=$(<.env)'
  assert_denied_by_json
}

@test "xxd .env is denied" {
  run_hook_bash "xxd .env"
  assert_denied_by_json
}

@test "true && cat .env.local is denied (compound-command segment walk)" {
  run_hook_bash "true && cat .env.local"
  assert_denied_by_json
}

@test "cd /tmp; cat .env.local is denied (semicolon segment walk)" {
  run_hook_bash "cd /tmp; cat .env.local"
  assert_denied_by_json
}

@test "false || cat .env.local is denied (or segment walk)" {
  run_hook_bash "false || cat .env.local"
  assert_denied_by_json
}

# --- Bash denies: bare environment dumps (UAT-005) ---

@test "bare env is denied" {
  run_hook_bash "env"
  assert_denied_by_json
}

@test "bare printenv is denied" {
  run_hook_bash "printenv"
  assert_denied_by_json
}

@test "printenv NODE_ENV is denied (printenv has no runner form)" {
  run_hook_bash "printenv NODE_ENV"
  assert_denied_by_json
}

# --- Bash allows: env as a runner (UAT-005) ---

@test "env NODE_ENV=production node app.js is allowed" {
  run_hook_bash "env NODE_ENV=production node app.js"
  assert_allowed_by_json
}

# --- Bash allows: false-positive guards (UAT-006) ---

@test "pnpm dev is allowed" {
  run_hook_bash "pnpm dev"
  assert_allowed_by_json
}

@test "pnpm i && pnpm dev is allowed (benign compound command)" {
  run_hook_bash "pnpm i && pnpm dev"
  assert_allowed_by_json
}

@test "cat app/services/env.ts is allowed" {
  run_hook_bash "cat app/services/env.ts"
  assert_allowed_by_json
}

@test "cat README.md is allowed" {
  run_hook_bash "cat README.md"
  assert_allowed_by_json
}

@test "cp .env.example .env is allowed" {
  run_hook_bash "cp .env.example .env"
  assert_allowed_by_json
}

@test "grep '.env' .gitignore is allowed (pattern, not a file read)" {
  run_hook_bash "grep '.env' .gitignore"
  assert_allowed_by_json
}

# --- Bash denies: the grep family, which needs argument grammar ---

@test "grep SECRET .env is denied" {
  run_hook_bash "grep SECRET .env"
  assert_denied_by_json
}

@test "grep -rn SECRET .env.local is denied" {
  run_hook_bash "grep -rn SECRET .env.local"
  assert_denied_by_json
}

@test "rg SECRET .env.production is denied" {
  run_hook_bash "rg SECRET .env.production"
  assert_denied_by_json
}

@test "grep -f .env foo.txt is denied (the pattern FILE is the secret)" {
  # -f names a file of patterns, which grep opens. The value is a read even
  # though it sits where a discarded flag value normally would.
  run_hook_bash "grep -f .env foo.txt"
  assert_denied_by_json
}

@test "/usr/bin/grep SECRET .env is denied (reader reached through a path)" {
  run_hook_bash "/usr/bin/grep SECRET .env"
  assert_denied_by_json
}

# --- Bash allows: the grep family, pattern operand not mistaken for a path ---

@test "grep -e .env .gitignore is allowed (-e supplies the pattern)" {
  run_hook_bash "grep -e .env .gitignore"
  assert_allowed_by_json
}

@test "grep --include=*.ts SECRET app is allowed" {
  run_hook_bash "grep --include=*.ts SECRET app"
  assert_allowed_by_json
}

@test "grep SECRET .env.example is allowed" {
  run_hook_bash "grep SECRET .env.example"
  assert_allowed_by_json
}

@test "rg --ignore-file .rgignore SECRET app is allowed" {
  # --ignore-file names a file of globs and supplies no pattern, so the
  # positional after it is still the pattern rather than a path.
  run_hook_bash "rg --ignore-file .rgignore SECRET app"
  assert_allowed_by_json
}

@test "ls -la .env is allowed (non-reading)" {
  run_hook_bash "ls -la .env"
  assert_allowed_by_json
}

@test "cat .env.example is allowed (UAT-003)" {
  run_hook_bash "cat .env.example"
  assert_allowed_by_json
}

# --- Self-leak (UAT-009) ---

@test "env SECRET=hunter2 cat .env.local is denied without leaking the inline value" {
  run_hook_bash "env SECRET=hunter2 cat .env.local"
  assert_denied_by_json
  grep -qF -- "hunter2" <<<"$output" && return 1
  grep -qF -- "env SECRET=hunter2 cat .env.local" <<<"$output" && return 1
  return 0
}

# --- UAT-007: Edit/Write dimension, driven against the existing write hook ---

@test "Edit on .env.local is denied by block-env-write.sh (UAT-007)" {
  run_write_hook_edit "Edit" ".env.local"
  assert_denied_by_json
}

@test "Write on .env.example is allowed by block-env-write.sh (UAT-007)" {
  run_write_hook_edit "Write" ".env.example"
  assert_allowed_by_json
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
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Read") | .hooks[] | select(.command | endswith("/.claude/hooks/block-env-read.sh\""))' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-env-read.sh under the Bash matcher (UAT-008)" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | endswith("/.claude/hooks/block-env-read.sh\""))' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "permissions.deny carries no Read() rule at all" {
  # Not merely "no Read(.env)": ANY Read() deny rule arms the bypass-immune
  # deniedPathInsideDirectory breaker, so the guarantee this hook is paid to
  # provide is the empty set, and a well-meaning re-addition of any one of them
  # silently reinstates the prompt storm this suite exists to keep away.
  run jq -e '[.permissions.deny[] | select(startswith("Read("))] | length == 0' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "permissions.deny keeps the write-side .env backstop" {
  # Edit(.env) blocks every file-writing tool (Write, Edit, MultiEdit,
  # NotebookEdit), so a separate Write(.env) deny is redundant and is
  # intentionally absent. Only the READ half moved to the hook layer; an Edit()
  # rule arms no read breaker and therefore costs nothing to keep.
  run jq -e '.permissions.deny | index("Edit(.env)")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "permissions.deny adds no .env.example deny and no .env.* glob" {
  run jq -e '[.permissions.deny[] | select(contains(".env.example") or contains(".env.*"))] | length == 0' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "a benign Bash command allows without short-circuiting the chain (UAT-008)" {
  run_hook_bash "pnpm dev"
  assert_allowed_by_json
}

@test "hook header documents the corrected posture (UAT-010)" {
  grep -qF -- "defense-in-depth" "$HOOK_ABS"
  grep -qF -- "not a sandbox" "$HOOK_ABS"
  grep -qF -- "sandbox.filesystem" "$HOOK_ABS"
  grep -qiF -- "variant" "$HOOK_ABS"
  grep -qF -- "Serena" "$HOOK_ABS"
}
