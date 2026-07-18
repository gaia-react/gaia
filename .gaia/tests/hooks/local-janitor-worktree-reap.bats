#!/usr/bin/env bats
#
# Sweep #8 of local-janitor.sh: reap orphaned GAIA worktrees under
# .claude/worktrees/ whose branch upstream is [gone] (the same provable-death
# signal sweep #1 uses for wiki-sync/* branches) and whose working tree is
# clean. Teardown delegates to the WorktreeRemove hook's own
# remove-worktree.sh, so these tests copy the real script into the fixture
# repo at its real repo-relative path, exactly as a real checkout would have
# it, rather than re-deriving remove + branch-delete + parent-prune here.
#
# Conservative provable-death policy: never age-reap, never the current
# checkout, never a worktree with uncommitted changes, never a detached-HEAD
# worktree (no branch to test for [gone]).
#
# Assertion style note: per .claude/rules/bats-assertions.md, non-final
# absence checks use a positive match for the bad case plus an explicit
# `return 1`, never `!`-negation; final-line absence uses `[ ! -e ... ]`.

setup() {
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/local-janitor.sh
  REPO_ROOT_REAL=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${ORIGIN:-}" ] && rm -rf "$ORIGIN"
  return 0
}

# Stand up a repo with a real bare origin so upstream-track state is faithful.
make_repo() {
  ORIGIN=$(mktemp -d -t gaia-janitor-wt-origin-XXXXXX)
  git init -q --bare "$ORIGIN"
  REPO=$(mktemp -d -t gaia-janitor-wt-repo-XXXXXX)
  git -C "$REPO" init -q --initial-branch=main
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" remote add origin "$ORIGIN"
  echo init > "$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
  mkdir -p "$REPO/.gaia/local"
}

# copy_worktree_reaper_deps: mirrors remove-worktree.sh's own repo-relative
# location inside the fixture repo (<main>/.gaia/scripts/remove-worktree.sh)
# so sweep #8's `bash "$wt_main/.gaia/scripts/remove-worktree.sh"` call
# resolves for real instead of silently no-op'ing.
copy_worktree_reaper_deps() {
  mkdir -p "$REPO/.gaia/scripts"
  cp "$REPO_ROOT_REAL/.gaia/scripts/remove-worktree.sh" "$REPO/.gaia/scripts/remove-worktree.sh"
  chmod +x "$REPO/.gaia/scripts/remove-worktree.sh"
}

# A branch whose upstream is [gone]: pushed (tracking ref created), then the
# remote head is deleted and pruned. Mirrors a squash-merged, auto-deleted PR.
make_gone_branch() {
  local br="$1"
  git -C "$REPO" branch "$br"
  git -C "$REPO" push -q -u origin "$br"
  git -C "$REPO" push -q origin --delete "$br"
  git -C "$REPO" fetch -q --prune
}

# A branch with a live, in-sync upstream (tracking ref still present).
make_live_branch() {
  local br="$1"
  git -C "$REPO" branch "$br"
  git -C "$REPO" push -q -u origin "$br"
}

# make_gone_worktree <path> <branch>: a [gone]-upstream branch checked out
# into a real linked worktree at .claude/worktrees/<path>, mirroring how GAIA
# creates plan/debt worktrees.
make_gone_worktree() {
  local rel="$1" br="$2"
  make_gone_branch "$br"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$rel" "$br"
}

# make_live_worktree <path> <branch>: same shape, but the branch's upstream
# is still live (not [gone]).
make_live_worktree() {
  local rel="$1" br="$2"
  make_live_branch "$br"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$rel" "$br"
}

branch_exists() {
  git -C "$REPO" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1
}

@test "reaps a [gone]-branch worktree with a clean working tree" {
  make_repo
  copy_worktree_reaper_deps
  make_gone_worktree "debt/100-foo" "debt/100-foo"
  wt="$REPO/.claude/worktrees/debt/100-foo"
  # Present before the sweep runs, so the reap below is provably real.
  [ -d "$wt" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "debt/100-foo" && return 1
  [ ! -e "$wt" ]
}

@test "keeps a worktree whose branch upstream is still live" {
  make_repo
  copy_worktree_reaper_deps
  make_live_worktree "debt/101-bar" "debt/101-bar"
  wt="$REPO/.claude/worktrees/debt/101-bar"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/101-bar"
}

@test "keeps a [gone]-branch worktree that has uncommitted changes" {
  make_repo
  copy_worktree_reaper_deps
  make_gone_worktree "debt/102-baz" "debt/102-baz"
  wt="$REPO/.claude/worktrees/debt/102-baz"
  echo "dirty" > "$wt/dirty.txt"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/102-baz"
}

# Running the janitor with cwd INSIDE a [gone]-branch worktree: `root`
# resolves to that worktree, so this exercises the actual current-checkout
# guard rather than a stand-in. A real GAIA worktree always carries its own
# .gaia/local (plans/specs/etc land there), so seed one here too -- otherwise
# the janitor's `[ -d "$local_dir" ] || exit 0` guard would exit before ever
# reaching sweep #8, and this test would pass for the wrong reason.
@test "never reaps the current checkout even when its own branch is gone" {
  make_repo
  copy_worktree_reaper_deps
  make_gone_worktree "debt/103-self" "debt/103-self"
  wt="$REPO/.claude/worktrees/debt/103-self"
  mkdir -p "$wt/.gaia/local"
  cd "$wt"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/103-self"
  # Belt-and-suspenders per the brief: the main checkout is never removed.
  [ -d "$REPO" ]
}

@test "leaves a detached-HEAD worktree untouched" {
  make_repo
  copy_worktree_reaper_deps
  sha=$(git -C "$REPO" rev-parse HEAD)
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/detached-104" "$sha"
  wt="$REPO/.claude/worktrees/detached-104"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
}
