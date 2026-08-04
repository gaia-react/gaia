#!/usr/bin/env bats

# Tests for .claude/hooks/block-eslint-config-edit.sh.
#
# The guard protects eslint.config.{js,cjs,mjs,ts} at any path, and it is an
# ALLOWLIST rather than a blocklist: an edit passes only when every line it
# changes is blank, a comment, or a bare `...<name>.<group>` preset spread, and
# only when no preset spread is removed. Everything else is denied, including a
# shape the allowlist has never seen. That direction is the whole guard, so the
# deny cases below carry more weight than the allow cases: a widening that
# admits a `rules:` override, an `ignores:` entry, or a spread deletion has
# hollowed the hook out even while the two allow cases still pass.
#
# The two allow cases are not decoration either. They are the defect the hook
# was filed for (tech-debt #1153): a filename-only deny blocks the
# `...lint.reactRouter` migration the CHANGELOG's Action required tells adopters
# to make, and blocks repairing a stale comment in the config itself.

# shellcheck disable=SC2317
# SC2317 (command appears unreachable) is a structural false positive on every
# @test block: bats invokes each body through its own runner, which the static
# analyzer cannot see. File-wide because the false positive is intrinsic to the
# bats structure rather than to any single test. (Keep the word "shellcheck"
# off the start of a comment line here; it is parsed as a directive there.)

# shellcheck disable=SC2016
# SC2016 (expressions don't expand in single quotes) fires on the `$` inside
# fixture identifiers and on `${...}` inside fixture config bodies. Not
# expanding is the point: a fixture has to reach the hook as the literal text a
# real edit would carry.

setup() {
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-eslint-config-edit.sh"
  TMP=$(mktemp -d "${BATS_TMPDIR:-/tmp}/eslint-hook.XXXXXX")
}

teardown() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  return 0
}

# Quote-safe delivery: fixtures carry quotes of their own, so the JSON payload
# and the hook path go in as positional args rather than being re-wrapped.
run_hook() {
  run bash -c 'printf %s "$1" | bash "$2"' _ "$1" "$HOOK_ABS"
}

edit_payload() {
  jq -n --arg p "$1" --arg o "$2" --arg n "$3" \
    '{tool_name: "Edit", tool_input: {file_path: $p, old_string: $o, new_string: $n}}'
}

run_edit() {
  run_hook "$(edit_payload "$1" "$2" "$3")"
}

run_write() {
  local json
  json=$(jq -n --arg p "$1" --arg c "$2" \
    '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}')
  run_hook "$json"
}

# For the shapes run_edit/run_write cannot express: a MultiEdit's edits[], and
# the malformed payloads whose whole point is a missing field. Takes the
# tool_input as a JSON literal, so a `\n` in a fixture is a real newline by the
# time the hook reads it.
run_tool() {
  run_hook "$(jq -n --arg t "$1" --argjson i "$2" '{tool_name: $t, tool_input: $i}')"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

assert_denied() {
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
}

# --- path gate -------------------------------------------------------------

@test "allows an edit to a file that is not an eslint config" {
  run_edit 'app/routes/home.tsx' 'const a = 1;' "const a = 1;
const b = 2;"
  assert_allowed
}

@test "allows an edit to a lookalike filename" {
  run_edit 'docs/eslint.config.md' 'rules: {}' "rules: {a: 'off'}"
  assert_allowed
}

@test "guards every extension and any depth" {
  for path in eslint.config.js eslint.config.cjs eslint.config.mjs eslint.config.ts \
    apps/web/eslint.config.mjs projects/frontend/nested/eslint.config.ts; do
    run_edit "$path" '...lint.react,' "...lint.react,
rules: {'no-empty-pattern': 'off'},"
    [ "$status" -eq 2 ] || return 1
  done
}

# --- the two allowed shapes ------------------------------------------------

@test "allows the reactRouter migration the CHANGELOG tells adopters to make" {
  run_edit 'eslint.config.mjs' '  ...lint.react,' "  ...lint.react,
  ...lint.reactRouter,"
  assert_allowed
}

@test "allows adding a spread where the anchor line gains a trailing comma" {
  run_edit 'eslint.config.mjs' '  ...lint.react' "  ...lint.react,
  ...lint.reactRouter"
  assert_allowed
}

@test "allows repairing a stale comment" {
  run_edit '.gaia/cli/eslint.config.mjs' \
    ' * playwright, betterTailwind). `react` is spread in only because `base`' \
    ' * playwright, reactRouter, betterTailwind). `react` is spread in only'
  assert_allowed
}

@test "allows a line comment and a block-comment opener" {
  run_edit 'eslint.config.mjs' '  // old note' "  /* new note
   * second line
   */"
  assert_allowed
}

@test "allows a blank-line-only change" {
  run_edit 'eslint.config.mjs' '  ...lint.base,
  ...lint.react,' '  ...lint.base,

  ...lint.react,'
  assert_allowed
}

@test "allows a comment change surrounding an untouched rules block" {
  run_edit 'eslint.config.mjs' "  // why
  rules: {'no-console': 'off'}," "  // why this rule is off
  rules: {'no-console': 'off'},"
  assert_allowed
}

# --- the deny cases, which are the guard -----------------------------------

@test "denies adding a rule override" {
  run_edit 'eslint.config.mjs' '  ...lint.react,' "  ...lint.react,
  rules: {'no-empty-pattern': 'off'},"
  assert_denied
}

@test "denies adding an ignores entry" {
  run_edit 'eslint.config.mjs' '  ...lint.guardrails,' "  ...lint.guardrails,
  ignores: ['app/routes/**'],"
  assert_denied
}

@test "denies removing a preset spread" {
  run_edit 'eslint.config.mjs' '  ...lint.guardrails,
  ...lint.prettier,' '  ...lint.prettier,'
  assert_denied
}

@test "denies commenting out a preset spread" {
  run_edit 'eslint.config.mjs' '  ...lint.guardrails,' '  // ...lint.guardrails,'
  assert_denied
}

@test "denies changing the options of a called preset" {
  run_edit 'eslint.config.mjs' "  ...lint.betterTailwind({
    entryPoint: './app/styles/tailwind.css',
    ignore: ['plain-link'],
  })," "  ...lint.betterTailwind({
    entryPoint: './app/styles/tailwind.css',
    ignore: ['plain-link', 'plain-table'],
  }),"
  assert_denied
}

@test "denies flipping a rule severity even when the line count is unchanged" {
  run_edit 'eslint.config.mjs' "      'sonarjs/no-os-command-from-path': 'error'," \
    "      'sonarjs/no-os-command-from-path': 'off',"
  assert_denied
}

@test "denies a rule override smuggled past a closed block comment" {
  # A comment PREFIX does not make a line a comment: `/* x */` closes the block
  # and everything after it is executable. Confirmed under node that the result
  # is a live rule override, not a curiosity.
  run_edit 'eslint.config.mjs' '  ...lint.react,' "  ...lint.react,
  /* x */ rules: {'no-console': 'off'},"
  assert_denied
}

@test "denies a rule override smuggled past a block comment closed on a // line" {
  # The same vector one prefix over, and the reason the comment arm cannot carve
  # out `//` as unconditionally safe: inside an open block comment a `//` line
  # closes it just as well, and the tail is code.
  run_edit 'eslint.config.mjs' '  ...lint.react,' "  ...lint.react,
  /*
  // */ rules: {'no-console': 'off'},"
  assert_denied
}

@test "denies an ignores entry smuggled past an empty block comment" {
  run_edit 'eslint.config.mjs' '  ...lint.guardrails,' "  ...lint.guardrails,
  /**/ignores: ['app/routes/**'],"
  assert_denied
}

@test "allows a whole-line block comment, which closes but continues with nothing" {
  run_edit 'eslint.config.mjs' '  /* old note */' '  /* new note */'
  assert_allowed
}

@test "denies wrapping a spread in a block comment" {
  # The wrap is the reason a line's own shape is not enough: every line here is
  # either a delimiter or unchanged text, so a purely line-local reading sees no
  # change at all while the spread stops taking effect. This is exactly what the
  # no-spread-removed term exists to refuse.
  run_edit 'eslint.config.mjs' '  ...lint.guardrails,' '  /*
  ...lint.guardrails,
  */'
  assert_denied
}

@test "denies wrapping a spread with a text-carrying opener" {
  # The delimiter lines cannot be recognized by shape alone either: an opener may
  # carry text, which makes it indistinguishable from an ordinary comment.
  run_edit 'eslint.config.mjs' '  ...lint.guardrails,' '  /* note
  ...lint.guardrails,
  */'
  assert_denied
}

@test "denies wrapping a rules block in a block comment" {
  run_edit 'eslint.config.mjs' "  rules: {'no-console': 'off'}," '  /*
  rules: {'"'"'no-console'"'"': '"'"'off'"'"'},
  */'
  assert_denied
}

@test "denies opening a block comment that swallows the lines below it" {
  # Only an opener is added; the closer already exists further down. Nothing is
  # deleted and no line is rewritten, yet everything between them stops running.
  run_edit 'eslint.config.mjs' '  ...lint.guardrails,
   */' '  /* swallow
  ...lint.guardrails,
   */'
  assert_denied
}

@test "denies adding a called preset that carries a rule override" {
  # The vector the bare-spread shape exists to exclude: a call is a spread by
  # eye, and it can carry the literal a bare `...lint.group` cannot. This case
  # is single-line on purpose. A multi-line call is already denied by its own
  # inner lines, and a changed one by the removal rule, so neither discriminates
  # a regex widened to admit calls; only an ADDED single-line call does.
  run_edit 'eslint.config.mjs' '  ...lint.react,' "  ...lint.react,
  ...lint.custom({rules: {'no-empty-pattern': 'off'}}),"
  assert_denied
}

@test "denies a spread carrying an inline object literal" {
  run_edit 'eslint.config.mjs' '  ...lint.react,' "  ...lint.react,
  ...{rules: {'no-empty-pattern': 'off'}},"
  assert_denied
}

@test "denies reindenting a rules block" {
  run_edit 'eslint.config.mjs' "  rules: {'no-console': 'off'}," \
    "    rules: {'no-console': 'off'},"
  assert_denied
}

# --- Write -----------------------------------------------------------------

@test "allows a Write that only changes a comment" {
  printf '%s\n' 'import gaiaLint from "@gaia-react/lint";' '// old note' \
    'export default [...lint.base];' >"$TMP/eslint.config.mjs"
  run_write "$TMP/eslint.config.mjs" 'import gaiaLint from "@gaia-react/lint";
// new note
export default [...lint.base];
'
  assert_allowed
}

@test "denies a Write that adds a rule override" {
  printf '%s\n' 'import gaiaLint from "@gaia-react/lint";' \
    'export default [...lint.base];' >"$TMP/eslint.config.mjs"
  run_write "$TMP/eslint.config.mjs" 'import gaiaLint from "@gaia-react/lint";
export default [...lint.base, {rules: {"no-console": "off"}}];
'
  assert_denied
}

@test "denies a Write that creates a config file from nothing" {
  run_write "$TMP/eslint.config.mjs" 'export default [];
'
  assert_denied
}

# --- MultiEdit, where a filename-only guard must not regress to fail-open ---

@test "allows a MultiEdit whose every pair is comment or added spread" {
  run_tool MultiEdit '{
    "file_path": "eslint.config.mjs",
    "edits": [
      {"old_string": "  // a", "new_string": "  // b"},
      {"old_string": "  ...lint.react,", "new_string": "  ...lint.react,\n  ...lint.reactRouter,"}
    ]
  }'
  assert_allowed
}

@test "denies a MultiEdit when any one pair adds a rule override" {
  run_tool MultiEdit '{
    "file_path": "eslint.config.mjs",
    "edits": [
      {"old_string": "  // a", "new_string": "  // b"},
      {"old_string": "  ...lint.react,", "new_string": "  ...lint.react,\n  rules: {},"}
    ]
  }'
  assert_denied
}

@test "denies a MultiEdit that removes a spread in a later pair" {
  run_tool MultiEdit '{
    "file_path": "eslint.config.mjs",
    "edits": [
      {"old_string": "  // a", "new_string": "  // b"},
      {"old_string": "  ...lint.guardrails,\n  ...lint.prettier,", "new_string": "  ...lint.prettier,"}
    ]
  }'
  assert_denied
}

# --- uncertainty resolves to deny, never to allow --------------------------

@test "denies a tool shape it cannot read on a guarded path" {
  run_tool NotebookEdit '{"file_path": "eslint.config.mjs"}'
  assert_denied
}

@test "denies an Edit on a guarded path with no strings to compare" {
  run_tool Edit '{"file_path": "eslint.config.mjs"}'
  assert_denied
}

@test "denies a MultiEdit on a guarded path with an empty edits array" {
  run_tool MultiEdit '{"file_path": "eslint.config.mjs", "edits": []}'
  assert_denied
}

@test "allows an unreadable payload, matching the pre-existing path gate" {
  run_hook 'not json at all'
  assert_allowed
}

# --- the message states what is enforced -----------------------------------

@test "the deny message names both allowed shapes and the by-hand path" {
  run_edit 'eslint.config.mjs' '  ...lint.react,' "  ...lint.react,
  rules: {},"
  [ "$status" -eq 2 ]
  grep -qF -- 'comment' <<<"$output"
  grep -qF -- 'spread' <<<"$output"
  grep -qF -- 'by hand' <<<"$output"
}
