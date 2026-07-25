#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/main-only-lib.sh (task 5.3): the shared
# main-only-flow refusal helper /update-gaia, /update-deps, and /gaia-release
# source instead of each carrying its own copy-pasted detection.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/main-only-lib.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.
#
# Fixture idiom matched from main-root-lib.bats (make_repo / make_worktree,
# canonicalized via `pwd -P` since macOS resolves /tmp -> /private/tmp inside
# `git rev-parse` and outputs are compared byte-for-byte) and link-worktree.bats
# (a run_in helper that cds into a tree and runs a script).

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/main-only-lib.sh"
  CLEANUP_DIRS=()
}

teardown() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  return 0
}

git_identity() {
  git -C "$1" config user.email gaia-test@example.com
  git -C "$1" config user.name "GAIA Test"
  git -C "$1" config commit.gpgsign false
}

# make_repo: an ordinary clone. Sets REPO.
make_repo() {
  local raw
  raw=$(mktemp -d -t gaia-mol-repo-XXXXXX)
  REPO="$(cd "$raw" && pwd -P)"
  CLEANUP_DIRS+=("$REPO")
  git -C "$REPO" init -q --initial-branch=main
  git_identity "$REPO"
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
}

# make_worktree <repo> <rel> <branch>: a real linked worktree under
# <repo>/.claude/worktrees/<rel>, mirroring how GAIA creates plan/debt
# worktrees. Sets WT to the worktree's absolute path.
make_worktree() {
  local repo="$1" rel="$2" br="$3"
  git -C "$repo" branch "$br"
  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/$rel" "$br"
  WT="$repo/.claude/worktrees/$rel"
}

# run_in <dir> -- <bash args...>: runs a command with cwd=<dir>.
run_in() {
  local dir="$1"
  shift
  [ "$1" = "--" ] && shift
  ( cd "$dir" && "$@" )
}

# ---------- not a linked worktree ----------

@test "not a linked worktree: returns 0 and prints nothing" {
  make_repo
  run run_in "$REPO" -- bash -c '. "$1"; gaia_refuse_if_worktree "/x"' _ "$LIB"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- linked worktree, resolvable main ----------

@test "linked worktree with resolvable main: returns 1, message names both roots, no state_line_fn given" {
  make_repo
  make_worktree "$REPO" w wtbranch1
  run run_in "$WT" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release"' _ "$LIB"
  [ "$status" -eq 1 ]
  grep -qF -- "/gaia-release must run from the main checkout, not a worktree." <<<"$output" || return 1
  grep -qF -- "Worktree:       $WT" <<<"$output" || return 1
  grep -qF -- "Main checkout:  $REPO" <<<"$output" || return 1
  grep -qF -- "Run \`cd $REPO\` then re-invoke /gaia-release." <<<"$output" || return 1
}

@test "linked worktree, no state_line_fn supplied: no state paragraph at all" {
  make_repo
  make_worktree "$REPO" w wtbranch2
  run run_in "$WT" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release" 2>/dev/null' _ "$LIB"
  [ "$status" -eq 1 ]
  # Byte-exact: no state paragraph, and exactly one blank line separates the
  # roots block from the "Run \`cd\`" line -- not $lines-based, bats' $lines
  # splitting silently drops blank-line entries so it can't prove this.
  local expected
  expected="/gaia-release must run from the main checkout, not a worktree.

Worktree:       $WT
Main checkout:  $REPO

Run \`cd $REPO\` then re-invoke /gaia-release."
  [ "$output" = "$expected" ]
}

@test "linked worktree, state_line_fn prints a line: that line is in the message" {
  make_repo
  make_worktree "$REPO" w wtbranch3
  run run_in "$WT" -- bash -c '
. "$1"
my_state() { printf "Cached on main: GAIA 1.2.3 installed; latest 1.2.3 (update not-available).\n"; }
gaia_refuse_if_worktree "/update-gaia" my_state
' _ "$LIB"
  [ "$status" -eq 1 ]
  grep -qF -- "Cached on main: GAIA 1.2.3 installed; latest 1.2.3 (update not-available)." <<<"$output" || return 1
  # Per .claude/rules/bats-assertions.md: a `<positive> && return 1` absence
  # check is only safe on a non-final line -- as the test's LAST line its own
  # (good-case) exit status of 1 would fail the test. The explicit `return 0`
  # makes the success path's exit status deterministic.
  grep -qF -- "Cached state unavailable" <<<"$output" && return 1
  return 0
}

@test "linked worktree, state_line_fn supplied but prints nothing: shared fallback line is used" {
  make_repo
  make_worktree "$REPO" w wtbranch4
  run run_in "$WT" -- bash -c '
. "$1"
my_state() { :; }
gaia_refuse_if_worktree "/update-deps" my_state
' _ "$LIB"
  [ "$status" -eq 1 ]
  grep -qF -- 'Cached state unavailable on main; symlinks may be broken, run `.gaia/cli/gaia setup link-worktree` to repair.' <<<"$output" || return 1
}

@test "linked worktree, state_line_fn's own cache_file argument is main's cache path, not the worktree's" {
  make_repo
  make_worktree "$REPO" w wtbranch5
  local captured="$BATS_TEST_TMPDIR/cache_file_arg"
  run run_in "$WT" -- bash -c '
. "$1"
captured_path="$2"
my_state() { printf "%s" "$1" > "$captured_path"; }
gaia_refuse_if_worktree "/update-gaia" my_state
' _ "$LIB" "$captured"
  [ "$status" -eq 1 ]
  [ "$(cat "$captured")" = "$REPO/.gaia/local/cache/shared/update-check.json" ]
}

# ---------- unresolvable main (fail-open) ----------

@test "linked worktree, unresolvable main: fails open, returns 0, prints nothing" {
  make_repo
  make_worktree "$REPO" w wtbranch6
  local common_config
  common_config="$(cd "$REPO/.git" && pwd -P)/config"
  git config --file "$common_config" core.worktree "/nonexistent/evil/path"
  # bats' `run` merges stdout+stderr by default, and the resolver's own
  # contract (main-root-lib.sh) writes one diagnostic line to STDERR on this
  # exact failure -- expected, and not this helper's stdout contract. Discard
  # it here (matching main-root-lib.bats' `resolve()` helper) so $output
  # reflects gaia_refuse_if_worktree's own stdout only.
  run run_in "$WT" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release" 2>/dev/null' _ "$LIB"
  git config --file "$common_config" --unset core.worktree || true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- structural ----------

@test "structural: main-only-lib.sh is executable" {
  [ -x "$LIB" ]
}

@test "structural: sourcing the library defines gaia_refuse_if_worktree and the resolver functions, with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_refuse_if_worktree >/dev/null
    type gaia_resolve_main_root >/dev/null
    type gaia_is_linked_worktree >/dev/null
    type gaia_resolve_tree_root >/dev/null
    echo OK
  ' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "structural: sourcing main-root-lib.sh first, then this file, does not error (guarded re-source)" {
  local mrl
  mrl="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/main-root-lib.sh"
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    # shellcheck disable=SC1090
    source "$2"
    type gaia_refuse_if_worktree >/dev/null
    echo OK
  ' _ "$mrl" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}
