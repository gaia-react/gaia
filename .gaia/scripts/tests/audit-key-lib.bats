#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/audit-key-lib.sh (task 4.1,
# analysis/task-4.1-audit-key-design.md §2a-2c): the one function computing
# "<base-sha>.<branch-slug>", the key that partitions Code Audit Team
# findings sidecars and the re-run ledger across worktrees. Two worktrees cut
# from the same main tip compute an IDENTICAL base sha but never the same
# branch (git forbids checking out one branch in two worktrees at once), so
# the branch is the discriminator this key adds.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/audit-key-lib.bats`.
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; equality/numeric/empty checks use POSIX
# `[ ... ]`, which fails correctly on every bash version.

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/audit-key-lib.sh"
  # shellcheck disable=SC1090
  source "$LIB"
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

# make_repo [branch]: a fresh repo, one commit, checked out on [branch]
# (default "main"). Sets REPO and BASE (the commit sha both trees fork from
# in the linked-worktree test below).
make_repo() {
  local branch="${1:-main}"
  local raw
  raw=$(mktemp -d -t gaia-akl-repo-XXXXXX)
  REPO="$(cd "$raw" && pwd -P)"
  CLEANUP_DIRS+=("$REPO")
  git -C "$REPO" init -q --initial-branch="$branch"
  git_identity "$REPO"
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
  BASE="$(git -C "$REPO" rev-parse HEAD)"
}

# ========== source-time purity ==========

@test "sourcing the lib has no side effects: succeeds under set -u with no git repo and no external PATH" {
  scratch="$BATS_TEST_TMPDIR/no-side-effects"
  mkdir -p "$scratch"
  run bash -c "cd '$scratch' && PATH='' && set -u && source '$LIB' && echo sourced-ok"
  [ "$status" -eq 0 ]
  grep -qF "sourced-ok" <<<"$output"
  [ -z "$(ls -A "$scratch")" ]
}

@test "structural: sourcing the lib defines gaia_audit_key" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_audit_key >/dev/null
    echo OK
  ' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ========== gaia_audit_key: the happy path ==========

@test "a plain branch (already in [A-Za-z0-9_-]) passes through unchanged" {
  make_repo "worktree-program"
  run gaia_audit_key "$BASE" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "${BASE}.worktree-program" ]
}

@test "a slash and a dot in the branch both percent-encode" {
  make_repo "release/1.2"
  run gaia_audit_key "$BASE" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "${BASE}.release%2F1%2E2" ]
}

@test "a percent sign in the branch percent-encodes (so the encoding is self-escaping)" {
  make_repo "main"
  git -C "$REPO" branch "has%percent"
  git -C "$REPO" checkout -q "has%percent"
  run gaia_audit_key "$BASE" "$REPO"
  [ "$status" -eq 0 ]
  [ "$output" = "${BASE}.has%25percent" ]
}

@test "determinism: the same base and dir yield the same key on two independent calls" {
  make_repo "worktree-program"
  first="$(gaia_audit_key "$BASE" "$REPO")"
  second="$(gaia_audit_key "$BASE" "$REPO")"
  [ -n "$first" ]
  [ "$first" = "$second" ]
}

@test "dir defaults to '.': omitting the second argument uses the process cwd" {
  make_repo "worktree-program"
  out="$(cd "$REPO" && gaia_audit_key "$BASE")"
  [ "$out" = "${BASE}.worktree-program" ]
}

# ========== fail-open: either half undeterminable ==========

@test "a missing base fails non-zero and prints nothing, even with a resolvable branch" {
  make_repo "main"
  run gaia_audit_key "" "$REPO"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a detached HEAD fails non-zero and prints nothing, even with a resolvable base" {
  make_repo "main"
  git -C "$REPO" checkout -q "$BASE"
  run gaia_audit_key "$BASE" "$REPO"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "a dir outside any git repository fails non-zero and prints nothing" {
  local nongit
  nongit=$(mktemp -d -t gaia-akl-nongit-XXXXXX)
  CLEANUP_DIRS+=("$nongit")
  run gaia_audit_key "deadbeef" "$nongit"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ========== the defect, expressed as a unit ==========

@test "two real linked worktrees off one base produce DIFFERENT keys from the SAME base sha" {
  make_repo "main"
  git -C "$REPO" branch tree-a "$BASE"
  git -C "$REPO" branch tree-b "$BASE"
  local wt_a wt_b
  wt_a="$BATS_TEST_TMPDIR/wt-a"
  wt_b="$BATS_TEST_TMPDIR/wt-b"
  git -C "$REPO" worktree add -q "$wt_a" tree-a
  git -C "$REPO" worktree add -q "$wt_b" tree-b

  key_a="$(gaia_audit_key "$BASE" "$wt_a")"
  key_b="$(gaia_audit_key "$BASE" "$wt_b")"

  [ -n "$key_a" ]
  [ -n "$key_b" ]
  [ "$key_a" != "$key_b" ]
  [ "$key_a" = "${BASE}.tree-a" ]
  [ "$key_b" = "${BASE}.tree-b" ]
}

# ========== structural hygiene ==========

@test "structural: never invokes cd, per .claude/rules/shell-cwd.md" {
  code_lines="$(grep -vE '^[[:space:]]*#' "$LIB")"
  grep -qE '(^|[^[:alnum:]_])cd([^[:alnum:]_]|$)' <<<"$code_lines" && return 1
  return 0
}

@test "structural: no hardcoded /Users or /home paths" {
  grep -E '/Users/|/home/' "$LIB" && return 1
  return 0
}

@test "structural: shellcheck is clean" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not available"
  shellcheck "$LIB"
}
