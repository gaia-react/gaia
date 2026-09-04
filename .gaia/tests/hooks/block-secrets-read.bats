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

run_hook_grep() {
  local path="$1" glob="$2"
  local json
  json=$(jq -n --arg p "$path" --arg g "$glob" '{
    tool_name: "Grep",
    tool_input: ({pattern: "x"}
      + (if $p == "" then {} else {path: $p} end)
      + (if $g == "" then {} else {glob: $g} end))
  }')
  invoke_hook "$json" "$HOOK_ABS"
}

# Run the hook with lib/reader-operands.sh absent, to exercise the grammar-load
# failure arm.
#
# The hook is COPIED into this test's own temporary directory and driven from
# there, with no library beside it. It must never be exercised by hiding the
# real one: both read-guard suites would target the identical absolute path,
# .gaia/tests/bats-shards.sh weighs by file size and may put them in one shard
# or in two, and .gaia/tests/run-bats-parallel.sh forks every shard into ONE
# shared workspace. One shard is if anything the stronger reason rather than a
# reprieve: the pair then runs sequentially inside a single bats invocation over
# that same one workspace.
# While one suite held the library hidden, every allow-assertion in its sibling
# would see the fail-closed deny, so the pair would flake against each other and
# the concurrency-safety claim that runner makes would be false. The live
# session's own Read, Grep and Bash calls run through these same hooks and would
# be denied for the width of that window too.
#
# The hook resolves its library as `dirname "${BASH_SOURCE[0]}"/lib`, so a copy
# in a directory with an empty lib/ beside it reaches for a file that is not
# there, which is the missing-library arm exactly. The directory is created and
# left empty rather than omitted so the arm under test is the absent FILE rather
# than an unresolvable lib dir; both deny, and pinning the narrower one is what
# makes this a test of the probe instead of a test of `cd`.
run_hook_without_library() {
  local json dir
  dir="$BATS_TEST_TMPDIR/nolib"
  mkdir -p "$dir/lib"
  cp "$HOOK_ABS" "$dir/"
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "cat README.md"}}')
  invoke_hook "$json" "$dir/$(basename "$HOOK_ABS")"
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

# --- Regression: a discard-listed flag that is value-less for the invoked tool ---
#
# Each of these was ALLOWED before the flag tables dropped -r, -T and the bare
# --color/--colour spelling. The flag ate the pattern, the path was then taken
# as the pattern, and the walk emitted no operand at all, so the guard passed a
# secret read through in silence. `-rn` denied throughout, which is what kept
# the class invisible: the idiomatic spelling sat untested beside a working one.

@test "grep -r TOKEN certs/server.key is denied (bare -r is value-less for grep)" {
  run_hook_bash "grep -r TOKEN certs/server.key"
  assert_denied_by_json
}

@test "grep -r TOKEN secrets/prod.json is denied" {
  run_hook_bash "grep -r TOKEN secrets/prod.json"
  assert_denied_by_json
}

@test "grep -T TOKEN certs/server.pem is denied (bare -T is value-less for grep)" {
  run_hook_bash "grep -T TOKEN certs/server.pem"
  assert_denied_by_json
}

@test "grep --color TOKEN certs/server.key is denied (optional-value for grep)" {
  run_hook_bash "grep --color TOKEN certs/server.key"
  assert_denied_by_json
}

@test "grep --colour TOKEN certs/server.key is denied" {
  run_hook_bash "grep --colour TOKEN certs/server.key"
  assert_denied_by_json
}

@test "rg -r X secrets/prod.json is denied (over-reads the pattern, fail-closed)" {
  run_hook_bash "rg -r X secrets/prod.json"
  assert_denied_by_json
}

@test "grep --color=auto server.key .gitignore is allowed (= form supplies its own value)" {
  run_hook_bash "grep --color=auto server.key .gitignore"
  assert_allowed_by_json
}

# --- Grep tool: content mode returns file contents, so it reads a path ---

@test "Grep path certs/server.key is denied" {
  run_hook_grep "certs/server.key" ""
  assert_denied_by_json
}

@test "Grep path secrets/prod.json is denied" {
  run_hook_grep "secrets/prod.json" ""
  assert_denied_by_json
}

@test "Grep glob *.key is denied (the filter selects the secret class)" {
  run_hook_grep "" "*.key"
  assert_denied_by_json
}

@test "Grep path app/lib/keychain.ts is allowed" {
  run_hook_grep "app/lib/keychain.ts" ""
  assert_allowed_by_json
}

@test "settings.json registers block-secrets-read.sh under the Grep matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Grep") | .hooks[] | select(.command | endswith("/.claude/hooks/block-secrets-read.sh\""))' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

# --- Fail-closed on a grammar-load failure ---
#
# The arm this pins used to be `exit 1`. Only exit 2 or a structured deny blocks
# a PreToolUse call, so a missing library allowed every secret read with a
# stderr line as the only trace. Asserting the deny payload rather than the exit
# status is the point: the exit status was 1 then and is 0 now, and neither
# value distinguishes a guard that is running from one that is not.

@test "a missing lib/reader-operands.sh denies rather than allowing the call" {
  run_hook_without_library
  assert_denied_by_json
}

# --- The sandbox tier the removed Read() rules used to carry ---

@test "settings.json declares sandbox.filesystem.denyRead for the secret classes" {
  run jq -e '
    .sandbox.filesystem.denyRead as $d
    | ["**/*.key", "**/*.pem", "**/*credential*", "**/secrets/**"]
    | all(. as $needle | $d | index($needle) != null)
  ' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

# --- Regression: a command substitution in either spelling ---
#
# The segment split reaches into `$(...)` because the parens are in its
# character set, and used not to reach into a backtick pair. The two spellings
# of one read therefore disagreed, and the backtick form was allowed.

@test "x=\$(cat certs/server.key) is denied (dollar-paren substitution)" {
  run_hook_bash 'x=$(cat certs/server.key)'
  assert_denied_by_json
}

@test "x=\`cat certs/server.key\` is denied (backtick substitution)" {
  run_hook_bash 'x=`cat certs/server.key`'
  assert_denied_by_json
}

@test "echo \`cat secrets/prod.json\` is denied (reader hidden inside a backtick pair)" {
  run_hook_bash 'echo `cat secrets/prod.json`'
  assert_denied_by_json
}
