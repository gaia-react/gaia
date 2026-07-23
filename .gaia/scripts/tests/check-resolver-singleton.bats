#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-resolver-singleton.sh -- Check A
# of the state-registry conformance model (foundations task 2.3, design
# analysis/registry-design.md §4.1, DECISIONS.md D-024). CI-runnable: asserts
# exactly one `gaia_resolve_main_root` function definition exists across
# tracked source. The narrow "one canonical definition" guard, not the
# repo-wide "every call site uses it" derivation scan (that stays red until
# Phase 3, PROGRAM.md §2 gate).
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

# make_fixture_repo <name> <n_definitions>: a fresh git repo under
# BATS_TEST_TMPDIR with <n_definitions> files, each defining a
# gaia_resolve_main_root() function. Returns the repo path on stdout.
make_fixture_repo() {
  local name="$1" n="$2"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  local i
  for ((i = 0; i < n; i++)); do
    printf '#!/usr/bin/env bash\ngaia_resolve_main_root() {\n  echo copy_%d\n}\n' "$i" >"$dir/def_$i.sh"
  done
  [ "$n" -eq 0 ] && printf 'no definitions here\n' >"$dir/README.md"
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

@test "real repo: exactly one gaia_resolve_main_root definition exists (main-root-lib.sh)" {
  run gaia_check_resolver_singleton "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "main-root-lib.sh" <<<"$output" || return 1
  grep -qF "gaia_resolve_main_root definitions found: 1" <<<"$output" || return 1
}

@test "fixture: zero definitions fails" {
  local repo
  repo="$(make_fixture_repo zero-defs 0)"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 1 ]
  grep -qF "gaia_resolve_main_root definitions found: 0" <<<"$output" || return 1
}

@test "fixture: a second gaia_resolve_main_root definition fails Check A (never in real tracked source)" {
  local repo
  repo="$(make_fixture_repo two-defs 2)"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 1 ]
  grep -qF "gaia_resolve_main_root definitions found: 2" <<<"$output" || return 1
  grep -qF "def_0.sh" <<<"$output" || return 1
  grep -qF "def_1.sh" <<<"$output" || return 1
}

@test "fixture: a plain call (not a definition) does not count as a second definition" {
  local repo
  repo="$(make_fixture_repo one-def-one-call 1)"
  {
    printf '#!/usr/bin/env bash\nsource ./def_0.sh\nmain_root="$(gaia_resolve_main_root)"\ngaia_resolve_main_root "$dir"\n'
  } >"$repo/caller.sh"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "add caller"
  run gaia_check_resolver_singleton "$repo"
  [ "$status" -eq 0 ]
  grep -qF "gaia_resolve_main_root definitions found: 1" <<<"$output" || return 1
}
