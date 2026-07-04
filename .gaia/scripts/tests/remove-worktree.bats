#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/remove-worktree.sh (the WorktreeRemove hook).
#
# Registering a WorktreeRemove hook replaces the harness's native removal, so
# this script owns the full teardown: remove the worktree, delete its branch,
# and prune empty parent dirs under .claude/worktrees/. The harness fires it
# with cwd INSIDE the worktree being removed and the path in `.worktree_path`.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/remove-worktree.sh"

  TMPROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/gaia-remove-wt-XXXXXX")"
  TMPROOT="$(cd "$TMPROOT_RAW" && pwd -P)"
  MAIN="$TMPROOT/main"
  BASE="$MAIN/.claude/worktrees"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" symbolic-ref HEAD refs/heads/main
  git -C "$MAIN" commit --allow-empty -q -m "init"
}

teardown() {
  if [ -n "${MAIN:-}" ] && [ -d "$MAIN/.git" ]; then
    git -C "$MAIN" worktree list --porcelain 2>/dev/null \
      | awk '/^worktree /{print $2}' \
      | while read -r wt; do
          [ "$wt" = "$MAIN" ] || git -C "$MAIN" worktree remove --force "$wt" 2>/dev/null || true
        done
  fi
  if [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ]; then rm -rf "$TMPROOT"; fi
  if [ -n "${TMPROOT_RAW:-}" ] && [ "$TMPROOT_RAW" != "${TMPROOT:-}" ] && [ -d "$TMPROOT_RAW" ]; then rm -rf "$TMPROOT_RAW"; fi
}

# Create a worktree named $1 (branch == dir). Pass "detach" as $2 for detached.
mk_wt() {
  if [ "${2:-}" = "detach" ]; then
    git -C "$MAIN" worktree add -q --detach "$BASE/$1" HEAD
  else
    git -C "$MAIN" worktree add -q "$BASE/$1" -b "$1"
  fi
}

# Run the hook: $1 = payload JSON, $2 = cwd (default: main checkout).
run_remove() {
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' _ "${2:-$MAIN}" "$1" "$SCRIPT"
}

# ---------- 1. Happy path: removes worktree, deletes branch ----------
@test "removes the worktree and deletes its branch" {
  mk_wt alpha
  [ -d "$BASE/alpha" ]

  run_remove "{\"worktree_path\":\"$BASE/alpha\"}"
  [ "$status" -eq 0 ]
  [ ! -d "$BASE/alpha" ]
  if git -C "$MAIN" worktree list --porcelain | grep -qF "worktree $BASE/alpha"; then return 1; fi
  if git -C "$MAIN" show-ref --verify --quiet refs/heads/alpha; then return 1; fi
  # The shared worktrees root is never removed.
  [ -d "$BASE" ]
}

# ---------- 2. Production cwd: hook runs from inside the worktree ----------
@test "completes when cwd is the worktree being removed (cwd deleted mid-run)" {
  mk_wt beta
  # The harness fires the hook with cwd inside the worktree; the script file
  # itself lives in the main checkout, so it survives the directory's deletion.
  run_remove "{\"worktree_path\":\"$BASE/beta\"}" "$BASE/beta"
  [ "$status" -eq 0 ]
  [ ! -d "$BASE/beta" ]
  if git -C "$MAIN" show-ref --verify --quiet refs/heads/beta; then return 1; fi
}

# ---------- 3. Branch is read from git, not assumed from the dir name ----------
@test "deletes the actual checked-out branch, not the directory name" {
  git -C "$MAIN" worktree add -q "$BASE/dir-name" -b real-branch
  run_remove "{\"worktree_path\":\"$BASE/dir-name\"}"
  [ "$status" -eq 0 ]
  [ ! -d "$BASE/dir-name" ]
  if git -C "$MAIN" show-ref --verify --quiet refs/heads/real-branch; then return 1; fi
}

# ---------- 4. Missing worktree_path aborts ----------
@test "missing worktree_path: exits non-zero" {
  run_remove '{}'
  [ "$status" -ne 0 ]
  grep -qF "missing worktree_path" <<<"$output"
}

# ---------- 5. Already-gone worktree is idempotent ----------
@test "unregistered / already-removed path: exits 0 without error" {
  run_remove "{\"worktree_path\":\"$BASE/ghost\"}"
  [ "$status" -eq 0 ]
}

# ---------- 6. Detached-HEAD worktree: removed, no branch to delete ----------
@test "detached HEAD worktree: removed cleanly with no branch deletion" {
  mk_wt detached detach
  run_remove "{\"worktree_path\":\"$BASE/detached\"}"
  [ "$status" -eq 0 ]
  [ ! -d "$BASE/detached" ]
}

# ---------- 7. Nested slash name: empty parent dir is pruned ----------
@test "nested slash name: prunes the empty parent dir but keeps the root" {
  mk_wt "feat/nested"
  [ -d "$BASE/feat/nested" ]
  run_remove "{\"worktree_path\":\"$BASE/feat/nested\"}"
  [ "$status" -eq 0 ]
  [ ! -d "$BASE/feat/nested" ]
  [ ! -d "$BASE/feat" ]
  if git -C "$MAIN" show-ref --verify --quiet refs/heads/feat/nested; then return 1; fi
  # The shared worktrees root survives the prune walk.
  [ -d "$BASE" ]
}
