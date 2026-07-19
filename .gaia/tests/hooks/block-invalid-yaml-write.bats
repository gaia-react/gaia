#!/usr/bin/env bats

# Tests for .claude/hooks/block-invalid-yaml-write.sh.
#
# Regression coverage for tech-debt #867: Claude repeatedly authors invalid
# YAML plain scalars (a mid-sentence ": " read as a mapping-key separator, or
# a stray " #" read as a comment that silently truncates the value) and only
# discovers it when a downstream parser or lint fails, sometimes on an
# already-saved artifact. This guard reconstructs the resulting content for
# an Edit/Write/MultiEdit call, extracts the YAML region (the whole file for
# .yml/.yaml, or the --- frontmatter block for .md), and denies the call on
# a real parse failure. It fails open on anything it cannot resolve: no
# python3+pyyaml, a target that doesn't exist yet, or an old_string it can't
# locate in the current file.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-invalid-yaml-write.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
  if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    skip "python3 with pyyaml not available"
  fi
}

teardown() {
  [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR"
  return 0
}

make_workdir() {
  WORKDIR=$(mktemp -d -t gaia-yaml-write-XXXXXX)
}

# Quote-safe delivery (mandatory, mirrors block-worktree-path-mismatch.bats):
# pass $json and $HOOK_ABS as positional args to an inner bash -c rather than
# re-wrapping in an outer single-quoted string, so embedded quotes/newlines in
# a payload never terminate the wrapper early.
run_hook_write() {
  local path="$1" content="$2"
  local json
  json=$(jq -n --arg p "$path" --arg c "$content" '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_edit() {
  local path="$1" old="$2" new="$3"
  local json
  json=$(jq -n --arg p "$path" --arg o "$old" --arg n "$new" '{tool_name: "Edit", tool_input: {file_path: $p, old_string: $o, new_string: $n}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
}

run_hook_multiedit() {
  local path="$1" edits_json="$2"
  local json
  json=$(jq -n --arg p "$path" --argjson e "$edits_json" '{tool_name: "MultiEdit", tool_input: {file_path: $p, edits: $e}}')
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

# --- denied: Write with a genuine YAML parse error ---

@test "Write of a .yaml file with a mid-sentence colon-space plain scalar is denied" {
  make_workdir
  run_hook_write "$WORKDIR/foo.yaml" $'title: fix this: it breaks\n'
  assert_denied
}

@test "Write of a .md file whose frontmatter has an unquoted colon-space value is denied" {
  make_workdir
  run_hook_write "$WORKDIR/foo.md" $'---\ndescription: works in isolation: its guarantees hold\n---\nbody\n'
  assert_denied
}

# --- allowed: Write with valid YAML ---

@test "Write of a .yaml file with a properly quoted colon-space value is allowed" {
  make_workdir
  run_hook_write "$WORKDIR/foo.yaml" $'title: "fix this: it breaks"\n'
  assert_allowed
}

@test "Write of a .md file with valid frontmatter is allowed" {
  make_workdir
  run_hook_write "$WORKDIR/foo.md" $'---\nname: foo\ndescription: a normal description\n---\nbody\n'
  assert_allowed
}

@test "Write of a .md file with no frontmatter at all is allowed" {
  make_workdir
  run_hook_write "$WORKDIR/foo.md" $'# Just a heading\n\nSome prose: with a colon.\n'
  assert_allowed
}

@test "Write of a non-YAML, non-Markdown file is allowed (out of scope)" {
  make_workdir
  run_hook_write "$WORKDIR/foo.ts" $'const x: number = 1;\n'
  assert_allowed
}

# --- fail-open: an internal error never turns into a surprise deny ---

@test "Write overwriting a file containing non-UTF-8 bytes is allowed, not a crash-to-deny" {
  make_workdir
  printf 'title: caf\xe9 time\n' >"$WORKDIR/foo.yaml"
  run_hook_write "$WORKDIR/foo.yaml" $'title: valid\n'
  assert_allowed
}

# --- regression-only: pre-existing brokenness never locks out a file ---

@test "Write that overwrites an already-broken file with still-broken frontmatter is allowed" {
  make_workdir
  printf '%s' $'---\ndescription: works in isolation: its guarantees hold\n---\nold body\n' >"$WORKDIR/foo.md"
  run_hook_write "$WORKDIR/foo.md" $'---\ndescription: works in isolation: its guarantees hold\n---\nnew body\n'
  assert_allowed
}

@test "Edit to the body of a file whose frontmatter is already broken is allowed" {
  make_workdir
  printf '%s' $'---\ndescription: works in isolation: its guarantees hold\n---\nold body\n' >"$WORKDIR/foo.md"
  run_hook_edit "$WORKDIR/foo.md" "old body" "new body, unrelated to the frontmatter"
  assert_allowed
}

# --- Edit: reconstructs resulting content from the on-disk file ---

@test "Edit that introduces an invalid colon-space scalar into frontmatter is denied" {
  make_workdir
  printf '%s' $'---\ndescription: fine\n---\nbody\n' >"$WORKDIR/foo.md"
  run_hook_edit "$WORKDIR/foo.md" "description: fine" "description: works in isolation: its guarantees hold"
  assert_denied
}

@test "Edit that keeps frontmatter valid is allowed" {
  make_workdir
  printf '%s' $'---\ndescription: fine\n---\nbody\n' >"$WORKDIR/foo.md"
  run_hook_edit "$WORKDIR/foo.md" "description: fine" "description: still fine"
  assert_allowed
}

@test "Edit introducing a space-hash comment truncation into a .yaml value is denied" {
  make_workdir
  printf '%s' $'title: sweep\n' >"$WORKDIR/foo.yaml"
  run_hook_edit "$WORKDIR/foo.yaml" "title: sweep" "title: sweep #9"
  assert_denied
}

@test "Edit on a file that does not exist yet fails open (allowed)" {
  make_workdir
  run_hook_edit "$WORKDIR/nope.yaml" "a" "b"
  assert_allowed
}

@test "Edit whose old_string is not found in the current file fails open (allowed)" {
  make_workdir
  printf '%s' $'title: fine\n' >"$WORKDIR/foo.yaml"
  run_hook_edit "$WORKDIR/foo.yaml" "not-present-anywhere" "title: broken: value"
  assert_allowed
}

# --- MultiEdit ---

@test "MultiEdit that introduces an invalid scalar is denied" {
  make_workdir
  printf '%s' $'---\ndescription: fine\nother: ok\n---\nbody\n' >"$WORKDIR/foo.md"
  edits='[{"old_string":"description: fine","new_string":"description: fine"},{"old_string":"other: ok","new_string":"other: works in isolation: its guarantees hold"}]'
  run_hook_multiedit "$WORKDIR/foo.md" "$edits"
  assert_denied
}

@test "MultiEdit that keeps content valid is allowed" {
  make_workdir
  printf '%s' $'---\ndescription: fine\nother: ok\n---\nbody\n' >"$WORKDIR/foo.md"
  edits='[{"old_string":"description: fine","new_string":"description: still fine"},{"old_string":"other: ok","new_string":"other: still ok"}]'
  run_hook_multiedit "$WORKDIR/foo.md" "$edits"
  assert_allowed
}

# --- ignored: not our matcher ---

@test "a Read tool call is ignored" {
  make_workdir
  local json
  json=$(jq -n --arg p "$WORKDIR/foo.yaml" '{tool_name: "Read", tool_input: {file_path: $p}}')
  run bash -c 'printf %s "$1" | bash "$2"' _ "$json" "$HOOK_ABS"
  assert_allowed
}

# --- structural ---

@test "block-invalid-yaml-write.sh is executable" {
  [ -x "$HOOK_ABS" ]
}

@test "settings.json is valid JSON" {
  run jq empty "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}

@test "settings.json registers the hook under the Edit|Write|MultiEdit matcher" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit") | .hooks[] | select(.command == ".claude/hooks/block-invalid-yaml-write.sh")' "$SETTINGS_ABS"
  [ "$status" -eq 0 ]
}
