#!/usr/bin/env bats
#
# Bats suite for .gaia/scripts/create-worktree.sh (the WorktreeCreate hook).
#
# Regression guard for the stdin payload contract. The harness sends the
# worktree name under `.name` (older/HTTP hook variants used `.worktree_name`)
# and carries NO base ref or target path, so the hook derives both. Each test
# pipes a payload into the hook against a throwaway git repo and asserts the
# emitted path, the branch, and the derived base.
#
# Assertion style follows .claude/rules/bats-assertions.md: POSIX `[ ]` for
# equality/status, `grep -qF` for substrings, explicit `return 1` branches.

setup() {
  # Resolve the script under test relative to this file (repo-root agnostic).
  SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SCRIPT="$SCRIPT_DIR/create-worktree.sh"

  # Canonicalize via `pwd -P`: macOS resolves /var -> /private/var inside
  # `git rev-parse`, and the hook prints absolute paths from the canonical form.
  TMPROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/gaia-create-wt-XXXXXX")"
  TMPROOT="$(cd "$TMPROOT_RAW" && pwd -P)"
  MAIN="$TMPROOT/main"

  export GIT_AUTHOR_NAME="GAIA Test"
  export GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test"
  export GIT_COMMITTER_EMAIL="gaia-test@example.com"

  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  # Force the initial branch so tests don't depend on init.defaultBranch.
  git -C "$MAIN" symbolic-ref HEAD refs/heads/main

  # Stub link-worktree.sh so the hook's post-create delegation runs without the
  # real symlink logic (covered by link-worktree.bats). It drops a marker in the
  # worktree so a test can assert the delegation fired. Committed so it appears
  # in the created worktree's checkout.
  mkdir -p "$MAIN/.gaia/scripts"
  cat > "$MAIN/.gaia/scripts/link-worktree.sh" <<'STUB'
#!/usr/bin/env bash
: > "$PWD/.link-ran"
STUB
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m "init"
}

teardown() {
  if [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ]; then
    rm -rf "$TMPROOT"
  fi
  if [ -n "${TMPROOT_RAW:-}" ] && [ "$TMPROOT_RAW" != "${TMPROOT:-}" ] && [ -d "$TMPROOT_RAW" ]; then
    rm -rf "$TMPROOT_RAW"
  fi
}

# Run the hook with cwd inside the main checkout; combined stdout+stderr in
# $output (used for asserting error messages).
run_hook() {
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3"' _ "$MAIN" "$1" "$SCRIPT"
}

# Same, but discard stderr so $output is exactly the hook's stdout. The harness
# consumes stdout as the worktree path, so this asserts the clean-path contract.
run_hook_stdout() {
  run bash -c 'cd "$1" && printf "%s" "$2" | bash "$3" 2>/dev/null' _ "$MAIN" "$1" "$SCRIPT"
}

# ---------- 1. Current contract: name under `.name` ----------
@test "name field: prints worktree path, creates branch, runs link delegate" {
  run_hook_stdout '{"name":"alpha"}'
  [ "$status" -eq 0 ]
  # stdout is exactly the worktree path under .claude/worktrees/.
  [ "$output" = "$MAIN/.claude/worktrees/alpha" ]
  # Worktree is registered with git.
  git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $MAIN/.claude/worktrees/alpha"
  # Branch was created.
  git -C "$MAIN" show-ref --verify --quiet refs/heads/alpha
  # The post-create link-worktree delegation ran inside the worktree.
  [ -f "$MAIN/.claude/worktrees/alpha/.link-ran" ]
}

# ---------- 2. Legacy contract: name under `.worktree_name` ----------
@test "legacy worktree_name field: still creates the worktree" {
  run_hook_stdout '{"worktree_name":"legacy"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$MAIN/.claude/worktrees/legacy" ]
  git -C "$MAIN" show-ref --verify --quiet refs/heads/legacy
}

# ---------- 3. `.name` wins when both keys are present ----------
@test "name takes precedence over worktree_name" {
  run_hook_stdout '{"name":"primary","worktree_name":"legacy"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$MAIN/.claude/worktrees/primary" ]
  git -C "$MAIN" show-ref --verify --quiet refs/heads/primary
  if git -C "$MAIN" show-ref --verify --quiet refs/heads/legacy; then return 1; fi
}

# ---------- 4. Missing name aborts (the reported failure) ----------
@test "missing name: exits non-zero with the missing-name error" {
  run_hook '{}'
  [ "$status" -ne 0 ]
  grep -qF "missing worktree_name" <<<"$output"
}

# ---------- 5. Empty name string aborts (jq // does not fall back on "") ----------
@test "empty name string: exits non-zero" {
  run_hook '{"name":""}'
  [ "$status" -ne 0 ]
  grep -qF "missing worktree_name" <<<"$output"
}

# ---------- 6. Path-traversal guard: `..` ----------
@test "name containing .. is rejected before any creation" {
  run_hook '{"name":"../evil"}'
  [ "$status" -ne 0 ]
  grep -qF "must not contain" <<<"$output"
  [ ! -e "$TMPROOT/evil" ]
}

# ---------- 7. Path-traversal guard: absolute path ----------
@test "absolute name is rejected" {
  run_hook '{"name":"/tmp/evil"}'
  [ "$status" -ne 0 ]
  grep -qF "must not contain" <<<"$output"
}

# ---------- 8. Internal slash is allowed (nested worktree + branch) ----------
@test "internal slash name: creates a nested worktree and slashed branch" {
  run_hook_stdout '{"name":"feat/x"}'
  [ "$status" -eq 0 ]
  [ "$output" = "$MAIN/.claude/worktrees/feat/x" ]
  [ -d "$MAIN/.claude/worktrees/feat/x" ]
  git -C "$MAIN" show-ref --verify --quiet refs/heads/feat/x
}

# ---------- 9. Collision cleanup: never destroy a worktree this run didn't create ----------
@test "name collision with a live worktree: fails without destroying it" {
  # First run creates the worktree a peer session would be sitting in.
  run_hook_stdout '{"name":"alpha"}'
  [ "$status" -eq 0 ]
  wt="$MAIN/.claude/worktrees/alpha"

  # Uncommitted work in that worktree: exactly what a force-remove would destroy.
  printf 'precious\n' > "$wt/precious.txt"

  # Second run collides on the same name, so both `worktree add` attempts fail.
  run_hook '{"name":"alpha"}'
  [ "$status" -ne 0 ]
  grep -qF "git worktree add failed" <<<"$output"
  grep -qF "was not created by this run" <<<"$output"

  # The colliding worktree, its uncommitted work, and its branch all survive.
  [ -f "$wt/precious.txt" ]
  [ "$(cat "$wt/precious.txt")" = "precious" ]
  git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $wt"
  git -C "$MAIN" show-ref --verify --quiet refs/heads/alpha
}

# ---------- 10. Collision cleanup: a pre-existing plain directory is not ours either ----------
@test "collision with a pre-existing non-worktree directory: leaves it intact" {
  wt="$MAIN/.claude/worktrees/beta"
  mkdir -p "$wt"
  printf 'user data\n' > "$wt/keep.txt"

  run_hook '{"name":"beta"}'
  [ "$status" -ne 0 ]

  # `worktree remove --force` fails here (not a worktree), so today's fallback
  # `rm -rf` is what would eat the directory. It must not run.
  [ -f "$wt/keep.txt" ]
  [ "$(cat "$wt/keep.txt")" = "user data" ]
}

# ---------- 11. Collision cleanup: the loser of a race must not clean up the winner ----------
@test "concurrent runs on the same name: the winner's worktree survives" {
  # Two sessions launching on the same name at once. Only one `worktree add` can
  # win; the loser's cleanup must not remove what the winner just created. The
  # pre-add existence sample cannot see this: the winner registers the path
  # inside the loser's check-to-add window.
  for i in 1 2 3 4 5; do
    name="race$i"
    wt="$MAIN/.claude/worktrees/$name"

    (cd "$MAIN" && printf '{"name":"%s"}' "$name" | bash "$SCRIPT" >/dev/null 2>&1) &
    pid_a=$!
    (cd "$MAIN" && printf '{"name":"%s"}' "$name" | bash "$SCRIPT" >/dev/null 2>&1) &
    pid_b=$!

    status_a=0; wait "$pid_a" || status_a=$?
    status_b=0; wait "$pid_b" || status_b=$?

    # Whichever run won, its worktree must still be on disk and registered.
    # (If both somehow failed, nothing was created and there is nothing to
    # protect, so the iteration has nothing to assert.)
    if [ "$status_a" -eq 0 ] || [ "$status_b" -eq 0 ]; then
      [ -d "$wt" ]
      git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $wt"
    fi
  done
}

# ---------- 12. Base ref: no remote -> local HEAD ----------
@test "no remote configured: branches from local HEAD" {
  head="$(git -C "$MAIN" rev-parse HEAD)"
  run_hook_stdout '{"name":"local-base"}'
  [ "$status" -eq 0 ]
  [ "$(git -C "$MAIN" rev-parse refs/heads/local-base)" = "$head" ]
}

# ---------- 13. Base ref: origin/HEAD present -> remote default, not local HEAD ----------
@test "with origin/HEAD: branches fresh from the remote default" {
  ORIGIN="$TMPROOT/origin.git"
  git init -q --bare "$ORIGIN"
  git -C "$MAIN" remote add origin "$ORIGIN"
  git -C "$MAIN" push -q origin main
  git -C "$MAIN" remote set-head origin main
  origin_tip="$(git -C "$MAIN" rev-parse refs/remotes/origin/main)"

  # Advance local main beyond origin so "fresh from origin" is observable.
  git -C "$MAIN" commit --allow-empty -q -m "local-only"
  local_tip="$(git -C "$MAIN" rev-parse HEAD)"
  [ "$origin_tip" != "$local_tip" ]

  run_hook_stdout '{"name":"fresh"}'
  [ "$status" -eq 0 ]
  # The new branch is based on origin/main, not the ahead local HEAD.
  [ "$(git -C "$MAIN" rev-parse refs/heads/fresh)" = "$origin_tip" ]
}
