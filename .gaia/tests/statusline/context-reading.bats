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
  STATUSLINE_SRC=$(cd "$BATS_TEST_DIRNAME/../../statusline" && pwd)
  SCRIPTS_SRC=$(cd "$BATS_TEST_DIRNAME/../../scripts" && pwd)
  GAIA_SRC=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  SID="0a1b2c3d-1111-4222-8333-444455556666"

  MAIN=$(mktemp -d -t gaia-ctx-main-XXXXXX)
  git -C "$MAIN" init --quiet --initial-branch=main
  git -C "$MAIN" config user.email "test@example.com"
  git -C "$MAIN" config user.name "Test"
  git -C "$MAIN" config commit.gpgsign false
  mkdir -p "$MAIN/.gaia/statusline" "$MAIN/.gaia/scripts" "$MAIN/.gaia/local"
  cp "$STATUSLINE_SRC"/*.sh "$MAIN/.gaia/statusline/"
  cp "$SCRIPTS_SRC/main-root-lib.sh" "$SCRIPTS_SRC/context-checkpoint-lib.sh" "$MAIN/.gaia/scripts/"
  echo x >"$MAIN/README.md"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit --quiet -m init
  printf '{"completed_at":"2026-01-01T00:00:00Z"}' >"$MAIN/.gaia/local/setup-state.json"
  WT="${MAIN}-wt"
  CTX_DIR="$MAIN/.gaia/local/cache/shared/context"
  TMP_HOME=$(mktemp -d -t gaia-ctx-home-XXXXXX)
}

teardown() {
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN" "${MAIN}-wt" || true
  [ -n "${TMP_HOME:-}" ] && rm -rf "$TMP_HOME" || true
  return 0
}

# payload <cwd> <session_id> <pct> <window> [total_input_tokens]
payload() {
  jq -n --arg d "$1" --arg sid "$2" --argjson pct "$3" --argjson win "$4" --argjson tit "${5:-1}" \
    '{session_id: $sid, workspace: {current_dir: $d}, cwd: $d, model: {display_name: "Claude Opus"}, effort: {level: "high"},
      context_window: {used_percentage: $pct, context_window_size: $win, total_input_tokens: $tit}}'
}

# render <script> <json> [extra env assignments...]
render() {
  local script="$1" json="$2"
  shift 2
  PAYLOAD="$json" run env HOME="$TMP_HOME" COLUMNS=200 "$@" bash -c "printf '%s' \"\$PAYLOAD\" | bash '$script'"
}

main_script() { printf '%s' "$MAIN/.gaia/statusline/gaia-statusline.sh"; }

assert_context_file() {
  local f="$CTX_DIR/$SID.json"
  [ -f "$f" ] || { echo "missing $f"; return 1; }
  jq -e '.version == 1 and (.used_percentage | type == "number") and (.used_tokens | type == "number")
    and (.context_window_size | type == "number") and (.written_at | type == "number")
    and .session_id == "'"$SID"'"' "$f" >/dev/null || { cat "$f"; return 1; }
  if find "$CTX_DIR" -name '*.tmp.*' | grep -q .; then
    echo "tmp file left behind"
    return 1
  fi
}

@test "main checkout: a render writes the context file with every field" {
  render "$(main_script)" "$(payload "$MAIN" "$SID" 25 1000000)"
  [ "$status" -eq 0 ]
  assert_context_file
  [ "$(jq -r .context_window_size "$CTX_DIR/$SID.json")" = "1000000" ]
}

@test "linked worktree: the file lands under the MAIN checkout, not the worktree" {
  git -C "$MAIN" worktree add --quiet "$WT" -b feature
  render "$(main_script)" "$(payload "$WT" "$SID" 25 1000000)"
  [ "$status" -eq 0 ]
  assert_context_file
  [ ! -e "$WT/.gaia/local/cache/shared/context" ]
}

@test "a user global statusLine.command still gets the context file written" {
  mkdir -p "$TMP_HOME/.claude"
  printf '{"statusLine":{"type":"command","command":"printf USERLEFT"}}' >"$TMP_HOME/.claude/settings.json"
  render "$(main_script)" "$(payload "$MAIN" "$SID" 25 1000000)"
  [ "$status" -eq 0 ]
  assert_context_file
  grep -qF "USERLEFT" <<<"$output"
}

@test "used_tokens is the percentage-derived value, not total_input_tokens" {
  render "$(main_script)" "$(payload "$MAIN" "$SID" 33.3333 200000 123)"
  [ "$status" -eq 0 ]
  # round(33.3333 / 100 * 200000) = 66667; total_input_tokens (123) must not win.
  [ "$(jq -r .used_tokens "$CTX_DIR/$SID.json")" = "66667" ]
}

@test "a long fractional percentage is accepted (rounded to the lib's shape)" {
  render "$(main_script)" "$(payload "$MAIN" "$SID" 33.333333333333336 200000)"
  [ "$status" -eq 0 ]
  assert_context_file
  [ "$(jq -r .used_tokens "$CTX_DIR/$SID.json")" = "66667" ]
}

@test "red: no session_id writes nothing and still renders" {
  local json
  json=$(payload "$MAIN" "$SID" 25 1000000 | jq 'del(.session_id)')
  render "$(main_script)" "$json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CTX_DIR" ]
}

@test "red: a path-traversal session_id writes nothing anywhere and still renders" {
  render "$(main_script)" "$(payload "$MAIN" "../../x" 25 1000000)"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CTX_DIR" ]
  # "../../x" resolves to <main>/.gaia/local/cache/x.json when it escapes.
  [ -z "$(find "$MAIN" -name 'x*' -not -path '*/.git/*')" ]
  [ -z "$(find "$(dirname "$MAIN")" -maxdepth 1 -name 'x.json')" ]
}

@test "red: a non-UUID session_id writes nothing" {
  render "$(main_script)" "$(payload "$MAIN" "not-a-uuid" 25 1000000)"
  [ "$status" -eq 0 ]
  [ ! -e "$CTX_DIR" ]
}

@test "red: no context_window writes nothing and still renders" {
  local json
  json=$(payload "$MAIN" "$SID" 25 1000000 | jq 'del(.context_window)')
  render "$(main_script)" "$json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CTX_DIR" ]
}

@test "red: a context_window without a size writes nothing" {
  local json
  json=$(payload "$MAIN" "$SID" 25 1000000 | jq 'del(.context_window.context_window_size)')
  render "$(main_script)" "$json"
  [ "$status" -eq 0 ]
  [ ! -e "$CTX_DIR" ]
}

@test "red: a non-JSON stdin writes nothing and still renders" {
  render "$(main_script)" "this is not json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CTX_DIR" ]
}

@test "GAIA_STATUSLINE_NESTED=1 still writes the file" {
  render "$(main_script)" "$(payload "$MAIN" "$SID" 25 1000000)" GAIA_STATUSLINE_NESTED=1
  [ "$status" -eq 0 ]
  assert_context_file
}

@test "setup-gaia pending (no setup state) still writes the file" {
  rm -f "$MAIN/.gaia/local/setup-state.json"
  render "$(main_script)" "$(payload "$MAIN" "$SID" 25 1000000)"
  [ "$status" -eq 0 ]
  grep -qF "Run /setup-gaia" <<<"$output"
  assert_context_file
}

@test "a missing sibling (older checkout) degrades: renders, writes nothing" {
  rm "$MAIN/.gaia/statusline/context-reading.sh"
  render "$(main_script)" "$(payload "$MAIN" "$SID" 25 1000000)"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ ! -e "$CTX_DIR" ]
}

@test "the maintainer wrapper's patched copy still writes the file" {
  local wrapper="$GAIA_SRC/local/maintainer-statusline.sh"
  if [ ! -f "$wrapper" ]; then
    skip "gitignored .gaia/local/maintainer-statusline.sh is absent (CI); the maintainer-path case runs only on the maintainer machine"
  fi
  # Reproduce the wrapper's own mechanics in the sandbox: it seds the shipped
  # script into .gaia/local/.patched-statusline.sh and execs it from there.
  cp "$wrapper" "$MAIN/.gaia/local/maintainer-statusline.sh"
  git -C "$MAIN" worktree add --quiet "$WT" -b feature
  render "$MAIN/.gaia/local/maintainer-statusline.sh" "$(payload "$WT" "$SID" 25 1000000)"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.gaia/local/.patched-statusline.sh" ]
  assert_context_file
}
