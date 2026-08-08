#!/usr/bin/env bats

# Tests for .claude/hooks/block-eslint-config-edit.sh.
#
# The guard protects eslint.config.{js,cjs,mjs,ts,mts,cts} at any path, and what
# it does on a match is ASK: every edit to the file prompts the operator,
# whatever the edit does. So the suite has two halves and neither is decoration.
#
# The first half is the path gate, which is the only thing that decides anything:
# a file that is not an eslint config passes silently, every guarded extension at
# every depth asks. It is pinned in both directions on purpose. The extension set
# is ESLint's own `FLAT_CONFIG_FILENAMES`, so a missing member is a config the
# resolver loads and the guard ignores; and the pattern's `(^|/)` boundary is
# what keeps an ordinary source file named `my-eslint.config.mjs` out of the
# prompt, a dimension no fixture varies unless one is written for it.
#
# The second half is the reason string, and it carries more weight than a message
# usually does, because here it is the whole basis on which a human answers. The
# operator is being asked precisely because the hook cannot tell the two cases
# apart, so the reason has to hand them what the hook could not use: that the
# prompt is on the filename alone, which edit is legitimate, and where the common
# case belongs instead. Those three are pinned individually, because a reason
# that loses any one of them turns an informed confirmation into a rubber stamp.
#
# The ask cases below deliberately include both extremes, a comment-only change
# and a whole-file replacement, an added bare preset spread and an added rule
# override. They are the cases where a guard that started judging edits again
# would first diverge, and judging is what this hook exists not to do: the
# legitimate shape and the silencing shape are the same shape, so the uniform ask
# is the contract rather than a coarse approximation of one.
#
# shellcheck disable=SC2317
# SC2317 (command appears unreachable) is a structural false positive on every
# @test block: bats invokes each body through its own runner, which the static
# analyzer cannot see. File-wide because the false positive is intrinsic to the
# bats structure rather than to any single test. (Keep the word "shellcheck"
# off the start of a comment line here; it is parsed as a directive there.)
#
# shellcheck disable=SC2016
# SC2016 (expressions don't expand in single quotes) fires on the `$` inside
# fixture identifiers and on `${...}` inside fixture config bodies. Not
# expanding is the point: a fixture has to reach the hook as the literal text a
# real edit would carry.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
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

# The fixtures here carry quotes of their own, so delivery goes through
# `invoke_hook` (helpers/run-hook.sh), which passes the payload positionally.
run_hook() {
  invoke_hook "$1" "$HOOK_ABS"
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



# --- path gate, the only thing that decides anything ------------------------

@test "allows an edit to a file that is not an eslint config" {
  run_edit "$(cfg 'const a = 1;' 'home.tsx')" 'const a = 1;' 'const a = 2;'
  assert_allowed_by_exit
}

@test "allows an edit to a lookalike filename" {
  run_edit "$(cfg 'rules: {}' 'eslint.config.md')" 'rules: {}' "rules: {a: 'off'}"
  assert_allowed_by_exit
}

@test "allows a source file whose name merely ends in the guarded one" {
  run_edit "$(cfg 'const a = 1;' 'my-eslint.config.mjs')" 'const a = 1;' 'const a = 2;'
  assert_allowed_by_exit
}

@test "allows a file whose name merely starts with the guarded one" {
  run_edit "$(cfg 'const a = 1;' 'eslint.config.mjs.bak')" 'const a = 1;' 'const a = 2;'
  assert_allowed_by_exit
}

# This fixture is pinned between two limits that pull in opposite directions,
# and it is the only test here that cannot use the shared helpers. Both
# constraints are load-bearing; satisfying one alone breaks it.
#
# It must be FAR ABOVE the pipe boundary. What it pins is a pipe fail-open, so
# the shape only reproduces past pipe capacity (65536) plus whatever the reader
# drains before exiting, and that second term is a property of the grep
# implementation rather than a constant: it moves by kilobytes between the two
# greps on one macOS host, and CI runs a third. A fixture tuned just above the
# local boundary passes with the defect fully restored on any reader that
# buffers more.
#
# It must also NEVER TRAVEL THROUGH ARGV, which is the constraint that bites as
# soon as the first one is satisfied. Linux caps a single execve argument at
# MAX_ARG_STRLEN, 32 pages (131072 bytes), independently of ARG_MAX, so a
# megabyte-scale payload handed to `jq --arg` never execs at all: jq dies E2BIG,
# the substitution yields nothing, the hook reads empty stdin and exits 0, and
# the test fails on the platform CI runs while passing on macOS, which has no
# per-string cap. That is a kernel limit rather than a bash-version gap, so the
# bash-5 pre-flight cannot see it either.
#
# So the payload is assembled into files and reaches jq by --rawfile and the
# hook by stdin redirection, crossing no argv boundary at any size.
@test "asks on a guarded path arriving with megabytes of trailing payload" {
  { printf '%s\n' "$(cfg)"; head -c 1000000 /dev/zero | tr '\0' 'x'; } >"$TMP/path.txt"
  jq -n --rawfile p "$TMP/path.txt" \
    '{tool_name: "Edit", tool_input: {file_path: $p, old_string: "a", new_string: "b"}}' \
    >"$TMP/payload.json"
  run bash -c 'bash "$2" <"$1"' _ "$TMP/payload.json" "$HOOK_ABS"
  assert_asked_by_json
}

# Every other fixture builds its path under $TMP, so all of them carry a slash
# and only the `/` half of the pattern's `(^|/)` gets exercised. Without this
# case, narrowing the group to `(/)` is undetected.
@test "guards a config named with no directory component at all" {
  run_tool Edit '{"file_path": "eslint.config.mjs", "old_string": "a", "new_string": "b"}'
  assert_asked_by_json
}

@test "guards every extension ESLint resolves, at any depth" {
  mkdir -p "$TMP/apps/web"
  for name in eslint.config.js eslint.config.cjs eslint.config.mjs eslint.config.ts \
    eslint.config.mts eslint.config.cts apps/web/eslint.config.mjs; do
    run_edit "$(cfg "$DEFAULT_BODY" "$name")" '  ...lint.react,' "  ...lint.react,
  rules: {'no-empty-pattern': 'off'},"
    [ "$status" -eq 0 ] || return 1
    grep -qF -- '"permissionDecision": "ask"' <<<"$output" || return 1
  done
}

# --- the ask is uniform, across every shape a judging guard would split -----

@test "asks on the reactRouter migration rather than refusing it" {
  run_edit "$(cfg)" '  ...lint.react,' '  ...lint.react,
  ...lint.reactRouter,'
  assert_asked_by_json
}

@test "asks on a comment-only change" {
  run_edit "$(cfg)" ' * Config for the app.' ' * ESLint config for the app.'
  assert_asked_by_json
}

@test "asks on a blank-line-only change" {
  run_edit "$(cfg)" "const lint = gaiaLint();

export default" "const lint = gaiaLint();


export default"
  assert_asked_by_json
}

@test "asks on a Write whose content only changes a comment" {
  run_write "$(cfg)" "${DEFAULT_BODY/Config for the app./ESLint config for the app.}"
  assert_asked_by_json
}

@test "asks on a MultiEdit whose every pair is a comment or an added spread" {
  run_tool MultiEdit "$(jq -n --arg p "$(cfg)" \
    '{file_path: $p,
      edits: [{old_string: " * Config for the app.", new_string: " * ESLint config."},
              {old_string: "  ...lint.react,", new_string: "  ...lint.react,\n  ...lint.reactRouter,"}]}')"
  assert_asked_by_json
}

# --- including the shapes that are usually silencing, so the floor is pinned -

@test "asks on adding a rule override" {
  run_edit "$(cfg)" "    rules: {'no-console': 'off'}," \
    "    rules: {'no-console': 'off', 'no-empty-pattern': 'off'},"
  assert_asked_by_json
}

@test "asks on removing a preset spread" {
  run_edit "$(cfg)" '  ...lint.guardrails,
' ''
  assert_asked_by_json
}

@test "asks on a Write that replaces the whole config" {
  run_write "$(cfg)" 'export default [];'
  assert_asked_by_json
}

# The hook never rules on a config edit, in either direction. Asserting the ask
# positively does not pin this: a hook that emitted BOTH an ask and a deny, or
# that regressed to the exit-2 contract while still printing an ask, satisfies
# every test above. The two failure directions are opposite, so they are pinned
# separately.
@test "never denies a config edit, and never blocks by exit code" {
  run_edit "$(cfg)" "    rules: {'no-console': 'off'}," \
    "    rules: {'no-console': 'off', 'no-empty-pattern': 'off'},"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  return 0
}

# The decision is machine-read, so a reason string that broke out of the JSON
# would take the whole decision with it and the hook would report nothing at
# all, which is the fail-open direction. `jq -n --arg` is what guarantees this;
# a hand-built JSON string is the shape that loses it.
@test "emits one well-formed JSON object a parser accepts" {
  run_edit "$(cfg)" ' * Config for the app.' ' * ESLint config.'
  [ "$status" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' <<<"$output" >/dev/null
}

# --- the reason is what the operator answers on ----------------------------

@test "the reason names the sanctioned migration it is asking about" {
  run_edit "$(cfg)" '  ...lint.react,' '  ...lint.react,
  ...lint.reactRouter,'
  assert_asked_by_json
  grep -qF -- '...lint.reactRouter' <<<"$output"
}

@test "the reason admits the prompt is on the filename alone" {
  run_edit "$(cfg)" ' * Config for the app.' ' * ESLint config.'
  assert_asked_by_json
  grep -qF -- 'filename alone' <<<"$output"
}

@test "the reason tells the operator the answer is theirs to give" {
  run_edit "$(cfg)" ' * Config for the app.' ' * ESLint config.'
  assert_asked_by_json
  grep -qF -- 'Approve only if you meant this edit' <<<"$output"
  # Asking is only safe while the reason also refuses the workaround. Nothing in
  # .claude/hooks/ guards writes to .claude/settings.json, so an agent that reads
  # a prompt as an obstacle can drop the registration and leave the guard off.
  # The assertion above cannot see that: a reason inviting a workaround still
  # contains the approve clause.
  grep -qF -- 'do not disable this hook' <<<"$output"
}

@test "the reason keeps pointing at the source file for the common case" {
  run_edit "$(cfg)" "    rules: {'no-console': 'off'}," \
    "    rules: {'no-console': 'off', 'no-empty-pattern': 'off'},"
  assert_asked_by_json
  grep -qF -- 'source file where it occurs' <<<"$output"
}

# --- an unreadable payload on a guarded path still asks ---------------------
# The path gate is the entire decision, so a tool shape the hook cannot parse
# changes nothing: the file is a config, so the operator is asked. These pin
# that the ask does not depend on reading the edit, which is the property that
# would erode first if a judging guard crept back in.

@test "asks on a tool shape it cannot otherwise read on a guarded path" {
  run_tool NotebookEdit "$(jq -n --arg p "$(cfg)" '{file_path: $p}')"
  assert_asked_by_json
}

@test "asks on an Edit on a guarded path carrying no strings at all" {
  run_tool Edit "$(jq -n --arg p "$(cfg)" '{file_path: $p}')"
  assert_asked_by_json
}

@test "asks on a Write on a guarded path that does not exist yet" {
  run_write "$TMP/eslint.config.ts" 'export default [];'
  assert_asked_by_json
}

# --- a payload naming no file cannot be judged, and is not an exemption -----

@test "exits zero on a payload carrying no file_path" {
  run_tool Edit '{"old_string": "a", "new_string": "b"}'
  assert_allowed_by_exit
}

@test "exits zero on a payload that is not readable JSON" {
  run_hook 'not json at all'
  assert_allowed_by_exit
}
