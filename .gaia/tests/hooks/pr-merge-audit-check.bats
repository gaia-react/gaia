#!/usr/bin/env bats

# Tests for the out-of-scope bypass in .claude/hooks/pr-merge-audit-check.sh.
#
# The hook denies `gh pr merge` unless a code-review-audit signal exists for
# HEAD. Signal 5 (check_out_of_scope_pr) is a fail-closed allowlist bypass: it
# allows the merge when EVERY file the PR changes (vs its merge base with the
# default branch) lives outside audit scope — wiki/, .claude/, .specify/,
# .gaia/, docs/, and root-level markdown. Any in-scope path (app/, test/,
# configs, .github/workflows/) keeps the marker mandatory.
#
# Each test drives the hook exactly as the harness does: a PreToolUse JSON
# payload on stdin, run with the repo as the working directory (the hook uses
# bare `git`, not `git -C`). The hook always exits 0; allow vs deny is carried
# in stdout — a deny emits `"permissionDecision": "deny"`, an allow emits
# nothing. The in-scope (deny) cases double as a jq/setup canary: if jq were
# missing the hook would exit early with no output and those assertions would
# fail rather than false-pass.
#
# Setup models a PR: a base commit on `main`, then a `feature` branch carrying
# the change under test. merge-base(HEAD, main) resolves to the base commit, so
# the bypass diffs only the feature's files. No remote is needed — the hook
# falls back from `origin/main` to `main`.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/pr-merge-audit-check.sh
  REPO=$(mktemp -d -t pr-merge-test-XXXXXX)

  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false

  mkdir -p "$REPO/.gaia"
  printf '1.4.0\n' > "$REPO/.gaia/VERSION"
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add .gaia/VERSION README.md
  git -C "$REPO" commit --quiet -m "init"

  git -C "$REPO" checkout --quiet -b feature
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Commit one or more files (path=content pairs) on the feature branch.
commit_files() {
  while [ "$#" -gt 0 ]; do
    local path="$1" content="$2"; shift 2
    mkdir -p "$REPO/$(dirname "$path")"
    printf '%s\n' "$content" > "$REPO/$path"
    git -C "$REPO" add "$path"
  done
  git -C "$REPO" commit --quiet -m "change"
}

# Run the hook with a `gh pr merge` command, from inside the repo.
run_merge_hook() {
  local cmd="${1:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -n --arg c "$cmd" \
    '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c "cd '$REPO' && printf '%s' '$json' | bash '$HOOK_ABS'"
}

@test "allows a docs/metadata-only PR (wiki + .claude + .gaia)" {
  commit_files \
    ".claude/skills/update-gaia/SKILL.md" "updated" \
    "wiki/concepts/PR Merge Workflow.md" "updated" \
    ".gaia/manifest.json" "{}"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "allows a root-level markdown-only PR" {
  commit_files "README.md" "# changed"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "allows a docs-only PR under docs/" {
  commit_files "docs/guide.md" "guide"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR that changes app/ source" {
  commit_files "app/components/Foo/index.tsx" "export const Foo = () => null"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR that changes a root config (package.json)" {
  commit_files "package.json" '{"name":"x"}'
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR that changes a root *.config.ts" {
  commit_files "vitest.config.ts" "export default {}"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR mixing out-of-scope docs with in-scope source" {
  commit_files \
    "wiki/x.md" "doc" \
    "app/y.ts" "export const y = 1"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "denies a PR that changes a CI workflow" {
  commit_files ".github/workflows/tests.yml" "name: t"
  run_merge_hook
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

@test "ignores commands that are not gh pr merge" {
  commit_files "app/y.ts" "export const y = 1"
  run_merge_hook "git status"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"permissionDecision": "deny"'* ]]
}
