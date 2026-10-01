#!/usr/bin/env bats

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/wiki-session-stop.sh
}

teardown() {
  # `return 0` because the guard is an AND-list: with no $REPO to remove it
  # would otherwise leave teardown non-zero and fail an innocent test.
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

# Stage a fixture repo whose session started at its current HEAD and then
# committed one change to PATH_TO_COMMIT. Sets REPO and START.
stage_session_commit() {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO" || return 1
  START=$(git rev-parse HEAD)
  echo "$START" > "$(git rev-parse --git-dir)/claude-session-start"
  echo "note" >> "$1"
  git add "$1"
  git commit --quiet -m "feat: touch $1"
}

@test "no session-start marker: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  head=$(git rev-parse HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session committed nothing: silent" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  head=$(git rev-parse HEAD)
  GIT_DIR=$(git rev-parse --git-dir)
  echo "$head" > "$GIT_DIR/claude-session-start"
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session committed only non-wiki paths with stale wiki state: silent, no marker" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  start=$(git rev-parse HEAD)
  GIT_DIR=$(git rev-parse --git-dir)
  echo "$start" > "$GIT_DIR/claude-session-start"
  for i in 1 2 3; do
    echo "$i" >> bar.txt
    git add bar.txt
    git commit --quiet -m "feat: $i"
  done
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$start","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f .claude/wiki-safety-checked ] && return 1
  return 0
}

@test "session committed wiki paths: WIKI_CHANGED line" {
  stage_session_commit wiki/index.md
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- 'WIKI_CHANGED' <<<"$output" || return 1
  grep -qF -- 'wiki/hot.md' <<<"$output" || return 1
  return 0
}

@test "WIKI_CHANGED fires once per session: a second stop is silent" {
  stage_session_commit wiki/index.md
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  invoke_hook "$input" "$HOOK_ABS"
  grep -qF -- 'WIKI_CHANGED' <<<"$output" || return 1

  invoke_hook "$input" "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "WIKI_CHANGED fires with no stdin at all" {
  stage_session_commit wiki/index.md
  run bash -c 'bash "$1" < /dev/null' _ "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- 'WIKI_CHANGED' <<<"$output" || return 1
  return 0
}

@test "malformed stdin: silent exit 0" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  start=$(git rev-parse HEAD)
  GIT_DIR=$(git rev-parse --git-dir)
  echo "$start" > "$GIT_DIR/claude-session-start"
  echo "x" >> qux.txt
  git add qux.txt
  git commit --quiet -m "x"
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$start","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  invoke_hook 'not-json{{' "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the hook carries no deferral-library sourcing, end-of-session reminder, or safety marker" {
  deferral_name="gaia-ci""-defer"
  reminder_tag="[wiki end-of""-session]"
  grep -qF -- "$deferral_name" "$HOOK_ABS" && return 1
  grep -qF -- "$reminder_tag" "$HOOK_ABS" && return 1
  grep -qF -- 'wiki-safety-checked' "$HOOK_ABS" && return 1
  return 0
}

@test "the hook file is executable" {
  [ -x "$HOOK_ABS" ]
}
