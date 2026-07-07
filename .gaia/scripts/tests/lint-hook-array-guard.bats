#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-hook-array-guard.sh: the static gate that flags
# unguarded bare "${arr[@]}" / "${arr[*]}" expansions in `set -u` hook bodies,
# the bash 3.2.57 empty-array abort class the bash-5 bats suites are blind to.
#
# Two jobs: prove the detector fires on a known-bad fixture and stays quiet on
# each guarded form (offset-guard, count-guard, no-set-u, comment), and assert
# the real .claude/hooks/ tree is clean so a regression fails CI.
#
# Assertion style (.claude/rules/bats-assertions.md): grep -qF / [ ] / explicit
# return 1, never a bare [[ ]] as a non-final line. The linter is invoked as
# `bash "$LINTER"` from a fixture cwd, matching how CI runs it from the repo
# root; its SCAN_GLOB is `.claude/hooks/*.sh` relative to cwd.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LINTER="$REPO_ROOT/.gaia/scripts/lint-hook-array-guard.sh"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# fixture_hook <body>: a tmp repo with one .claude/hooks/probe.sh holding <body>.
# Sets $TMP. Run the linter from $TMP so its cwd-relative SCAN_GLOB resolves.
fixture_hook() {
  TMP="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TMP/.claude/hooks"
  printf '%s\n' "$1" > "$TMP/.claude/hooks/probe.sh"
}

# ---------------------------------------------------------------------------
# 1. The real hooks tree is clean (regression gate)
# ---------------------------------------------------------------------------

@test "the real .claude/hooks tree passes the lint" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. The detector fires on an unguarded bare expansion under set -u
# ---------------------------------------------------------------------------

@test "flags an unguarded bare \${arr[@]} under set -u" {
  fixture_hook $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:4" <<<"$output"
  grep -qF -- "unguarded" <<<"$output"
}

@test "flags an unguarded bare \${arr[*]} under set -u" {
  fixture_hook $'#!/usr/bin/env bash\nset -u\narr=()\nprintf "%s\\n" "${arr[*]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/probe.sh:4" <<<"$output"
}

# ---------------------------------------------------------------------------
# 3. Guarded / out-of-scope forms are NOT flagged
# ---------------------------------------------------------------------------

@test "offset-guarded expansion passes" {
  fixture_hook $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" ${arr[@]+"${arr[@]}"}'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "count-guarded expansion passes" {
  fixture_hook $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\n[ "${#arr[@]}" -eq 0 ] || printf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "a bare expansion in a file with no set -u is not scanned" {
  fixture_hook $'#!/usr/bin/env bash\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "a bare expansion in a full-line comment is skipped" {
  fixture_hook $'#!/usr/bin/env bash\nset -u\n# printf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}
