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

# Asserts the deny fired for the *stated* reason, not merely that some deny
# fired. Without this, a target denied by the wrong case arm (say, `$HOME`
# caught by the absolute-path arm) still reads as a pass.
assert_denied_because() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
  grep -qF -- "$1" <<<"$output"
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

# --- denied: backslash-newline continuations ---
#
# Both greps in the hook are line-oriented, so a target parked on a continuation
# line carries no `rm` token of its own and, unspliced, is never extracted. The
# multi-line form is idiomatic and the target is a plain literal token, so it
# must deny exactly like the one-liner it is equivalent to.

@test "a continuation-line \$HOME target is denied" {
  run_hook_bash 'rm -rf \
  $HOME/.cache/foo'
  assert_denied
}

@test "a continuation-line root target is denied" {
  run_hook_bash 'rm -rf \
  /'
  assert_denied
}

@test "a continuation-line quoted brace target is denied" {
  run_hook_bash 'rm -rf \
  "${HOME}"'
  assert_denied
}

@test "a continuation split between rm and its flags is denied" {
  run_hook_bash 'rm \
  -rf /'
  assert_denied
}

@test "a benign continuation-line cleanup is allowed" {
  # Splicing continuations must not turn an ordinary multi-line cleanup into a deny.
  run_hook_bash 'rm -rf \
  dist \
  build/output'
  assert_allowed
}

# A continuation may split a token mid-word. Bash removes the backslash-newline
# with nothing, so the fragments reassemble into one token and the command runs
# against the reassembled target. The splice must join the same way: a space-join
# would cut the token into fragments that match no pattern, which is a bypass.

@test "a continuation splitting \$HOME mid-token is denied" {
  run_hook_bash 'rm -rf $HOM\
E'
  assert_denied
}

@test "a continuation splitting a quoted \$HOME mid-token is denied" {
  run_hook_bash 'rm -rf "$HO\
ME"'
  assert_denied
}

@test "a continuation splitting node_modules mid-token is denied" {
  run_hook_bash 'rm -rf node_modul\
es'
  assert_denied
}

@test "a continuation splitting .git mid-token is denied" {
  run_hook_bash 'rm -rf .gi\
t'
  assert_denied
}

# --- denied: backslash-escaped targets ---
#
# Bash strips a backslash before an ordinary character, so the escaped token
# reassembles into the dangerous one and rm receives the real target. Stripping
# quotes but not escapes would be half a fix.

@test "rm -rf \\\\/ (escaped root) is denied" {
  run_hook_bash 'rm -rf \/'
  assert_denied_because 'rm -rf of absolute path'
}

@test "rm -rf \\\\.git (escaped .git) is denied" {
  run_hook_bash 'rm -rf \.git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "rm -rf .\\\\git (escape inside the token) is denied" {
  run_hook_bash 'rm -rf .\git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "rm -rf \\\\node_modules (escaped node_modules) is denied" {
  run_hook_bash 'rm -rf \node_modules'
  assert_denied_because 'BLOCKED: rm -rf of node_modules is forbidden'
}

@test "rm -rf \\\\\$HOME denies, though it is a fail-safe false deny, not a closed hole" {
  # Honest framing: bash hands rm a file literally NAMED '$HOME' here, not the
  # home directory, so this shape was never dangerous. It denies, which fails
  # safe, and that is all this asserts. Unlike its four siblings above it does
  # NOT gate the backslash strip: the legacy '\$HOME' case arm catches the raw
  # token even with the strip deleted. Kept as a behavior lock, not as evidence
  # the strip works.
  run_hook_bash 'rm -rf \$HOME'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

# --- denied: remaining flag-shape gaps ---

@test "rm --no-preserve-root / (no recursive flag) is denied" {
  # The bare form carries no -r/-f at all, so only the widened short-circuit
  # reaches it. The -rf variant above does not cover this path.
  run_hook_bash 'rm --no-preserve-root /'
  assert_denied
}

@test "rm \${HOME} -rf (brace form, operand first) is denied" {
  run_hook_bash 'rm ${HOME} -rf'
  assert_denied
}

# --- denied: for the right reason ---
#
# assert_denied alone cannot tell a correct deny from a deny by the wrong arm.

@test "\$HOME denies via the \$HOME arm, not the absolute-path arm" {
  run_hook_bash 'rm -rf "$HOME"'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "\${HOME} denies via the \$HOME arm" {
  run_hook_bash 'rm -rf "${HOME}"'
  assert_denied_because 'BLOCKED: rm -rf of $HOME / ~ is forbidden.'
}

@test "/ denies via the absolute-path arm" {
  run_hook_bash 'rm -rf /'
  assert_denied_because 'rm -rf of absolute path'
}

@test ". denies via the cwd arm" {
  run_hook_bash 'rm -rf "."'
  assert_denied_because "BLOCKED: rm -rf of cwd ('.') is forbidden."
}

@test ".git denies via the .git arm" {
  run_hook_bash 'rm -rf ".git"'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
}

@test "node_modules denies via the node_modules arm" {
  run_hook_bash 'rm -rf "node_modules"'
  assert_denied_because 'BLOCKED: rm -rf of node_modules is forbidden'
}

@test "--no-preserve-root denies via its own arm" {
  run_hook_bash 'rm --no-preserve-root -rf /'
  assert_denied_because 'BLOCKED: rm with --no-preserve-root is forbidden.'
}

@test "a chained dangerous segment denies via the target's own arm" {
  # Proves the second segment is what fired, not an accidental match on the first.
  run_hook_bash 'rm -rf dist && rm -rf .git'
  assert_denied_because 'BLOCKED: rm -rf of .git is forbidden.'
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
