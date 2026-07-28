#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-wiki-state-collision.sh.
#
# wiki/.state.json is a single-valued position in commit history that every
# branch advances to its own head. Two branches that both sync collide on
# it, and the collision stops loudly only because git's default three-way
# merge refuses to resolve two changes to the same lines. Nothing in this
# repository authored that refusal, so nothing in it would notice the
# refusal going away. The check is the notice, and it guards the two edits
# that remove it silently: the file ceasing to be tracked, and a `merge`
# attribute routing it to a driver that resolves on its own.
#
# This suite IS the gate: nothing else in the repo invokes the check, so
# the "real repo" test below is what actually fails a build when either
# edit lands (same shape as check-main-root-derivation.bats).
#
# The last test is the non-vacuity proof. It runs a real cross-branch
# collision twice in identical fixtures, differing only in whether a
# `merge=union` attribute is bound to the path, and shows the collision
# conflicting in one and merging clean in the other. Without it this suite
# would only assert that the check reports what git reports, never that
# what git reports decides anything.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-wiki-state-collision.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIR/check-wiki-state-collision.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-wiki-state-collision.sh
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

# make_fixture_repo <name>: a fresh, empty git repo under BATS_TEST_TMPDIR.
# Returns the repo path on stdout.
make_fixture_repo() {
  local name="$1"
  local dir="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$dir"
  git init -q --initial-branch=main "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name T
  git -C "$dir" config commit.gpgsign false
  FIXTURE_REPOS+=("$dir")
  printf '%s' "$dir"
}

# write_state <repo> <sha>: write the state file with <sha> as the recorded
# position. Mirrors the shipped shape closely enough that a three-way merge
# sees the same single changed line the real file presents.
write_state() {
  local dir="$1" sha="$2"
  mkdir -p "$dir/wiki"
  {
    printf '{\n'
    printf '  "version": 1,\n'
    printf '  "last_evaluated_sha": "%s",\n' "$sha"
    printf '  "last_evaluated_at": "2026-01-01T00:00:00Z"\n'
    printf '}\n'
  } >"$dir/wiki/.state.json"
}

commit_fixture() {
  local dir="$1" msg="${2:-fixture}"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "$msg"
}

# make_tracked_state_repo <name> [attributes]: a repo whose state file is
# tracked, optionally with <attributes> written to .gitattributes first.
make_tracked_state_repo() {
  local name="$1" attributes="${2:-}"
  local repo
  repo="$(make_fixture_repo "$name")"
  [ -n "$attributes" ] && printf '%s\n' "$attributes" >"$repo/.gitattributes"
  write_state "$repo" aaaaaaa
  commit_fixture "$repo" "seed"
  printf '%s' "$repo"
}

# collide <repo>: branch twice off HEAD, advance the recorded sha
# differently on each, land the first, then attempt to land the second.
# Leaves the second merge's exit status in $status via `run`.
collide() {
  local repo="$1"
  git -C "$repo" checkout -q -b treeA
  write_state "$repo" aaaabbb
  commit_fixture "$repo" "wiki: sync through a"
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b treeB main
  write_state "$repo" ccccddd
  commit_fixture "$repo" "wiki: sync through b"
  git -C "$repo" checkout -q main
  git -C "$repo" merge -q --no-ff -m "merge A" treeA
  run git -C "$repo" merge --no-ff -m "merge B" treeB
}

@test "structural: check-wiki-state-collision.sh is executable" {
  [ -x "$CHECK" ]
}

@test "structural: sourcing the script defines gaia_check_wiki_state_collision with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_wiki_state_collision >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "real repo: the state file is tracked and no merge driver resolves it" {
  run gaia_check_wiki_state_collision "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF "wiki state file tracked: yes" <<<"$output" || return 1
  grep -qF "wiki state merge attribute: unspecified (loud)" <<<"$output" || return 1
}

@test "fixture: a tracked state file with no attributes passes" {
  local repo
  repo="$(make_tracked_state_repo clean)"
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 0 ]
  grep -qF "wiki state file tracked: yes" <<<"$output" || return 1
  grep -qF "wiki state merge attribute: unspecified (loud)" <<<"$output" || return 1
}

@test "fixture: a state file present but never added fails and names the path" {
  local repo
  repo="$(make_fixture_repo untracked)"
  printf 'seed\n' >"$repo/seed.txt"
  commit_fixture "$repo" "seed"
  write_state "$repo" aaaaaaa
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 1 ]
  grep -qF "wiki state file tracked: no" <<<"$output" || return 1
  grep -qF "wiki/.state.json" <<<"$output" || return 1
}

@test "fixture: a gitignored state file fails" {
  local repo
  repo="$(make_fixture_repo ignored)"
  printf 'wiki/.state.json\n' >"$repo/.gitignore"
  write_state "$repo" aaaaaaa
  commit_fixture "$repo" "seed"
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 1 ]
  grep -qF "wiki state file tracked: no" <<<"$output" || return 1
}

@test "fixture: an absent state file fails" {
  local repo
  repo="$(make_fixture_repo absent)"
  printf 'seed\n' >"$repo/seed.txt"
  commit_fixture "$repo" "seed"
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 1 ]
  grep -qF "wiki state file tracked: no" <<<"$output" || return 1
}

@test "fixture: a union merge driver bound to the state file fails and names it" {
  local repo
  repo="$(make_tracked_state_repo union-driver 'wiki/.state.json merge=union')"
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 1 ]
  grep -qF "wiki state merge attribute: union (silent)" <<<"$output" || return 1
  grep -qF "wiki/.state.json" <<<"$output" || return 1
}

@test "fixture: a custom merge driver bound to the state file fails" {
  local repo
  repo="$(make_tracked_state_repo custom-driver 'wiki/.state.json merge=keepours')"
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 1 ]
  grep -qF "wiki state merge attribute: keepours (silent)" <<<"$output" || return 1
}

@test "fixture: a wildcard attribute reaching the state file fails" {
  local repo
  repo="$(make_tracked_state_repo wildcard-driver '*.json merge=union')"
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 1 ]
  grep -qF "wiki state merge attribute: union (silent)" <<<"$output" || return 1
}

@test "fixture: -merge passes, because git still declares the merge conflicted" {
  local repo
  repo="$(make_tracked_state_repo unset-merge 'wiki/.state.json -merge')"
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 0 ]
  grep -qF "wiki state merge attribute: unset (loud)" <<<"$output" || return 1
}

@test "fixture: an ordinary text=auto attributes file does not false-fire" {
  local repo
  repo="$(make_tracked_state_repo text-auto '* text=auto')"
  run gaia_check_wiki_state_collision "$repo"
  [ "$status" -eq 0 ]
  grep -qF "wiki state merge attribute: unspecified (loud)" <<<"$output" || return 1
  grep -qF "(silent)" <<<"$output" && return 1
  return 0
}

@test "non-vacuity: the attribute the check rejects is what turns a real collision silent" {
  local loud quiet
  loud="$(make_tracked_state_repo collision-loud)"
  collide "$loud"
  # Default attributes: git refuses two changes to the same lines.
  [ "$status" -ne 0 ]
  grep -qF 'CONFLICT' <<<"$output" || return 1

  quiet="$(make_tracked_state_repo collision-silent 'wiki/.state.json merge=union')"
  collide "$quiet"
  # One attribute later, the identical collision lands with no conflict and
  # the file holds both sides' values at once.
  [ "$status" -eq 0 ]
  grep -qF 'CONFLICT' <<<"$output" && return 1
  grep -qF 'aaaabbb' "$quiet/wiki/.state.json" || return 1
  grep -qF 'ccccddd' "$quiet/wiki/.state.json" || return 1

  # And the check tells the two repositories apart.
  run gaia_check_wiki_state_collision "$loud"
  [ "$status" -eq 0 ]
  run gaia_check_wiki_state_collision "$quiet"
  [ "$status" -eq 1 ]
}
