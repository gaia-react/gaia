#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-resolver-singleton.sh -- Check A
# of the state-registry conformance model (foundations task 2.3, design
# analysis/registry-design.md §4.1, DECISIONS.md D-024). CI-runnable: asserts
# exactly one canonical main-root resolver definition exists across tracked
# source PER LANGUAGE -- one `gaia_resolve_main_root` in shell and one
# `resolveMainWorktreeRoot` in TypeScript (task 3.11, DECISIONS.md D-M3-2).
# The narrow "one canonical definition" guard, not the repo-wide "every call
# site uses it" derivation scan.
#
# This suite IS the gate: nothing else in the repo invokes the check, so the
# "real repo" tests below are what actually fail a build when a second
# definition lands.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-resolver-singleton.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-resolver-singleton.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-resolver-singleton.sh
  source "$CHECK"
  FIXTURE_REPOS=()
}

teardown() {
  local d
  for d in "${FIXTURE_REPOS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

# make_fixture_repo <name> <n_shell_definitions> <n_ts_definitions>: a fresh
# git repo under BATS_TEST_TMPDIR with <n_shell_definitions> files each
# defining a gaia_resolve_main_root() function, and <n_ts_definitions> files
# each defining a resolveMainWorktreeRoot const. Both counts are supplied
# because the check is per-language: a fixture exercising one language's count
# must still satisfy the other, or it fails for two reasons at once and proves
# nothing. Returns the repo path on stdout.
make_fixture_repo() {
  local name="$1" n_shell="$2" n_ts="$3"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  local i
  for ((i = 0; i < n_shell; i++)); do
    printf '#!/usr/bin/env bash\ngaia_resolve_main_root() {\n  echo copy_%d\n}\n' "$i" >"$dir/def_$i.sh"
  done
  for ((i = 0; i < n_ts; i++)); do
    printf 'export const resolveMainWorktreeRoot = (cwd: string): string => cwd; // copy_%d\n' "$i" >"$dir/def_$i.ts"
  done
  printf 'fixture\n' >"$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m init
  FIXTURE_REPOS+=("$dir")
  printf '%s' "$dir"
}

@test "structural: check-resolver-singleton.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_resolver_singleton with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_resolver_singleton >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "real repo: exactly one shell resolver definition exists (main-root-lib.sh)" {
  run gaia_check_resolver_singleton "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "main-root-lib.sh" <<<"$output" || return 1
  grep -qF "shell resolver (gaia_resolve_main_root) definitions found: 1" <<<"$output" || return 1
}

@test "real repo: exactly one TypeScript resolver definition exists (state-file.ts)" {
  run gaia_check_resolver_singleton "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "state-file.ts" <<<"$output" || return 1
  grep -qF "typescript resolver (resolveMainWorktreeRoot) definitions found: 1" <<<"$output" || return 1
}

@test "fixture: zero shell definitions fails" {
  local repo
  repo="$(make_fixture_repo zero-shell 0 1)"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 1 ]
  grep -qF "shell resolver (gaia_resolve_main_root) definitions found: 0" <<<"$output" || return 1
}

@test "fixture: a second shell definition fails Check A (never in real tracked source)" {
  local repo
  repo="$(make_fixture_repo two-shell 2 1)"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 1 ]
  grep -qF "shell resolver (gaia_resolve_main_root) definitions found: 2" <<<"$output" || return 1
  grep -qF "def_0.sh" <<<"$output" || return 1
  grep -qF "def_1.sh" <<<"$output" || return 1
}

@test "fixture: zero TypeScript definitions fails" {
  local repo
  repo="$(make_fixture_repo zero-ts 1 0)"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 1 ]
  grep -qF "typescript resolver (resolveMainWorktreeRoot) definitions found: 0" <<<"$output" || return 1
}

@test "fixture: a second TypeScript definition fails Check A" {
  local repo
  repo="$(make_fixture_repo two-ts 1 2)"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 1 ]
  grep -qF "typescript resolver (resolveMainWorktreeRoot) definitions found: 2" <<<"$output" || return 1
  grep -qF "def_0.ts" <<<"$output" || return 1
  grep -qF "def_1.ts" <<<"$output" || return 1
}

@test "fixture: a plain shell call (not a definition) does not count as a second definition" {
  local repo
  repo="$(make_fixture_repo one-shell-one-call 1 1)"
  {
    printf '#!/usr/bin/env bash\nsource ./def_0.sh\nmain_root="$(gaia_resolve_main_root)"\ngaia_resolve_main_root "$dir"\n'
  } >"$repo/caller.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "add caller"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 0 ]
  grep -qF "shell resolver (gaia_resolve_main_root) definitions found: 1" <<<"$output" || return 1
}

@test "fixture: a TypeScript import, re-export, or call is not a second definition" {
  local repo
  repo="$(make_fixture_repo one-ts-one-call 1 1)"
  {
    printf "import {resolveMainWorktreeRoot} from './def_0.js';\n"
    printf 'export {resolveMainWorktreeRoot};\n'
    printf 'const root = resolveMainWorktreeRoot(process.cwd());\n'
  } >"$repo/caller.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "add ts caller"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 0 ]
  grep -qF "typescript resolver (resolveMainWorktreeRoot) definitions found: 1" <<<"$output" || return 1
}
