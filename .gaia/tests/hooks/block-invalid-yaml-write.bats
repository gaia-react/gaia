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

# The hook parses YAML with python3 + PyYAML and fails open without it, so every
# assertion in this file depends on the parser being present. On CI that parser is
# a precondition rather than a maybe: audit-ci-tests.yml installs python3-yaml in
# the same job that runs this suite. So the CI branch FAILS instead of skipping. A
# skip reports `ok ... # skip` and greens the job, so a runner that lost that
# install would retire every test in this file in silence, the hollow guard this
# suite exists to prevent on the hook, turned on the suite itself. The gate test in
# the first section below proves this branch fires. Matches the same-shaped gates in
# .gaia/scripts/tests/retrigger-reachability.bats and .gaia/tests/lib/lint-yaml.bats.
require_yaml_parser() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    # No `::error::` prefix: bats prints a test's stderr prefixed with `# `, and
    # Actions parses a workflow command only at column 0, so the annotation that
    # spelling promises would never render. The `return 1` is what gates.
    echo "no YAML parser (python3 + PyYAML) on a CI runner; every test here would skip to green. Check the apt install in .github/workflows/audit-ci-tests.yml." >&2
    return 1
  fi
  skip "python3 with pyyaml not available"
}

# `require_yaml_parser` is setup()'s last command, so its status is setup()'s: the
# CI branch's `return 1` fails each test individually and attaches its message,
# rather than aborting the run.
setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-invalid-yaml-write.sh"
  SETTINGS_ABS="${HOOKS_SRC%/hooks}/settings.json"
  require_yaml_parser
}

teardown() {
  [ -n "${WORKDIR:-}" ] && rm -rf "$WORKDIR"
  return 0
}

make_workdir() {
  WORKDIR=$(mktemp -d -t gaia-yaml-write-XXXXXX)
}

# Payloads here carry both quotes and newlines, so delivery goes through
# `invoke_hook` (helpers/run-hook.sh) rather than any local variant.
run_hook_write() {
  local path="$1" content="$2"
  local json
  json=$(jq -n --arg p "$path" --arg c "$content" '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}')
  invoke_hook "$json" "$HOOK_ABS"
}

run_hook_edit() {
  local path="$1" old="$2" new="$3"
  local json
  json=$(jq -n --arg p "$path" --arg o "$old" --arg n "$new" '{tool_name: "Edit", tool_input: {file_path: $p, old_string: $o, new_string: $n}}')
  invoke_hook "$json" "$HOOK_ABS"
}

run_hook_multiedit() {
  local path="$1" edits_json="$2"
  local json
  json=$(jq -n --arg p "$path" --argjson e "$edits_json" '{tool_name: "MultiEdit", tool_input: {file_path: $p, edits: $e}}')
  invoke_hook "$json" "$HOOK_ABS"
}



# --- the parser gate itself ---
#
# setup() routes every test in this file through `require_yaml_parser`, which makes
# that one function the single point where all of them can be turned off at once. On
# a CI runner it has to FAIL rather than skip, and nothing else here would notice if
# it stopped: weakening it back to a bare `skip` would red nothing, and a runner that
# lost its python3-yaml install would report `ok ... # skip` for every test and green
# the job. This test is what makes that weakening red. It runs through setup() like
# every other test here, so it cannot escape the gate it covers: what it catches is
# the weakening, not the condition.

@test "the parser gate fails on a CI runner and still skips off CI" {
  local shim="$BATS_TEST_TMPDIR/yaml-write-no-parser" rc
  mkdir -p "$shim"
  # python3 present, but its `import yaml` fails: the shape a runner takes when
  # python3-yaml is dropped from the apt line, not one where python3 is missing
  # outright. The shebang is absolute so the stripped PATH below cannot affect it.
  printf '#!/bin/sh\nexit 1\n' > "$shim/python3"
  chmod +x "$shim/python3"

  # The shim ALONE is a sufficient PATH: the gate runs no command other than
  # `command -v python3` and that python3. Calling the gate in a subshell is what
  # keeps its `skip` arm from marking this test skipped -- bats' `skip` exits 0,
  # so the subshell's status is exactly the discriminator wanted here: non-zero
  # is the CI failure, 0 is the off-CI skip.
  rc=0
  ( PATH="$shim" GITHUB_ACTIONS=true; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the gate skipped on a CI runner with no YAML parser; every test here would report green" >&2
    return 1
  }

  rc=0
  ( PATH="$shim"; unset GITHUB_ACTIONS; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI, where a missing parser must still skip" >&2
    return 1
  }
}

# --- denied: Write with a genuine YAML parse error ---

@test "Write of a .yaml file with a mid-sentence colon-space plain scalar is denied" {
  make_workdir
  run_hook_write "$WORKDIR/foo.yaml" $'title: fix this: it breaks\n'
  assert_denied_by_json
}

@test "Write of a .md file whose frontmatter has an unquoted colon-space value is denied" {
  make_workdir
  run_hook_write "$WORKDIR/foo.md" $'---\ndescription: works in isolation: its guarantees hold\n---\nbody\n'
  assert_denied_by_json
}

# --- allowed: Write with valid YAML ---

@test "Write of a .yaml file with a properly quoted colon-space value is allowed" {
  make_workdir
  run_hook_write "$WORKDIR/foo.yaml" $'title: "fix this: it breaks"\n'
  assert_allowed_by_json
}

@test "Write of a .md file with valid frontmatter is allowed" {
  make_workdir
  run_hook_write "$WORKDIR/foo.md" $'---\nname: foo\ndescription: a normal description\n---\nbody\n'
  assert_allowed_by_json
}

@test "Write of a .md file with no frontmatter at all is allowed" {
  make_workdir
  run_hook_write "$WORKDIR/foo.md" $'# Just a heading\n\nSome prose: with a colon.\n'
  assert_allowed_by_json
}

@test "Write of a non-YAML, non-Markdown file is allowed (out of scope)" {
  make_workdir
  run_hook_write "$WORKDIR/foo.ts" $'const x: number = 1;\n'
  assert_allowed_by_json
}

# --- fail-open: an internal error never turns into a surprise deny ---

@test "Write overwriting a file containing non-UTF-8 bytes is allowed, not a crash-to-deny" {
  make_workdir
  printf 'title: caf\xe9 time\n' >"$WORKDIR/foo.yaml"
  run_hook_write "$WORKDIR/foo.yaml" $'title: valid\n'
  assert_allowed_by_json
}

# --- regression-only: pre-existing brokenness never locks out a file ---

@test "Write that overwrites an already-broken file with still-broken frontmatter is allowed" {
  make_workdir
  printf '%s' $'---\ndescription: works in isolation: its guarantees hold\n---\nold body\n' >"$WORKDIR/foo.md"
  run_hook_write "$WORKDIR/foo.md" $'---\ndescription: works in isolation: its guarantees hold\n---\nnew body\n'
  assert_allowed_by_json
}

@test "Edit to the body of a file whose frontmatter is already broken is allowed" {
  make_workdir
  printf '%s' $'---\ndescription: works in isolation: its guarantees hold\n---\nold body\n' >"$WORKDIR/foo.md"
  run_hook_edit "$WORKDIR/foo.md" "old body" "new body, unrelated to the frontmatter"
  assert_allowed_by_json
}

# --- Edit: reconstructs resulting content from the on-disk file ---

@test "Edit that introduces an invalid colon-space scalar into frontmatter is denied" {
  make_workdir
  printf '%s' $'---\ndescription: fine\n---\nbody\n' >"$WORKDIR/foo.md"
  run_hook_edit "$WORKDIR/foo.md" "description: fine" "description: works in isolation: its guarantees hold"
  assert_denied_by_json
}

@test "Edit that keeps frontmatter valid is allowed" {
  make_workdir
  printf '%s' $'---\ndescription: fine\n---\nbody\n' >"$WORKDIR/foo.md"
  run_hook_edit "$WORKDIR/foo.md" "description: fine" "description: still fine"
  assert_allowed_by_json
}

@test "Edit introducing a space-hash comment truncation into a .yaml value is denied" {
  make_workdir
  printf '%s' $'title: sweep\n' >"$WORKDIR/foo.yaml"
  run_hook_edit "$WORKDIR/foo.yaml" "title: sweep" "title: sweep #9"
  assert_denied_by_json
}

@test "Edit on a file that does not exist yet fails open (allowed)" {
  make_workdir
  run_hook_edit "$WORKDIR/nope.yaml" "a" "b"
  assert_allowed_by_json
}

@test "Edit whose old_string is not found in the current file fails open (allowed)" {
  make_workdir
  printf '%s' $'title: fine\n' >"$WORKDIR/foo.yaml"
  run_hook_edit "$WORKDIR/foo.yaml" "not-present-anywhere" "title: broken: value"
  assert_allowed_by_json
}

# --- MultiEdit ---

@test "MultiEdit that introduces an invalid scalar is denied" {
  make_workdir
  printf '%s' $'---\ndescription: fine\nother: ok\n---\nbody\n' >"$WORKDIR/foo.md"
  edits='[{"old_string":"description: fine","new_string":"description: fine"},{"old_string":"other: ok","new_string":"other: works in isolation: its guarantees hold"}]'
  run_hook_multiedit "$WORKDIR/foo.md" "$edits"
  assert_denied_by_json
}

@test "MultiEdit that keeps content valid is allowed" {
  make_workdir
  printf '%s' $'---\ndescription: fine\nother: ok\n---\nbody\n' >"$WORKDIR/foo.md"
  edits='[{"old_string":"description: fine","new_string":"description: still fine"},{"old_string":"other: ok","new_string":"other: still ok"}]'
  run_hook_multiedit "$WORKDIR/foo.md" "$edits"
  assert_allowed_by_json
}

# --- ignored: not our matcher ---

@test "a Read tool call is ignored" {
  make_workdir
  local json
  json=$(jq -n --arg p "$WORKDIR/foo.yaml" '{tool_name: "Read", tool_input: {file_path: $p}}')
  invoke_hook "$json" "$HOOK_ABS"
  assert_allowed_by_json
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
