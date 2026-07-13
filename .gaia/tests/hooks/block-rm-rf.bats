#!/usr/bin/env bats

# Tests for .claude/hooks/block-rm-rf.sh.
#
# The guard denies the well-known `rm -rf` footguns (root, $HOME / ~, cwd,
# unscoped glob, .git, node_modules, --no-preserve-root) while letting the
# whitelisted scratch paths and unknown relative paths through. It is
# best-effort defense-in-depth, not airtight: it always exits 0, carrying the
# allow/deny decision in stdout JSON, and broader policy lives in
# settings.json permissions.
#
# The quoting axis is the point of this suite. `read -r -a` word-splits but
# does not remove quote characters, so a target must be matched with its
# quotes stripped: `rm -rf "$HOME"` is the *careful* way to write the
# expansion and has to be denied exactly like the bare `rm -rf $HOME`. Each
# dangerous target is therefore asserted in three shapes, bare, double-quoted,
# and single-quoted, plus the partially-quoted `"$HOME"/projects` form where
# the quotes sit inside the token rather than around it.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-rm-rf.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
}

# Quote-safe delivery (mandatory): every payload here is about quoting, so the
# command text must reach the hook byte-for-byte. Passing $json and $HOME_ABS
# as positional args means no outer re-quoting can strip the inner quotes
# under test. Payloads are written in single quotes so `$HOME` stays the
# literal 5-character string the guard must match, never this machine's home.
run_hook_bash() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

assert_denied() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}

# --- denied: bare targets ---

@test "rm -rf / is denied" {
  run_hook_bash 'rm -rf /'
  assert_denied
}

@test "rm -rf \$HOME is denied" {
  run_hook_bash 'rm -rf $HOME'
  assert_denied
}

@test "rm -rf ~ is denied" {
  run_hook_bash 'rm -rf ~'
  assert_denied
}

@test "rm -rf ~/ is denied" {
  run_hook_bash 'rm -rf ~/'
  assert_denied
}

@test "rm -rf \$HOME/projects is denied" {
  run_hook_bash 'rm -rf $HOME/projects'
  assert_denied
}

@test "rm -rf . is denied" {
  run_hook_bash 'rm -rf .'
  assert_denied
}

@test "rm -rf * is denied" {
  run_hook_bash 'rm -rf *'
  assert_denied
}

@test "rm -rf .git is denied" {
  run_hook_bash 'rm -rf .git'
  assert_denied
}

@test "rm -rf node_modules is denied" {
  run_hook_bash 'rm -rf node_modules'
  assert_denied
}

@test "rm -fr / (reversed flags) is denied" {
  run_hook_bash 'rm -fr /'
  assert_denied
}

@test "rm --no-preserve-root -rf / is denied" {
  run_hook_bash 'rm --no-preserve-root -rf /'
  assert_denied
}

# --- denied: double-quoted targets ---
#
# Quoting the expansion is the correct, careful shell idiom, and it is exactly
# the shape a quote-blind guard misses. These must deny identically to the
# bare forms above.

@test "rm -rf \"\$HOME\" (quoted) is denied" {
  run_hook_bash 'rm -rf "$HOME"'
  assert_denied
}

@test "rm -rf \"/\" (quoted) is denied" {
  run_hook_bash 'rm -rf "/"'
  assert_denied
}

@test "rm -rf \".\" (quoted) is denied" {
  run_hook_bash 'rm -rf "."'
  assert_denied
}

@test "rm -rf \"*\" (quoted) is denied" {
  run_hook_bash 'rm -rf "*"'
  assert_denied
}

@test "rm -rf \"~\" (quoted) is denied" {
  run_hook_bash 'rm -rf "~"'
  assert_denied
}

@test "rm -rf \".git\" (quoted) is denied" {
  run_hook_bash 'rm -rf ".git"'
  assert_denied
}

@test "rm -rf \"node_modules\" (quoted) is denied" {
  run_hook_bash 'rm -rf "node_modules"'
  assert_denied
}

@test "rm -rf \"\$HOME/projects\" (fully quoted path) is denied" {
  run_hook_bash 'rm -rf "$HOME/projects"'
  assert_denied
}

@test "rm -rf \"\$HOME\"/projects (quotes inside the token) is denied" {
  # Quoting only the expansion and leaving the rest bare is just as idiomatic,
  # and leaves the quote characters mid-token rather than surrounding it.
  run_hook_bash 'rm -rf "$HOME"/projects'
  assert_denied
}

# --- denied: single-quoted targets ---

@test "rm -rf '\$HOME' (single-quoted) is denied" {
  run_hook_bash "rm -rf '\$HOME'"
  assert_denied
}

@test "rm -rf '/' (single-quoted) is denied" {
  run_hook_bash "rm -rf '/'"
  assert_denied
}

@test "rm -rf '.git' (single-quoted) is denied" {
  run_hook_bash "rm -rf '.git'"
  assert_denied
}

# --- denied: the ${HOME} brace form ---
#
# `${HOME}` is, if anything, the more deliberate spelling of the expansion, so
# omitting it reproduces the very bug this suite exists to lock down: the guard
# catching the casual form and missing the careful one.

@test "rm -rf \${HOME} (brace form) is denied" {
  run_hook_bash 'rm -rf ${HOME}'
  assert_denied
}

@test "rm -rf \"\${HOME}\" (quoted brace form) is denied" {
  run_hook_bash 'rm -rf "${HOME}"'
  assert_denied
}

@test "rm -rf \"\${HOME}/projects\" (quoted brace path) is denied" {
  run_hook_bash 'rm -rf "${HOME}/projects"'
  assert_denied
}

@test "rm -rf \${HOME}/.config (brace path) is denied" {
  run_hook_bash 'rm -rf ${HOME}/.config'
  assert_denied
}

# --- denied: a dangerous target in a non-first rm segment ---
#
# `rm -rf node_modules && rm -rf dist` is an ordinary cleanup chain, so a guard
# that inspects only the first rm segment lets a dangerous target ride behind a
# harmless one.

@test "a dangerous target in the second rm segment (&&) is denied" {
  run_hook_bash 'rm -rf dist && rm -rf /'
  assert_denied
}

@test "a dangerous target in the second rm segment (;) is denied" {
  run_hook_bash 'rm -rf dist ; rm -rf ~'
  assert_denied
}

@test "a dangerous target in the second rm segment (||) is denied" {
  run_hook_bash 'rm -rf dist || rm -rf .git'
  assert_denied
}

@test "a dangerous target in the third rm segment is denied" {
  run_hook_bash 'cd /tmp && rm -rf build && rm -rf $HOME'
  assert_denied
}

# --- denied: operand-first flag order ---
#
# GNU getopt permutes argv, so `rm $HOME -rf` is exactly `rm -rf $HOME` and
# deletes home on Linux. BSD/macOS rm does not permute, which is why this shape
# looks harmless when hand-tested on a Mac and must be covered by the suite.

@test "rm \$HOME -rf (operand before flags) is denied" {
  run_hook_bash 'rm $HOME -rf'
  assert_denied
}

@test "rm .git -rf (operand before flags) is denied" {
  run_hook_bash 'rm .git -rf'
  assert_denied
}

@test "rm ~ -rf (operand before flags) is denied" {
  run_hook_bash 'rm ~ -rf'
  assert_denied
}

# --- allowed: whitelisted scratch paths ---

@test "rm -rf .gaia/local/plans/x is allowed" {
  run_hook_bash 'rm -rf .gaia/local/plans/x'
  assert_allowed
}

@test "rm -rf .gaia/local/cache/x is allowed" {
  run_hook_bash 'rm -rf .gaia/local/cache/x'
  assert_allowed
}

@test "rm -rf dist is allowed" {
  run_hook_bash 'rm -rf dist'
  assert_allowed
}

@test "rm -rf build/output is allowed" {
  run_hook_bash 'rm -rf build/output'
  assert_allowed
}

@test "rm -rf \"dist\" (quoted whitelist entry) is allowed" {
  # Quote-stripping must not turn a benign quoted target into a denial.
  run_hook_bash 'rm -rf "dist"'
  assert_allowed
}

@test "rm -rf ./\"dist\" (quotes inside a benign token) is allowed" {
  run_hook_bash 'rm -rf ./"dist"'
  assert_allowed
}

# --- allowed: everything the guard deliberately does not gate ---

@test "rm -rf on an unknown relative path is allowed" {
  run_hook_bash 'rm -rf some/scratch/dir'
  assert_allowed
}

@test "rm -rf on an unrelated quoted variable is allowed" {
  run_hook_bash 'rm -rf "$SCRATCH_DIR"'
  assert_allowed
}

@test "rm -rf \${HOMEBREW_PREFIX} (a \$HOME-prefixed neighbour) is allowed" {
  # The brace arms must be anchored, not prefix matches: a variable whose name
  # merely starts with HOME is not $HOME.
  run_hook_bash 'rm -rf ${HOMEBREW_PREFIX}'
  assert_allowed
}

@test "rm -rf \${PWD}/dist (an unrelated brace variable) is allowed" {
  run_hook_bash 'rm -rf ${PWD}/dist'
  assert_allowed
}

@test "a benign multi-segment rm chain is allowed" {
  # Inspecting every segment must not turn an ordinary cleanup chain into a deny.
  run_hook_bash 'rm -rf dist && rm -rf build/output'
  assert_allowed
}

@test "rm -rf node_modules_backup (a node_modules-prefixed neighbour) is allowed" {
  run_hook_bash 'rm -rf node_modules_backup'
  assert_allowed
}

@test "rm without -rf is allowed" {
  run_hook_bash 'rm file.txt'
  assert_allowed
}

@test "a command with no rm at all is allowed" {
  run_hook_bash 'ls -la node_modules'
  assert_allowed
}

# --- structural ---

@test "block-rm-rf.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json registers the hook under the Bash matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command == ".claude/hooks/block-rm-rf.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
