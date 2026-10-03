#!/usr/bin/env bats

# .claude/hooks/wiki-hot-inject.sh: writes the head of wiki/hot.md to stdout at
# SessionStart (startup, resume, clear, compact), capped at 4096 bytes with a
# trailing notice when the file is larger, and nothing when there is no hot.md
# or no repository.
#
# Every case runs a copy of the hook inside a fixture repo, from the fixture's
# root and again from its frontend/ directory, so a hook that reads wiki/hot.md
# relative to the cwd cannot pass. HOOK_SOURCE_PATH points the suite at another
# copy of the hook; the cases that prove the suite can go red run a mutated
# scratch copy through the same assertions and expect them to fail.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/wiki-hot-inject.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TEMPORARY_DIRECTORY="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  . "$REPO_ROOT/.gaia/tests/helpers/hook-registration.sh"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  HOOK_SOURCE_PATH="${HOOK_SOURCE_PATH:-$REPO_ROOT/.claude/hooks/wiki-hot-inject.sh}"
  FIXTURE="$TEMPORARY_DIRECTORY/fixture"
  HOOK="$FIXTURE/.claude/hooks/wiki-hot-inject.sh"
  TRUNCATION_NOTICE='[wiki/hot.md truncated at 4096 bytes; read the file for the rest]'
  mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/wiki" "$FIXTURE/frontend" "$TEMPORARY_DIRECTORY/outside"
  git -C "$FIXTURE" init -q -b main
}

install_hook() {
  cp "$1" "$HOOK"
  chmod 755 "$HOOK"
}

write_small_hot_cache() {
  printf '%s\n' '# Hot cache' 'KNOWN_MARKER_LINE recent context' >"$FIXTURE/wiki/hot.md"
}

# A hot.md of 200 numbered lines, so the 4096-byte cut falls mid-file and the
# last line is a marker that only an uncut read can contain.
write_large_hot_cache() {
  local line_number
  : >"$FIXTURE/wiki/hot.md"
  for line_number in $(seq 1 200); do
    printf 'HOT_LINE_%04d padding padding padding padding\n' "$line_number" >>"$FIXTURE/wiki/hot.md"
  done
  printf '%s\n' 'PAST_THE_CAP_MARKER' >>"$FIXTURE/wiki/hot.md"
}

# run_hook <cwd> <source>: the hook gets a SessionStart payload on stdin.
run_hook() {
  local working_directory="$1" session_source="$2" payload
  payload=$(printf '{"hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$session_source" "$working_directory")
  cd "$working_directory" || return 1
  run --separate-stderr /bin/bash "$HOOK" <<<"$payload"
}

# Assertions return non-zero themselves so a mutated copy can be driven through
# them under `if` and the failure observed.
assert_oversize_is_capped() {
  local last_line portion
  [ "$status" -eq 0 ] || return 1
  [ -z "$stderr" ] || return 1
  last_line=$(printf '%s\n' "$output" | tail -n 1)
  [ "$last_line" = "$TRUNCATION_NOTICE" ] || return 1
  portion=$(head -c 4096 "$FIXTURE/wiki/hot.md")
  printf '%s' "$output" | grep -qF -- 'HOT_LINE_0001' || return 1
  printf '%s' "$output" | grep -qF -- 'PAST_THE_CAP_MARKER' && return 1
  printf '%s' "$output" | grep -qF -- 'HOT_LINE_0200' && return 1
  # Everything before the notice line is at most the cap, and is the file's own head.
  local without_notice
  without_notice=$(printf '%s\n' "$output" | sed '$d')
  [ "$(printf '%s' "$without_notice" | wc -c | tr -d ' ')" -le 4096 ] || return 1
  [ "${portion:0:200}" = "${without_notice:0:200}" ] || return 1
  return 0
}

assert_marker_printed() {
  [ "$status" -eq 0 ] || return 1
  [ -z "$stderr" ] || return 1
  printf '%s' "$output" | grep -qF -- 'KNOWN_MARKER_LINE' || return 1
  return 0
}

@test "startup, resume, clear, and compact each print hot.md from the repo root" {
  install_hook "$HOOK_SOURCE_PATH"
  write_small_hot_cache
  local session_source
  for session_source in startup resume clear compact; do
    run_hook "$FIXTURE" "$session_source"
    assert_marker_printed
  done
}

@test "startup, resume, clear, and compact each print hot.md from frontend/" {
  install_hook "$HOOK_SOURCE_PATH"
  write_small_hot_cache
  local session_source
  for session_source in startup resume clear compact; do
    run_hook "$FIXTURE/frontend" "$session_source"
    assert_marker_printed
  done
}

@test "a hot.md past 4096 bytes is cut at the cap and ends with the truncation notice, from the root" {
  install_hook "$HOOK_SOURCE_PATH"
  write_large_hot_cache
  [ "$(wc -c <"$FIXTURE/wiki/hot.md" | tr -d ' ')" -gt 4096 ]
  run_hook "$FIXTURE" startup
  assert_oversize_is_capped
}

@test "a hot.md past 4096 bytes is cut at the cap and ends with the truncation notice, from frontend/" {
  install_hook "$HOOK_SOURCE_PATH"
  write_large_hot_cache
  run_hook "$FIXTURE/frontend" compact
  assert_oversize_is_capped
}

@test "a hot.md of exactly 4096 bytes prints whole with no truncation notice" {
  install_hook "$HOOK_SOURCE_PATH"
  head -c 4095 /dev/zero | tr '\0' 'a' >"$FIXTURE/wiki/hot.md"
  printf '\n' >>"$FIXTURE/wiki/hot.md"
  [ "$(wc -c <"$FIXTURE/wiki/hot.md" | tr -d ' ')" -eq 4096 ]
  run_hook "$FIXTURE" startup
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- 'truncated' && return 1
  [ "$(printf '%s\n' "$output" | wc -c | tr -d ' ')" -eq 4096 ]
}

@test "no wiki/hot.md prints nothing and exits 0, from the root and from frontend/" {
  install_hook "$HOOK_SOURCE_PATH"
  local working_directory
  for working_directory in "$FIXTURE" "$FIXTURE/frontend"; do
    run_hook "$working_directory" startup
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
  done
}

@test "an unreadable wiki/hot.md prints nothing and exits 0" {
  install_hook "$HOOK_SOURCE_PATH"
  write_small_hot_cache
  chmod 000 "$FIXTURE/wiki/hot.md"
  run_hook "$FIXTURE" startup
  chmod 644 "$FIXTURE/wiki/hot.md"
  [ "$status" -eq 0 ]
  # A root user reads past the mode bits, so only the no-stderr half is universal.
  [ -z "$stderr" ]
}

@test "outside a git repository prints nothing and exits 0" {
  install_hook "$HOOK_SOURCE_PATH"
  write_small_hot_cache
  run_hook "$TEMPORARY_DIRECTORY/outside" startup
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "the header states the 4096-byte cap and the truncation behavior" {
  grep -qF -- '4096 bytes' "$HOOK_SOURCE_PATH"
  grep -qF -- 'truncated at 4096 bytes' "$HOOK_SOURCE_PATH"
  grep -qF -- 'CLAUDE_OBSIDIAN_SESSION_CONTEXT' "$HOOK_SOURCE_PATH"
}

@test "the hook file is executable" {
  [ -x "$REPO_ROOT/.claude/hooks/wiki-hot-inject.sh" ]
}

@test "the hook is registered in both settings files on startup|resume|clear|compact" {
  local settings
  for settings in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/frontend/.claude/settings.json"; do
    hook_registered "$settings" '.hooks.SessionStart[] | select(.matcher == "startup|resume|clear|compact")' wiki-hot-inject.sh
  done
}

@test "the group that runs the hook does not run wiki-session-start.sh" {
  local settings count
  for settings in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/frontend/.claude/settings.json"; do
    count=$(jq '[.hooks.SessionStart[] | select(any(.hooks[]; .command | contains("wiki-hot-inject.sh")))] | length' "$settings")
    [ "$count" -eq 1 ]
    run jq -e '[.hooks.SessionStart[] | select(any(.hooks[]; .command | contains("wiki-hot-inject.sh"))) | .hooks[].command | select(contains("wiki-session-start.sh"))] | length == 0' "$settings"
    [ "$status" -eq 0 ]
  done
}

@test "the recompact and squash hooks are no longer registered and PostCompact is gone" {
  local settings
  for settings in "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/frontend/.claude/settings.json"; do
    run jq -e '.hooks | has("PostCompact") | not' "$settings"
    [ "$status" -eq 0 ]
    # Split literals keep the removed hook names out of the tracked tree.
    run grep -F -e "wiki-""recompact" -e "wiki-squash-""autocommits" "$settings"
    [ "$status" -eq 1 ]
  done
}

@test "packages sync-settings --check reports the committed settings up to date" {
  local cli="$REPO_ROOT/.gaia/cli/gaia"
  [ -x "$cli" ] || skip "the .gaia/cli/gaia binary is absent"
  run "$cli" packages sync-settings --check --repo-root "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

# The cases below prove the suite can fail: each runs a scratch copy of the hook
# with one behavior broken through the real assertions and expects them to fail.

@test "guard: a copy with the byte cap removed fails the oversize assertions" {
  local mutated="$TEMPORARY_DIRECTORY/mutated-no-cap.sh"
  sed 's/head -c "\$maximum_bytes"/cat/' "$HOOK_SOURCE_PATH" >"$mutated"
  cmp -s "$HOOK_SOURCE_PATH" "$mutated" && return 1
  install_hook "$mutated"
  write_large_hot_cache
  run_hook "$FIXTURE" startup
  if assert_oversize_is_capped; then return 1; fi
  true
}

@test "guard: a copy that reads wiki/hot.md relative to the cwd fails the frontend/ case" {
  local mutated="$TEMPORARY_DIRECTORY/mutated-cwd-relative.sh"
  sed 's|^hot_cache=.*|hot_cache="wiki/hot.md"|' "$HOOK_SOURCE_PATH" >"$mutated"
  cmp -s "$HOOK_SOURCE_PATH" "$mutated" && return 1
  install_hook "$mutated"
  write_small_hot_cache
  run_hook "$FIXTURE" startup
  assert_marker_printed
  run_hook "$FIXTURE/frontend" startup
  if assert_marker_printed; then return 1; fi
  true
}
