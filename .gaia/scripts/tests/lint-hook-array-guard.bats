#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-hook-array-guard.sh: the static gate that flags
# unguarded bare "${arr[@]}" / "${arr[*]}" expansions under `set -u`, the bash
# 3.2.57 empty-array abort class the bash-5 bats suites are blind to. The gate
# scans the .claude/hooks bodies and every shipped .gaia/scripts/**/*.sh.
#
# Two jobs: prove the detector fires on a known-bad fixture in each scanned tree
# (including a .gaia/scripts subdirectory, so the recursive walk is covered) and
# stays quiet on each guarded form (offset-guard, count-guard, no-set-u,
# comment), and assert the real scanned tree is clean so a regression fails CI.
#
# Assertion style (.claude/rules/bats-assertions.md): grep -qF / [ ] / explicit
# return 1, never a bare [[ ]] as a non-final line. The linter is invoked as
# `bash "$LINTER"` from a fixture cwd, matching how CI runs it from the repo
# root; it scans `.claude/hooks/*.sh` and `.gaia/scripts/**/*.sh` relative to cwd.

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
# Sets $TMP. Run the linter from $TMP so its cwd-relative scan resolves.
fixture_hook() {
  TMP="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TMP/.claude/hooks"
  printf '%s\n' "$1" > "$TMP/.claude/hooks/probe.sh"
}

# fixture_script <relpath> <body>: a tmp repo with one .gaia/scripts/<relpath>
# holding <body>. Sets $TMP. <relpath> may name a subdirectory so the recursive
# walk is exercised. Run the linter from $TMP so its cwd-relative scan resolves.
fixture_script() {
  TMP="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TMP/.gaia/scripts/$(dirname "$1")"
  printf '%s\n' "$2" > "$TMP/.gaia/scripts/$1"
}

# ---------------------------------------------------------------------------
# 1. The real scanned tree is clean (regression gate)
# ---------------------------------------------------------------------------

@test "the real scanned tree (.claude/hooks + .gaia/scripts) passes the lint" {
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

# ---------------------------------------------------------------------------
# 4. The widened surface: .gaia/scripts/** is scanned too, recursively
# ---------------------------------------------------------------------------

@test "flags an unguarded bare \${arr[@]} in a .gaia/scripts file under set -u" {
  fixture_script probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/probe.sh:4" <<<"$output"
  grep -qF -- "unguarded" <<<"$output"
}

@test "recurses into .gaia/scripts subdirectories" {
  fixture_script sub/deep.sh $'#!/usr/bin/env bash\nset -u\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/scripts/sub/deep.sh:4" <<<"$output"
}

@test "an offset-guarded expansion in a .gaia/scripts file passes" {
  fixture_script probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" ${arr[@]+"${arr[@]}"}'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}
