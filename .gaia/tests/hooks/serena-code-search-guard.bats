#!/usr/bin/env bats

# Tests for .claude/hooks/serena-code-search-guard.sh.
#
# The guard is a PreToolUse routing hook registered under BOTH the Grep and Bash
# matchers. It blocks (exit 2, BLOCKED on stderr) a bare-identifier symbol search
# over app/** or test/** TS/TSX source and points at Serena's find_symbol /
# find_referencing_symbols / get_symbols_overview. Grep payloads carry structured
# pattern/path/glob/type fields; Bash payloads carry a raw command line, and the
# Bash detection is intentionally shallow and biased toward ALLOWING: a pipeline,
# a compound/sequenced command, a substitution, a quoted/regex/multi-word
# pattern, a non-TS scope, or a scope it cannot resolve to app/test all pass.
#
# The allow cases deliberately outnumber the block cases: missing a symbol grep
# is cheaper than blocking legitimate shell work, and the ratio here embodies
# that safety posture.
#
# Each test drives the hook exactly as the harness does: a PreToolUse JSON
# payload on stdin, run with the repo as the working directory (the guard uses
# bare `git rev-parse --show-toplevel`). The guard's availability gate needs a
# tsconfig.json in the repo AND a registered `serena` MCP server; setup provides
# both by default (a fresh repo per test, plus a fake HOME whose .claude.json
# registers serena), and individual no-op tests remove one or the other. A fresh
# repo per test also means the block-once cache starts empty every time.

setup() {
  HOOK=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/serena-code-search-guard.sh

  REPO=$(mktemp -d -t serena-guard-repo-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  printf '{}\n' > "$REPO/tsconfig.json"

  # Fake HOME whose ~/.claude.json registers serena as a user-scope MCP server,
  # so the availability gate is satisfied by default.
  FAKEHOME=$(mktemp -d -t serena-guard-home-XXXXXX)
  printf '{"mcpServers":{"serena":{}}}' > "$FAKEHOME/.claude.json"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${FAKEHOME:-}" ] && rm -rf "$FAKEHOME"
  return 0
}

# Build a Grep PreToolUse payload: pattern path glob type [session_id].
mk_grep() {
  jq -nc --arg pat "$1" --arg pth "$2" --arg glb "$3" --arg typ "$4" --arg sid "${5:-s1}" \
    '{tool_name: "Grep", tool_input: {pattern: $pat, path: $pth, glob: $glb, type: $typ}, session_id: $sid}'
}

# Build a Bash PreToolUse payload: command [session_id].
mk_bash() {
  jq -nc --arg c "$1" --arg sid "${2:-s1}" \
    '{tool_name: "Bash", tool_input: {command: $c}, session_id: $sid}'
}

# Pipe $1 (a payload) to the hook from inside the repo. $2 overrides HOME.
run_hook() {
  local payload="$1" home="${2:-$FAKEHOME}"
  run bash -c "cd '$REPO' && printf '%s' '$payload' | HOME='$home' bash '$HOOK'"
}

assert_blocked() {
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ===========================================================================
# Grep matcher: regression-lock the existing structured-field behavior.
# ===========================================================================

@test "grep: bare identifier with no scope narrowing is blocked" {
  run_hook "$(mk_grep 'useBreakpoint' '' '' '')"
  assert_blocked
}

@test "grep: a prose pattern with a space is allowed" {
  run_hook "$(mk_grep 'some phrase' '' '' '')"
  assert_allowed
}

@test "grep: a pattern with regex metacharacters is allowed" {
  run_hook "$(mk_grep 'foo.*bar' '' '' '')"
  assert_allowed
}

@test "grep: a non-TS type filter is allowed" {
  run_hook "$(mk_grep 'useBreakpoint' '' '' 'css')"
  assert_allowed
}

@test "grep: a *.md glob is allowed" {
  run_hook "$(mk_grep 'useBreakpoint' '' '*.md' '')"
  assert_allowed
}

@test "grep: a path outside app/ and test/ is allowed" {
  run_hook "$(mk_grep 'useBreakpoint' 'wiki' '' '')"
  assert_allowed
}

@test "grep: a pattern shorter than 3 chars is allowed" {
  run_hook "$(mk_grep 'ab' '' '' '')"
  assert_allowed
}

@test "grep: block-once - the identical blocked grep re-run within the window passes" {
  local p; p=$(mk_grep 'useBreakpoint' '' '' '' 'sGrepOnce')
  run_hook "$p"
  assert_blocked
  run_hook "$p"
  assert_allowed
}

@test "grep: no tsconfig.json is a no-op (allow)" {
  rm -f "$REPO/tsconfig.json"
  run_hook "$(mk_grep 'useBreakpoint' '' '' '')"
  assert_allowed
}

@test "grep: serena unregistered is a no-op (allow)" {
  local emptyhome; emptyhome=$(mktemp -d -t serena-guard-nohome-XXXXXX)
  run_hook "$(mk_grep 'useBreakpoint' '' '' '')" "$emptyhome"
  rm -rf "$emptyhome"
  assert_allowed
}

# ===========================================================================
# Bash matcher: block a lone bare-identifier grep over app/test TS/TSX.
# ===========================================================================

@test "bash: grep -rn over app/ is blocked" {
  run_hook "$(mk_bash 'grep -rn "useBreakpoint" app/')"
  assert_blocked
}

@test "bash: rg over app/components is blocked" {
  run_hook "$(mk_bash 'rg "handleSubmit" app/components')"
  assert_blocked
}

@test "bash: ag over test/ is blocked" {
  run_hook "$(mk_bash 'ag SomeSymbol test/')"
  assert_blocked
}

@test "bash: grep --include=*.ts over app is blocked" {
  run_hook "$(mk_bash 'grep --include=*.ts -rn "MyType" app')"
  assert_blocked
}

# ===========================================================================
# Bash matcher confounders: all ALLOW (favor false-negatives).
# ===========================================================================

@test "bash: a git-diff pipeline is allowed" {
  run_hook "$(mk_bash 'git diff | grep "foo"')"
  assert_allowed
}

@test "bash: a lint pipeline with context flags is allowed" {
  run_hook "$(mk_bash 'pnpm lint | grep -A2 "warning"')"
  assert_allowed
}

@test "bash: a wiki-lint scan scoped to .claude/ is allowed" {
  run_hook "$(mk_bash 'grep -rn "wiki-lint" .claude/')"
  assert_allowed
}

@test "bash: a playwright-output pipeline is allowed" {
  run_hook "$(mk_bash 'playwright-cli screenshot out.png | grep passed')"
  assert_allowed
}

@test "bash: a path-literal pattern searched in a JSON file is allowed" {
  run_hook "$(mk_bash 'grep -n "app/languages/" manifest.json')"
  assert_allowed
}

@test "bash: a multi-word pattern is allowed" {
  run_hook "$(mk_bash 'grep -rn "some phrase here" app/')"
  assert_allowed
}

@test "bash: a regex-alternation pattern is allowed" {
  run_hook "$(mk_bash 'grep -rEn "foo|bar" app/')"
  assert_allowed
}

@test "bash: a pattern shorter than 3 chars is allowed" {
  run_hook "$(mk_bash 'grep -rn "ab" app/')"
  assert_allowed
}

@test "bash: a scope that is not TS/TSX is allowed" {
  run_hook "$(mk_bash 'grep -rn "useThing" app/foo.md')"
  assert_allowed
}

@test "bash: a compound command is allowed" {
  run_hook "$(mk_bash 'echo useBreakpoint && grep -rn useBreakpoint app/')"
  assert_allowed
}

@test "bash: rg with no resolvable app/test scope is allowed" {
  run_hook "$(mk_bash 'rg useBreakpoint')"
  assert_allowed
}

@test "bash: a non-grep command is allowed" {
  run_hook "$(mk_bash 'ls app/')"
  assert_allowed
}

@test "bash: grep as prose inside a quoted commit message is allowed" {
  run_hook "$(mk_bash 'git commit -m "grep useBreakpoint in app"')"
  assert_allowed
}

# ===========================================================================
# Bash matcher: block-once escape and adopter no-op.
# ===========================================================================

@test "bash: block-once - the identical blocked grep re-run within the window passes" {
  local p; p=$(mk_bash 'grep -rn "useBreakpoint" app/' 'sBashOnce')
  run_hook "$p"
  assert_blocked
  run_hook "$p"
  assert_allowed
}

@test "bash: no tsconfig.json is a no-op (allow)" {
  rm -f "$REPO/tsconfig.json"
  run_hook "$(mk_bash 'grep -rn "useBreakpoint" app/')"
  assert_allowed
}

@test "bash: serena unregistered is a no-op (allow)" {
  local emptyhome; emptyhome=$(mktemp -d -t serena-guard-nohome-XXXXXX)
  run_hook "$(mk_bash 'grep -rn "useBreakpoint" app/')" "$emptyhome"
  rm -rf "$emptyhome"
  assert_allowed
}
