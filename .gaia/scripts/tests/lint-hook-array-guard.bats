#!/usr/bin/env bats
# Tests for .gaia/scripts/lint-hook-array-guard.sh: the static gate that flags
# unguarded bare "${arr[@]}" / "${arr[*]}" expansions under `set -u`, the bash
# 3.2.57 empty-array abort class the bash-5 bats suites are blind to. The gate
# walks .claude/hooks/**/*.sh recursively, the sourced libraries under lib/
# included, every shipped .gaia/scripts/**/*.sh, and the framework test bash
# under .gaia/tests/**/*.sh.
#
# Two jobs: prove the detector fires on a known-bad fixture in each scanned tree
# (including a subdirectory of each recursive tree, so the walk is covered) and
# stays quiet on each guarded form (offset-guard, count-guard, no-set-u,
# comment), and assert the real scanned tree is clean so a regression fails CI.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
# The linter is invoked as `bash "$LINTER"` from a fixture cwd, matching
# how CI runs it from the repo root; it scans `.claude/hooks/**/*.sh`,
# `.gaia/scripts/**/*.sh` and `.gaia/tests/**/*.sh` relative to cwd.
#
# One asymmetry the fixtures below cover on both sides: whether a file runs
# under `set -u` is read from the file's own text everywhere except
# `.claude/hooks/lib/`, whose modules are sourced into callers that already set
# it. A lib fixture setting nothing is still scanned; a root hook setting
# nothing is still skipped.

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

# fixture_test_script <relpath> <body>: a tmp repo with one .gaia/tests/<relpath>
# holding <body>. Sets $TMP. <relpath> may name a subdirectory so the recursive
# walk is exercised. Run the linter from $TMP so its cwd-relative scan resolves.
fixture_test_script() {
  TMP="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TMP/.gaia/tests/$(dirname "$1")"
  printf '%s\n' "$2" > "$TMP/.gaia/tests/$1"
}

# 1. The real scanned tree is clean (regression gate)

@test "the real scanned tree (.claude/hooks + .gaia/scripts + .gaia/tests) passes the lint" {
  run bash -c "cd '$REPO_ROOT' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 2. The detector fires on an unguarded bare expansion under set -u

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

# 3. Guarded / out-of-scope forms are NOT flagged

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

# 4. The widened surface: .gaia/scripts/** is scanned too, recursively

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

# 5. The framework test bash under .gaia/tests/** is scanned too, recursively.
# It runs under the same stock macOS /bin/bash a contributor invokes it with, so
# the abort class is identical there; the bash-5 bats suites cannot see it, and
# the sharder that class first bit is itself one of these files.

@test "flags an unguarded bare \${arr[@]} in a .gaia/tests file under set -u" {
  fixture_test_script probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/tests/probe.sh:4" <<<"$output"
  grep -qF -- "unguarded" <<<"$output"
}

@test "recurses into .gaia/tests subdirectories" {
  fixture_test_script sub/deep.sh $'#!/usr/bin/env bash\nset -u\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".gaia/tests/sub/deep.sh:4" <<<"$output"
}

@test "an offset-guarded expansion in a .gaia/tests file passes" {
  fixture_test_script probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" ${arr[@]+"${arr[@]}"}'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

# 6. The sourced libraries under .claude/hooks/lib/ are scanned too, recursively.
#
# They are function modules sourced into hooks running `set -euo pipefail`, so
# `set -u` is in effect for their code at runtime whether or not the file sets
# it itself. scan_file's precondition asks whether the FILE sets `set -u`, the
# right question for a standalone script and the wrong one for a sourced
# module, so lib/ is exempt from it. Two of the cases below carry that split:
# one lib that sets `set -u` and one that does not, because only the second
# distinguishes the exemption from the walk, and the last case pins the
# exemption's boundary by asserting a root hook is still held to the
# precondition.

# fixture_lib <relpath> <body>: a tmp repo with one .claude/hooks/lib/<relpath>
# holding <body>. Sets $TMP. <relpath> may name a subdirectory so the recursive
# walk is exercised. Run the linter from $TMP so its cwd-relative scan resolves.
fixture_lib() {
  TMP="$(mktemp -d -t array-guard-lint-XXXXXX)"
  mkdir -p "$TMP/.claude/hooks/lib/$(dirname "$1")"
  printf '%s\n' "$2" > "$TMP/.claude/hooks/lib/$1"
}

@test "flags an unguarded bare \${arr[@]} in a .claude/hooks/lib file that sets set -u" {
  fixture_lib probe.sh $'#!/usr/bin/env bash\nset -euo pipefail\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/lib/probe.sh:4" <<<"$output"
  grep -qF -- "unguarded" <<<"$output"
}

@test "flags an unguarded bare \${arr[@]} in a .claude/hooks/lib file that sets no set -u of its own" {
  fixture_lib inherits.sh $'#!/usr/bin/env bash\n# shellcheck shell=bash\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/lib/inherits.sh:4" <<<"$output"
  grep -qF -- "unguarded" <<<"$output"
}

@test "recurses into .claude/hooks subdirectories" {
  fixture_lib sub/deep.sh $'#!/usr/bin/env bash\nset -u\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 1 ]
  grep -qF -- ".claude/hooks/lib/sub/deep.sh:4" <<<"$output"
}

@test "an offset-guarded expansion in a .claude/hooks/lib file passes" {
  fixture_lib probe.sh $'#!/usr/bin/env bash\narr=()\nprintf "%s\\n" ${arr[@]+"${arr[@]}"}'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "a count-guarded expansion in a .claude/hooks/lib file passes" {
  fixture_lib probe.sh $'#!/usr/bin/env bash\narr=()\n[ "${#arr[@]}" -eq 0 ] || printf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "a bare expansion in a full-line comment in a .claude/hooks/lib file is skipped" {
  fixture_lib probe.sh $'#!/usr/bin/env bash\n# printf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}

@test "a root .claude/hooks script with no set -u of its own is still not scanned" {
  fixture_hook $'#!/usr/bin/env bash\narr=()\nprintf "%s\\n" "${arr[@]}"'
  run bash -c "cd '$TMP' && bash '$LINTER'"
  [ "$status" -eq 0 ]
}
