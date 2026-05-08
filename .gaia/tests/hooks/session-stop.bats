#!/usr/bin/env bats

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/wiki-session-stop.sh
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
}

@test "no session-start marker: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  head=$(git rev-parse HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  run bash -c "echo '$input' | '$HOOK_ABS'"
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
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session committed and state advanced fully: silent" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  start=$(git rev-parse HEAD)
  GIT_DIR=$(git rev-parse --git-dir)
  echo "$start" > "$GIT_DIR/claude-session-start"
  echo "x" > foo.txt
  git add foo.txt
  git commit --quiet -m "feat: add foo"
  head=$(git rev-parse HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session committed but state did not advance: emits reminder" {
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
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[wiki end-of-session]"* ]]
  [[ "$output" == *"3 times"* ]]
  [ -f .claude/wiki-safety-checked ]
}

@test "same session second stop: no re-nag" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  start=$(git rev-parse HEAD)
  GIT_DIR=$(git rev-parse --git-dir)
  echo "$start" > "$GIT_DIR/claude-session-start"
  echo "x" >> baz.txt
  git add baz.txt
  git commit --quiet -m "x"
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$start","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF

  input=$("$HELPERS/mock-hook-input.sh" stop S1)
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ -n "$output" ]

  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
  run bash -c "echo 'not-json{{' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
