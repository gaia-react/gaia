#!/usr/bin/env bats

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK="$BATS_TEST_DIRNAME/../../../.claude/hooks/wiki-drift-check.sh"
  # Hook is invoked relative to its own repo. Resolve to absolute.
  HOOK_ABS=$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
}

@test "no state file: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  rm -f wiki/.state.json
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "state matches HEAD: silent, marker written" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  head=$(git rev-parse HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f .claude/wiki-drift-checked ]
  grep -q "session_id=S1" .claude/wiki-drift-checked
}

@test "5 commits behind: emits reminder, writes marker" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 5)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)  # initial commit
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[wiki state]"* ]]
  [[ "$output" == *"5 commits ahead"* ]]
  [ -f .claude/wiki-drift-checked ]
  grep -q "drift_count=5" .claude/wiki-drift-checked
}

@test "same session_id second prompt: no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 3)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF

  # First call: emits reminder
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ -n "$output" ]

  # Second call same session: no output
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "different session_id: emits again" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 3)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF

  input1=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  bash -c "echo '$input1' | '$HOOK_ABS'" >/dev/null

  input2=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S2)
  run bash -c "echo '$input2' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[wiki state]"* ]]
  grep -q "session_id=S2" .claude/wiki-drift-checked
}

@test "unreachable state SHA (rebase scenario): silent" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 2)
  cd "$REPO"
  # Use a SHA that doesn't exist in this repo
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  input=$("$HELPERS/mock-hook-input.sh" user-prompt-submit S1)
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing jq input: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  # Need a state file present so we get past the early state-file existence check
  head=$(git rev-parse HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$head","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  run bash -c "echo 'not json' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
