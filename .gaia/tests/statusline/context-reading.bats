#!/usr/bin/env bats

# Tests for the context-reading writer in .gaia/statusline/gaia-statusline.sh
# (sourced sibling context-reading.sh). Every render whose stdin carries a
# session_id and a context_window writes the per-session context file under
# the main checkout's cache/shared/context directory atomically, from the main
# checkout and from a linked worktree, whatever left side is configured; a
# render without them writes nothing and still renders.
#
# HOME points at an empty dir unless a test sets a user global command, so the
# left side is the shipped default.

setup() {
  STATUSLINE_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  SCRIPTS_SOURCE=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)
  GAIA_SOURCE=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  SESSION_ID="0a1b2c3d-1111-4222-8333-444455556666"

  MAIN=$(mktemp -d -t gaia-ctx-main-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/scripts" "$MAIN/.gaia/local"
  cp "$STATUSLINE_SOURCE"/*.sh "$MAIN/.gaia/statusline/"
  cp "$SCRIPTS_SOURCE/main-root-lib.sh" "$SCRIPTS_SOURCE/context-checkpoint-lib.sh" "$MAIN/.gaia/scripts/"
  echo x >"$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m init
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' >"$MAIN/.gaia/local/setup-state.json"
  WORKTREE="${MAIN}-wt"
  CONTEXT_DIRECTORY="$MAIN/.gaia/local/cache/shared/context"
  TEMPORARY_HOME=$(mktemp -d -t gaia-ctx-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" "${MAIN}-wt" || true
  [ -n "${TEMPORARY_HOME:-}" ] && rm -rf "$TEMPORARY_HOME" || true
  return 0
}

# payload <cwd> <session_id> <used_percentage> <window> [total_input_tokens]
payload() {
  jq -n --arg current_directory "$1" --arg session_id "$2" --argjson used_percentage "$3" --argjson window_size "$4" --argjson total_input_tokens "${5:-1}" \
    '{session_id: $session_id, workspace: {current_dir: $current_directory}, cwd: $current_directory, model: {display_name: "Claude Opus"}, effort: {level: "high"},
      context_window: {used_percentage: $used_percentage, context_window_size: $window_size, total_input_tokens: $total_input_tokens}}'
}

# render <script> <json> [extra env assignments...]
render() {
  local script="$1" json="$2"
  shift 2
  PAYLOAD="$json" run env HOME="$TEMPORARY_HOME" COLUMNS=200 "$@" bash -c "printf '%s' \"\$PAYLOAD\" | bash '$script'"
}

main_script() { printf '%s' "$MAIN/.gaia/statusline/gaia-statusline.sh"; }

assert_context_file() {
  local context_file="$CONTEXT_DIRECTORY/$SESSION_ID.json"
  [ -f "$context_file" ] || { echo "missing $context_file"; return 1; }
  jq -e '.version == 1 and (.used_percentage | type == "number") and (.used_tokens | type == "number")
    and (.context_window_size | type == "number") and (.written_at | type == "number")
    and .session_id == "'"$SESSION_ID"'"' "$context_file" >/dev/null || { cat "$context_file"; return 1; }
  if find "$CONTEXT_DIRECTORY" -name '*.tmp.*' | grep -q .; then
    echo "tmp file left behind"
    return 1
  fi
}

@test "main checkout: a render writes the context file with every field" {
  render "$(main_script)" "$(payload "$MAIN" "$SESSION_ID" 25 1000000)"
  [ "$status" -eq 0 ]
  assert_context_file
  [ "$(jq -r .context_window_size "$CONTEXT_DIRECTORY/$SESSION_ID.json")" = "1000000" ]
}

@test "linked worktree: the file lands under the MAIN checkout, not the worktree" {
  git -C "$MAIN" worktree add --quiet "$WORKTREE" -b feature
  render "$(main_script)" "$(payload "$WORKTREE" "$SESSION_ID" 25 1000000)"
  [ "$status" -eq 0 ]
  assert_context_file
  [ ! -e "$WORKTREE/.gaia/local/cache/shared/context" ]
}

@test "a user global statusLine.command still gets the context file written" {
  mkdir -p "$TEMPORARY_HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"printf USERLEFT"}}' >"$TEMPORARY_HOME/.claude/settings.json"
  render "$(main_script)" "$(payload "$MAIN" "$SESSION_ID" 25 1000000)"
  [ "$status" -eq 0 ]
  assert_context_file
  grep -qF "USERLEFT" <<<"$output"
}

@test "used_tokens is the percentage-derived value, not total_input_tokens" {
  render "$(main_script)" "$(payload "$MAIN" "$SESSION_ID" 33.3333 200000 123)"
  [ "$status" -eq 0 ]
  # round(33.3333 / 100 * 200000) = 66667; total_input_tokens (123) must not win.
  [ "$(jq -r .used_tokens "$CONTEXT_DIRECTORY/$SESSION_ID.json")" = "66667" ]
}

@test "a long fractional percentage is accepted (rounded to the lib's shape)" {
  render "$(main_script)" "$(payload "$MAIN" "$SESSION_ID" 33.333333333333336 200000)"
  [ "$status" -eq 0 ]
  assert_context_file
  [ "$(jq -r .used_tokens "$CONTEXT_DIRECTORY/$SESSION_ID.json")" = "66667" ]
}

@test "red: no session_id writes nothing and still renders" {
  local json
  json=$(payload "$MAIN" "$SESSION_ID" 25 1000000 | jq 'del(.session_id)')
  render "$(main_script)" "$json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "red: a path-traversal session_id writes nothing anywhere and still renders" {
  render "$(main_script)" "$(payload "$MAIN" "../../x" 25 1000000)"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
  # "../../x" resolves to <main>/.gaia/local/cache/x.json when it escapes.
  [ -z "$(find "$MAIN" -name 'x*' -not -path '*/.git/*')" ]
  [ -z "$(find "$(dirname "$MAIN")" -maxdepth 1 -name 'x.json')" ]
}

@test "red: a non-UUID session_id writes nothing" {
  render "$(main_script)" "$(payload "$MAIN" "not-a-uuid" 25 1000000)"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "red: no context_window writes nothing and still renders" {
  local json
  json=$(payload "$MAIN" "$SESSION_ID" 25 1000000 | jq 'del(.context_window)')
  render "$(main_script)" "$json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "red: a context_window without a size writes nothing" {
  local json
  json=$(payload "$MAIN" "$SESSION_ID" 25 1000000 | jq 'del(.context_window.context_window_size)')
  render "$(main_script)" "$json"
  [ "$status" -eq 0 ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "red: a non-JSON stdin writes nothing and still renders" {
  render "$(main_script)" "this is not json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "GAIA_STATUSLINE_NESTED=1 still writes the file" {
  render "$(main_script)" "$(payload "$MAIN" "$SESSION_ID" 25 1000000)" GAIA_STATUSLINE_NESTED=1
  [ "$status" -eq 0 ]
  assert_context_file
}

@test "setup-gaia pending (no setup state) still writes the file" {
  rm -f "$MAIN/.gaia/local/setup-state.json"
  render "$(main_script)" "$(payload "$MAIN" "$SESSION_ID" 25 1000000)"
  [ "$status" -eq 0 ]
  grep -qF "Run /setup-gaia" <<<"$output"
  assert_context_file
}

@test "a missing sibling (older checkout) degrades: renders, writes nothing" {
  rm "$MAIN/.gaia/statusline/context-reading.sh"
  render "$(main_script)" "$(payload "$MAIN" "$SESSION_ID" 25 1000000)"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CONTEXT_DIRECTORY" ]
}

@test "the maintainer wrapper's patched copy still writes the file" {
  local wrapper="$GAIA_SOURCE/local/maintainer-statusline.sh"
  if [ ! -f "$wrapper" ]; then
    skip "gitignored .gaia/local/maintainer-statusline.sh is absent (CI); the maintainer-path case runs only on the maintainer machine"
  fi
  # Reproduce the wrapper's own mechanics in the sandbox: it seds the shipped
  # script into .gaia/local/.patched-statusline.sh and execs it from there.
  cp "$wrapper" "$MAIN/.gaia/local/maintainer-statusline.sh"
  git -C "$MAIN" worktree add --quiet "$WORKTREE" -b feature
  render "$MAIN/.gaia/local/maintainer-statusline.sh" "$(payload "$WORKTREE" "$SESSION_ID" 25 1000000)"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.gaia/local/.patched-statusline.sh" ]
  assert_context_file
}
