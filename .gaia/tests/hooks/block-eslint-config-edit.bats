#!/usr/bin/env bats

# Tests for .claude/hooks/block-eslint-config-edit.sh.
#
# The guard protects eslint.config.{js,cjs,mjs,ts} at any path, and it is an
# ALLOWLIST rather than a blocklist: blank lines and comments change freely, a
# bare `...<name>.<group>` preset spread may be added anywhere, and nothing else
# is added while nothing at all is removed, altered, or reordered. Everything
# else is denied, including a shape the allowlist has never seen. That direction
# is the whole guard, so the deny cases below carry more weight than the allow
# cases: a widening that admits a `rules:` override, an `ignores:` entry, a
# spread deletion, or a spread MOVE has hollowed the hook out even while the two
# allow cases still pass.
#
# The two allow cases are not decoration either. They are the defect the hook
# was filed for (tech-debt #1153): a filename-only deny blocks the
# `...lint.reactRouter` migration the CHANGELOG's Action required tells adopters
# to make, and blocks repairing a stale comment in the config itself.
#
# **Every content test runs against a real file on disk**, and that is
# load-bearing rather than tidiness. The hook judges whole files: an Edit's
# old_string/new_string are a fragment whose boundaries the caller picks, and
# comment state is a property of the file, so a suite that fed bare fragments
# could only ever test the arrangements it happened to choose. The split-wrap
# tests below are the cases that shortcut hid.

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

# A realistic config: a header block comment, bare spreads, a called preset, and
# an overrides object with a rules block. Every fixture below edits this.
DEFAULT_BODY="import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';

/*
 * Config for the app. It OMITS the presets the app does not use
 * (storybook, playwright, betterTailwind).
 */
const lint = gaiaLint();

export default defineConfig([
  ...lint.ignores({extra: ['dist/**']}),
  ...lint.base,
  ...lint.react,
  ...lint.guardrails,
  ...lint.prettier,
  {
    name: 'app/overrides',
    // why this rule is off
    rules: {'no-console': 'off'},
  },
]);"

# Writes a config to the temp dir and echoes its path. Takes an optional body.
cfg() {
  local name="${2:-eslint.config.mjs}"
  printf '%s\n' "${1:-$DEFAULT_BODY}" >"$TMP/$name"
  printf '%s' "$TMP/$name"
}

# Quote-safe delivery: fixtures carry quotes of their own, so the JSON payload
# and the hook path go in as positional args rather than being re-wrapped.
run_hook() {
  run bash -c 'printf %s "$1" | bash "$2"' _ "$1" "$HOOK_ABS"
}

run_edit() {
  run_hook "$(jq -n --arg p "$1" --arg o "$2" --arg n "$3" \
    '{tool_name: "Edit", tool_input: {file_path: $p, old_string: $o, new_string: $n}}')"
}

run_write() {
  run_hook "$(jq -n --arg p "$1" --arg c "$2" \
    '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}')"
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
  run_edit "$(cfg 'const a = 1;' 'home.tsx')" 'const a = 1;' 'const a = 2;'
  assert_allowed
}

@test "allows an edit to a lookalike filename" {
  run_edit "$(cfg 'rules: {}' 'eslint.config.md')" 'rules: {}' "rules: {a: 'off'}"
  assert_allowed
}

@test "guards every extension and any depth" {
  mkdir -p "$TMP/apps/web"
  for name in eslint.config.js eslint.config.cjs eslint.config.mjs eslint.config.ts \
    apps/web/eslint.config.mjs; do
    run_edit "$(cfg "$DEFAULT_BODY" "$name")" '  ...lint.react,' "  ...lint.react,
  rules: {'no-empty-pattern': 'off'},"
    [ "$status" -eq 2 ] || return 1
  done
}

# --- the two allowed shapes ------------------------------------------------

@test "allows the reactRouter migration the CHANGELOG tells adopters to make" {
  run_edit "$(cfg)" '  ...lint.react,' "  ...lint.react,
  ...lint.reactRouter,"
  assert_allowed
}

@test "allows adding a spread where the anchor line gains a trailing comma" {
  run_edit "$(cfg)" '  ...lint.react' "  ...lint.react,
  ...lint.reactRouter"
  assert_allowed
}

@test "allows repairing a stale comment" {
  run_edit "$(cfg)" ' * (storybook, playwright, betterTailwind).' \
    ' * (storybook, playwright, reactRouter, betterTailwind).'
  assert_allowed
}

@test "allows turning a line comment into a block comment" {
  run_edit "$(cfg)" '    // why this rule is off' "    /* why this rule is off
     * and when to revisit it
     */"
  assert_allowed
}

@test "allows the migration on a config carrying a glob that contains a slash-star" {
  # `['dist/**']` and `['.gaia/**']` both contain the two characters that open a
  # block comment. Reading those as openers puts the rest of the file inside a
  # phantom comment and denies the migration this hook exists to allow, on the
  # exact config that motivated it. DEFAULT_BODY carries such a glob on purpose;
  # this test pins the reason.
  run_edit "$(cfg)" '  ...lint.react,' "  ...lint.react,
  ...lint.reactRouter,"
  assert_allowed
  grep -qF -- "dist/**" "$TMP/eslint.config.mjs"
}

@test "allows a blank-line-only change" {
  run_edit "$(cfg)" '  ...lint.base,
  ...lint.react,' '  ...lint.base,

  ...lint.react,'
  assert_allowed
}

@test "allows a comment change surrounding an untouched rules block" {
  run_edit "$(cfg)" '    // why this rule is off' '    // why this rule is off, see #123'
  assert_allowed
}

@test "allows editing a whole-line block comment" {
  run_edit "$(cfg)" '  ...lint.base,' '  /* base first */
  ...lint.base,'
  assert_allowed
}

# --- the deny cases, which are the guard -----------------------------------

@test "denies adding a rule override" {
  run_edit "$(cfg)" '  ...lint.react,' "  ...lint.react,
  rules: {'no-empty-pattern': 'off'},"
  assert_denied
}

@test "denies adding an ignores entry" {
  run_edit "$(cfg)" '  ...lint.guardrails,' "  ...lint.guardrails,
  ignores: ['app/routes/**'],"
  assert_denied
}

@test "denies removing a preset spread" {
  run_edit "$(cfg)" '  ...lint.guardrails,
' ''
  assert_denied
}

@test "denies commenting out a preset spread" {
  run_edit "$(cfg)" '  ...lint.guardrails,' '  // ...lint.guardrails,'
  assert_denied
}

@test "denies changing the options of a called preset" {
  run_edit "$(cfg)" "  ...lint.ignores({extra: ['dist/**']})," \
    "  ...lint.ignores({extra: ['dist/**', 'app/routes/**']}),"
  assert_denied
}

@test "denies flipping a rule severity even when the line count is unchanged" {
  run_edit "$(cfg)" "    rules: {'no-console': 'off'}," "    rules: {'no-console': 'error'},"
  assert_denied
}

@test "denies a spread carrying an inline object literal" {
  run_edit "$(cfg)" '  ...lint.react,' "  ...lint.react,
  ...{rules: {'no-empty-pattern': 'off'}},"
  assert_denied
}

@test "denies adding a called preset that carries a rule override" {
  # The vector the bare-spread shape exists to exclude: a call is a spread by
  # eye, and it can carry the literal a bare `...lint.group` cannot. Single-line
  # on purpose. A multi-line call is already denied by its own inner lines, and a
  # changed one by the removal rule, so neither discriminates a regex widened to
  # admit calls; only an ADDED single-line call does.
  run_edit "$(cfg)" '  ...lint.react,' "  ...lint.react,
  ...lint.custom({rules: {'no-empty-pattern': 'off'}}),"
  assert_denied
}

@test "denies reindenting a rules block" {
  run_edit "$(cfg)" "    rules: {'no-console': 'off'}," "      rules: {'no-console': 'off'},"
  assert_denied
}

# --- a comment prefix does not make a line a comment -----------------------

@test "denies a rule override smuggled past a closed block comment" {
  # `/* x */` closes the block and everything after it is executable.
  run_edit "$(cfg)" '  ...lint.react,' "  ...lint.react,
  /* x */ rules: {'no-console': 'off'},"
  assert_denied
}

@test "denies a rule override smuggled past a block comment closed on a // line" {
  # The same vector one prefix over, and the reason the comment arm cannot carve
  # out `//` as unconditionally safe: inside an open block comment a `//` line
  # closes it just as well, and the tail is code.
  run_edit "$(cfg)" '  ...lint.react,' "  ...lint.react,
  /*
  // */ rules: {'no-console': 'off'},"
  assert_denied
}

@test "denies an ignores entry smuggled past an empty block comment" {
  run_edit "$(cfg)" '  ...lint.guardrails,' "  ...lint.guardrails,
  /**/ignores: ['app/routes/**'],"
  assert_denied
}

# --- wrapping, where the line-local reading runs out -----------------------

@test "denies wrapping a spread in a block comment" {
  # Every line here is a delimiter or unchanged text, so nothing about any single
  # line changed while the preset stopped taking effect.
  run_edit "$(cfg)" '  ...lint.guardrails,' '  /*
  ...lint.guardrails,
  */'
  assert_denied
}

@test "denies wrapping a spread with a text-carrying opener" {
  # The delimiters cannot be recognized by shape alone: an opener may carry text,
  # which makes it indistinguishable from an ordinary comment.
  run_edit "$(cfg)" '  ...lint.guardrails,' '  /* note
  ...lint.guardrails,
  */'
  assert_denied
}

@test "denies wrapping a rules block in a block comment" {
  run_edit "$(cfg)" "    rules: {'no-console': 'off'}," "    /*
    rules: {'no-console': 'off'},
    */"
  assert_denied
}

@test "denies appending a lone block-comment opener" {
  # The split wrap's first half, and the case a fragment-level reading could not
  # see: the fragment ends at the delimiter, so on its own it reads as a pure
  # comment line. Against the whole file it swallows everything below it.
  run_edit "$(cfg)" '  ...lint.base,' '  ...lint.base,
  /*'
  assert_denied
}

@test "denies a MultiEdit that splits a wrap across two pairs" {
  # Neither pair looks like anything on its own. Together they comment out a
  # preset. This is the composition a per-pair reading admitted.
  local p; p="$(cfg)"
  run_tool MultiEdit "$(jq -n --arg p "$p" '{
    file_path: $p,
    edits: [
      {old_string: "  ...lint.base,", new_string: "  ...lint.base,\n  /*"},
      {old_string: "  ...lint.guardrails,", new_string: "  ...lint.guardrails,\n  */"}
    ]
  }')"
  assert_denied
}

@test "denies an edit whose new_string drops the trailing newline onto the next line" {
  # The reconstruction has to model what the tool writes, and the tool glues
  # new_string's last line onto whatever followed old_string. Here old_string
  # ends in a newline and new_string does not, so `  //` does not stay a line of
  # its own: it prefixes the spread below and comments it out. Both strings must
  # therefore survive with their trailing newlines intact.
  run_edit "$(cfg)" '  ...lint.base,
' '  ...lint.base,
  //'
  assert_denied
}

@test "denies moving an existing block-comment closer down past effective code" {
  # Nothing is added or deleted; a closer simply moves, and a line that was
  # running stops running.
  run_edit "$(cfg)" ' */
const lint = gaiaLint();' 'const lint = gaiaLint();
 */'
  assert_denied
}

# --- order is precedence, so a move is a change ----------------------------
#
# Later spreads win. Groups in `@gaia-react/lint` overlap heavily (`base` and
# `prettier` share 155 rule ids, most at different severities), so reordering two
# of them silences rules that are on today, which is the thing this guard
# exists to refuse. None of these three adds, removes, or alters a line: they are
# invisible to any comparison that checks the non-spread lines for equality and
# the spreads for removal, and that is why all three are here.

@test "denies swapping two adjacent preset spreads" {
  run_edit "$(cfg)" '  ...lint.guardrails,
  ...lint.prettier,' '  ...lint.prettier,
  ...lint.guardrails,'
  assert_denied
}

@test "denies swapping two preset spreads with others between them" {
  run_edit "$(cfg)" '  ...lint.base,
  ...lint.react,
  ...lint.guardrails,
  ...lint.prettier,' '  ...lint.prettier,
  ...lint.react,
  ...lint.guardrails,
  ...lint.base,'
  assert_denied
}

@test "denies moving a preset spread across a line that is not a spread" {
  # The vector a swap-only reading misses: nothing swaps, one spread hoists past
  # the called preset above it. The non-spread lines keep their own order, and the
  # set of spreads is untouched, so only a comparison that reads both together in
  # one order sees it.
  run_edit "$(cfg)" "  ...lint.ignores({extra: ['dist/**']}),
  ...lint.base,
  ...lint.react,
  ...lint.guardrails,
  ...lint.prettier," "  ...lint.prettier,
  ...lint.ignores({extra: ['dist/**']}),
  ...lint.base,
  ...lint.react,
  ...lint.guardrails,"
  assert_denied
}

# --- Write -----------------------------------------------------------------

@test "allows a Write that only changes a comment" {
  local p; p="$(cfg)"
  run_write "$p" "${DEFAULT_BODY/Config for the app./Config for this app.}"
  assert_allowed
}

@test "denies a Write that adds a rule override" {
  local p; p="$(cfg)"
  run_write "$p" "${DEFAULT_BODY/  ...lint.prettier,/  ...lint.prettier,
  {rules: {\'no-console\': \'off\'}},}"
  assert_denied
}

@test "denies a Write that truncates the config to its header" {
  # The one shape that reaches the "every before line is accounted for" half of
  # the comparison on its own: nothing is added, so no after line is left over to
  # judge, and the whole body simply stops existing. Every other deny case in this
  # suite leaves something behind that fails the other half first, which is why
  # this fixture is here rather than folded into one of them.
  local p; p="$(cfg)"
  run_write "$p" "import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';

const lint = gaiaLint();
"
  assert_denied
}

@test "denies a Write whose target exists but cannot be read" {
  # The Edit and MultiEdit arms refuse an unreadable target rather than judging
  # against a baseline they never read; the Write arm has to do the same, or an
  # empty baseline makes every line of the replacement look added, and content
  # that is nothing but comments and spreads passes while really replacing a whole
  # config. A directory is the deterministic unreadable target: `chmod 000` is not
  # one when the suite runs as root.
  mkdir -p "$TMP/eslint.config.mjs"
  run_write "$TMP/eslint.config.mjs" '// replaced
  ...lint.base,'
  assert_denied
}

@test "denies a Write that creates a config file from nothing" {
  run_write "$TMP/eslint.config.mjs" 'export default [];
'
  assert_denied
}

# --- MultiEdit -------------------------------------------------------------

@test "allows a MultiEdit whose every pair is comment or added spread" {
  local p; p="$(cfg)"
  run_tool MultiEdit "$(jq -n --arg p "$p" '{
    file_path: $p,
    edits: [
      {old_string: "    // why this rule is off", new_string: "    // why it is off"},
      {old_string: "  ...lint.react,", new_string: "  ...lint.react,\n  ...lint.reactRouter,"}
    ]
  }')"
  assert_allowed
}

@test "denies a MultiEdit when any one pair adds a rule override" {
  local p; p="$(cfg)"
  run_tool MultiEdit "$(jq -n --arg p "$p" '{
    file_path: $p,
    edits: [
      {old_string: "    // why this rule is off", new_string: "    // why it is off"},
      {old_string: "  ...lint.react,", new_string: "  ...lint.react,\n  rules: {},"}
    ]
  }')"
  assert_denied
}

@test "denies a MultiEdit that removes a spread in a later pair" {
  local p; p="$(cfg)"
  run_tool MultiEdit "$(jq -n --arg p "$p" '{
    file_path: $p,
    edits: [
      {old_string: "    // why this rule is off", new_string: "    // why it is off"},
      {old_string: "  ...lint.guardrails,\n", new_string: ""}
    ]
  }')"
  assert_denied
}

# --- uncertainty resolves to deny, never to allow --------------------------

@test "denies a tool shape it cannot read on a guarded path" {
  run_tool NotebookEdit "$(jq -n --arg p "$(cfg)" '{file_path: $p}')"
  assert_denied
}

@test "denies an Edit on a guarded path with no strings to compare" {
  run_tool Edit "$(jq -n --arg p "$(cfg)" '{file_path: $p}')"
  assert_denied
}

@test "denies a MultiEdit on a guarded path with an empty edits array" {
  run_tool MultiEdit "$(jq -n --arg p "$(cfg)" '{file_path: $p, edits: []}')"
  assert_denied
}

@test "denies an Edit whose replaced text is not in the file" {
  run_edit "$(cfg)" '  ...lint.doesNotExist,' '  ...lint.doesNotExist,
  ...lint.reactRouter,'
  assert_denied
}

@test "denies an Edit whose replaced text appears more than once" {
  # The edit tools enforce this uniqueness themselves; the guard cannot establish
  # which occurrence would move, so it refuses rather than guessing.
  run_edit "$(cfg 'export default [
  ...lint.base,
  // marker
  ...lint.react,
  // marker
];')" '  // marker' '  // marker two'
  assert_denied
}

@test "denies an Edit on a guarded path whose file does not exist" {
  run_edit "$TMP/eslint.config.mjs" '  ...lint.react,' '  ...lint.react,
  ...lint.reactRouter,'
  assert_denied
}

@test "allows an unreadable payload, matching the pre-existing path gate" {
  run_hook 'not json at all'
  assert_allowed
}

# --- the message states what is enforced -----------------------------------

@test "the deny message names both allowed shapes and the by-hand path" {
  run_edit "$(cfg)" '  ...lint.react,' "  ...lint.react,
  rules: {},"
  [ "$status" -eq 2 ]
  grep -qF -- 'comment' <<<"$output"
  grep -qF -- 'spread' <<<"$output"
  grep -qF -- 'by hand' <<<"$output"
}
