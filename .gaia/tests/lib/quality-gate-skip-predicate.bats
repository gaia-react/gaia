#!/usr/bin/env bats
#
# The Quality Gate page's "Quick check" command decides whether a commit skips
# the gate. After the frontend/ move a commit touching only frontend/package.json
# or frontend/tsconfig.json must still select the gate. The test extracts the
# command from the page itself and runs it against staged files in a temp repo.
#
# The "old" control is an inline copy of the pre-move command, so the guard is
# proven able to fail without reading git history (this PR is squash-merged).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$REPO_ROOT/wiki/decisions/Quality Gate.md"
  TMP_REPO="$(mktemp -d)"
  git -C "$TMP_REPO" init -q
  OLD_COMMAND="git diff --cached --name-only -z | tr '\\0' '\\n' | grep -E '\\.(ts|tsx|js|jsx|mjs|cjs|css)\$|^(package\\.json|pnpm-lock\\.yaml|tsconfig.*\\.json|vite\\.config\\.|vitest\\.config\\.|playwright\\.config\\.|eslint\\.config\\.)'"
}

teardown() {
  rm -rf "$TMP_REPO"
}

# The fenced block that follows the "Quick check:" line.
page_quick_check() {
  awk '
    /^Quick check:$/ { armed = 1; next }
    armed && /^```bash$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$PAGE"
}

# Stage the given paths in the temp repo, run the command, print its output.
staged_selection() {
  local command="$1" path
  shift
  for path in "$@"; do
    mkdir -p "$TMP_REPO/$(dirname "$path")"
    printf '{}\n' >"$TMP_REPO/$path"
    git -C "$TMP_REPO" add -- "$path"
  done
  (cd "$TMP_REPO" && bash -c "$command") || true
}

@test "the page carries exactly one quick-check command" {
  run page_quick_check
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "staging only frontend/package.json selects the gate" {
  run staged_selection "$(page_quick_check)" frontend/package.json
  [ -n "$output" ]
}

@test "staging only frontend/tsconfig.json selects the gate" {
  run staged_selection "$(page_quick_check)" frontend/tsconfig.json
  [ -n "$output" ]
}

@test "staging only the package registry files selects the gate" {
  run staged_selection "$(page_quick_check)" .gaia/packages.json frontend/gaia.package.json
  [ -n "$output" ]
}

@test "root package.json still selects the gate" {
  run staged_selection "$(page_quick_check)" package.json
  [ -n "$output" ]
}

@test "staging only wiki and rules markdown skips the gate" {
  run staged_selection "$(page_quick_check)" wiki/a.md .claude/rules/a.md
  [ -z "$output" ]
}

@test "guard can fail: the pre-move command skips a frontend/tsconfig.json-only stage" {
  run staged_selection "$OLD_COMMAND" frontend/tsconfig.json
  [ -z "$output" ]
}

@test "guard can fail: the pre-move command skips a frontend/package.json-only stage" {
  run staged_selection "$OLD_COMMAND" frontend/package.json
  [ -z "$output" ]
}

@test "steps 3 to 8 each name their pnpm -C frontend equivalent, in order" {
  local expected="typecheck lint test pw dev build" actual=""
  local n
  for n in 3 4 5 6 7 8; do
    local line
    line="$(grep -E "^$n\. " "$PAGE")"
    [ -n "$line" ]
    [[ "$line" == *'pnpm -C frontend '* ]]
    actual="$actual $(printf '%s' "$line" | sed -E 's/.*pnpm -C frontend ([a-z]+).*/\1/')"
  done
  [ "${actual# }" = "$expected" ]
}
