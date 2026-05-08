#!/usr/bin/env bats

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/wiki-commit-nudge.sh
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
}

@test "non-Bash tool: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  input=$(jq -n '{session_id:"S1",tool_name:"Edit",tool_input:{file_path:"x"}}')
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Bash but not git commit: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "ls -la")
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git commit-tree: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "git commit-tree foo")
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git commit --amend: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "git commit --amend --no-edit")
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "git commit emits nudge with subject and file count" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 1)
  cd "$REPO"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'git commit -m "feat: add foo"')
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[wiki nudge]"* ]]
  [[ "$output" == *"Committed"* ]]
}

@test "wiki commit subject: skipped" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  echo "x" > wiki/foo.md
  git add wiki/foo.md
  git commit --quiet -m "wiki: auto-commit 2026-05-03"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash "git commit -m wiki")
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "drift count appears when state file present and behind" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 3)
  cd "$REPO"
  base=$(git rev-list --max-parents=0 HEAD)
  cat > wiki/.state.json <<EOF
{"version":1,"last_evaluated_sha":"$base","last_evaluated_at":"2026-01-01T00:00:00Z"}
EOF
  git add wiki/.state.json
  git commit --quiet -m "feat: another"
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'git commit -m "feat: another"')
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [[ "$output" == *"commits behind"* ]]
}

@test "no state file: omits drift, still nudges" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 1)
  cd "$REPO"
  rm -f wiki/.state.json
  input=$("$HELPERS/mock-hook-input.sh" post-tool-use S1 Bash 'git commit -m "feat: x"')
  run bash -c "echo '$input' | '$HOOK_ABS'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[wiki nudge]"* ]]
  [[ "$output" != *"commits behind"* ]]
}
