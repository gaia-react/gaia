#!/usr/bin/env bats
#
# Sweep #8 of local-janitor.sh: reap orphaned GAIA worktrees under
# .claude/worktrees/ whose branch upstream is [gone] (the same provable-death
# signal sweep #1 uses for wiki-sync/* branches), whose working tree is clean,
# and whose branch is not named by a live RUNNING plan sentinel (gitignored, so
# invisible to both git-level signals). Teardown runs inline in the janitor
# itself: remove the worktree, delete its now-detached branch, and prune the
# empty parent directories a slashed name leaves behind. These tests run
# .claude/hooks/local-janitor.sh directly; nothing else needs to be staged
# into the fixture repo for teardown to happen for real.
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

# make_repo_spaced: identical to make_repo, but REPO's absolute path contains
# a space (e.g. an adopter under ~/My Projects/...). Regression fixture for
# the porcelain path-truncation defect: `git worktree list --porcelain` does
# not quote the path, so a naive awk $2 split truncates at the first space.
make_repo_spaced() {
  ORIGIN=$(mktemp -d -t gaia-janitor-wt-origin-XXXXXX)
  git init -q --bare "$ORIGIN"
  REPO=$(mktemp -d -t 'gaia janitor wt repo XXXXXX')
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

# ignore_local_state: commit the .gitignore entry every real GAIA checkout
# carries for .gaia/local/. Load-bearing for the sentinel tests below: without
# it a RUNNING sentinel written into a worktree shows up as an untracked file,
# sweep #8's clean-working-tree check spares the worktree for that reason, and
# the sentinel guard is never exercised at all.
ignore_local_state() {
  printf '.gaia/local/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore
  git -C "$REPO" commit -q -m "ignore local state"
}

# write_plan_sentinel <root> <plan-rel> <branch>: a RUNNING plan sentinel at
# <root>/.gaia/local/<plan-rel>/RUNNING naming <branch>, the marker GAIA leaves
# for an in-flight execution. An empty <branch> writes a sentinel with no
# parseable `branch:` line.
write_plan_sentinel() {
  local root="$1" rel="$2" br="$3" file
  file="$root/.gaia/local/$rel/RUNNING"
  mkdir -p "$root/.gaia/local/$rel"
  : > "$file"
  if [ -n "$br" ]; then
    printf 'branch: %s\n' "$br" >> "$file"
  fi
  printf 'status: RUNNING\n' >> "$file"
}

@test "reaps a [gone]-branch worktree with a clean working tree" {
  make_repo
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

# The third step of the inline teardown: pruning the empty parent directory a
# slashed worktree name leaves behind. debt/<n>-<slug> is exactly that shape --
# reaping the leaf must not leave an empty "debt/" directory behind, but the
# shared .claude/worktrees/ base itself is never removed even once it is empty.
@test "prunes the empty parent directory left behind by a slashed worktree name" {
  make_repo
  make_gone_worktree "debt/110-prune" "debt/110-prune"
  wt="$REPO/.claude/worktrees/debt/110-prune"
  [ -d "$wt" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ ! -e "$wt" ]
  [ ! -d "$REPO/.claude/worktrees/debt" ]
  [ -d "$REPO/.claude/worktrees" ]
}

# Regression coverage for the teardown's lock-reclaim fallback: a worktree
# left `locked ... initializing` is what a session killed mid-`git worktree
# add` leaves behind, and git refuses a SINGLE --force against it. Only a
# double --force clears it, so a [gone]-branch worktree in this state must
# still be reaped rather than silently surviving every future run.
@test "reaps a [gone]-branch worktree wedged locked-initializing by a crashed add" {
  make_repo
  make_gone_worktree "debt/111-wedged" "debt/111-wedged"
  wt="$REPO/.claude/worktrees/debt/111-wedged"
  admin="$REPO/.git/worktrees/111-wedged"
  [ -d "$admin" ]
  printf 'initializing\n' > "$admin/locked"
  git -C "$REPO" worktree list --porcelain | grep -qF "locked initializing"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "debt/111-wedged" && return 1
  [ ! -e "$wt" ]
}

@test "keeps a worktree whose branch upstream is still live" {
  make_repo
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
  sha=$(git -C "$REPO" rev-parse HEAD)
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/detached-104" "$sha"
  wt="$REPO/.claude/worktrees/detached-104"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
}

# Regression: `git worktree list --porcelain` does not quote the `worktree
# <path>` line, so reading the path as awk's $2 (whitespace-split) truncates
# it at the first space. On a spaced repo path the case guard against
# $wt_base then never matches and the reap silently no-ops -- fail-safe (no
# wrong deletion), but the feature is inoperative for any adopter whose
# checkout lives under a spaced directory.
@test "reaps a [gone]-branch worktree even when the repo's absolute path contains a space" {
  make_repo_spaced
  make_gone_worktree "debt/105-spaced" "debt/105-spaced"
  wt="$REPO/.claude/worktrees/debt/105-spaced"
  [ -d "$wt" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "debt/105-spaced" && return 1
  [ ! -e "$wt" ]
}

# The third guard: a RUNNING plan sentinel is gitignored, so a genuinely live
# session reads as [gone] + clean to both git-level signals above. Scanned in
# both the worktree's own .gaia/local/ and main's: for a properly linked
# worktree these are the same physical directory (.gaia/local is one symlink
# to main's), but a worktree nobody has linked -- provisioning failed, or
# never ran, exactly what this fixture models by never linking `wt` -- still
# has its own real, unconnected .gaia/local, and only the worktree-side scan
# sees a live plan sentinel written there.
@test "keeps a [gone]-branch worktree whose own tree holds a live RUNNING plan" {
  make_repo
  ignore_local_state
  make_gone_worktree "debt/106-live" "debt/106-live"
  wt="$REPO/.claude/worktrees/debt/106-live"
  write_plan_sentinel "$wt" "plans/PLAN-901" "debt/106-live"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/106-live"
}

# The main-checkout half of the same guard, on the colocated
# specs/<SPEC-ID>/plan/ sentinel shape rather than a plans/<slug>/ one.
@test "keeps a [gone]-branch worktree named by a RUNNING plan in the main checkout" {
  make_repo
  ignore_local_state
  make_gone_worktree "debt/107-mainside" "debt/107-mainside"
  wt="$REPO/.claude/worktrees/debt/107-mainside"
  write_plan_sentinel "$REPO" "specs/SPEC-901/plan" "debt/107-mainside"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/107-mainside"
}

# The guard fails toward sparing: a sentinel under the worktree's own tree that
# names no branch still proves something is running there, so it is not reaped.
@test "keeps a [gone]-branch worktree whose own RUNNING sentinel names no branch" {
  make_repo
  ignore_local_state
  make_gone_worktree "debt/108-unparseable" "debt/108-unparseable"
  wt="$REPO/.claude/worktrees/debt/108-unparseable"
  write_plan_sentinel "$wt" "plans/PLAN-902" ""
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/108-unparseable"
}

# The guard is a branch comparison, not a blanket "any sentinel spares
# everything": a live plan on some other branch does not keep this worktree
# alive, so sweep #8 still reclaims a provably-dead one.
@test "reaps a [gone]-branch worktree when the only RUNNING plan names another branch" {
  make_repo
  ignore_local_state
  make_gone_worktree "debt/109-other" "debt/109-other"
  wt="$REPO/.claude/worktrees/debt/109-other"
  write_plan_sentinel "$wt" "plans/PLAN-903" "debt/999-unrelated"
  [ -d "$wt" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "debt/109-other" && return 1
  [ ! -e "$wt" ]
}

# --- UAT-017 / UAT-019: sweep #1's fast-forward, run from a linked worktree,
# and sweep #8's guards under the newly routine [gone] trigger -------------
#
# Sweep #1's own prune-fetch (task-janitor-fetch.md) now runs a real
# `git fetch --prune` whenever ANY wiki-sync/* branch is present, not on some
# rarer schedule -- and that fetch is never tree-scoped: refs and the object
# store are shared across every worktree of the same repo, so it can flip an
# UNRELATED branch's upstream-track to [gone] as a side effect. Sweep #8's
# existing guards (current checkout, dirty tree, live RUNNING sentinel) have
# to keep holding under this now much more frequent trigger.

# push_upstream_then_delete <branch>: creates <branch>, pushes it (tracking
# ref created), then deletes the remote head WITHOUT a local prune -- so its
# upstream-track only flips to [gone] once something else (sweep #1's own
# fetch --prune) resolves it, mirroring UAT-019's premise exactly.
push_upstream_then_delete() {
  local br="$1"
  git -C "$REPO" branch "$br"
  git -C "$REPO" push -q -u origin "$br"
  git -C "$REPO" push -q origin --delete "$br"
}

@test "sweep 1: a worktree invocation leaves main's HEAD unchanged" {
  make_repo
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" remote set-head origin -a
  make_gone_branch "wiki-sync/2026-08-13-6666663"

  # Advance origin/main beyond what REPO's own main currently has, via a
  # throwaway clone so REPO's own history is never touched directly.
  local clone
  clone=$(mktemp -d -t gaia-janitor-wt-adv-XXXXXX)
  git clone -q "$ORIGIN" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name Test
  git -C "$clone" config commit.gpgsign false
  echo advanced >> "$clone/f"
  git -C "$clone" add f
  git -C "$clone" commit -q -m advance
  git -C "$clone" push -q origin main
  rm -rf "$clone"

  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" branch other-work
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/other-work" other-work
  wt="$REPO/.claude/worktrees/other-work"

  main_before=$(git -C "$REPO" rev-parse main)
  cd "$wt"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  # The fetch and the reap are NOT tree-scoped -- refs and the object store
  # are shared, so this invocation, run from the worktree, still fetches and
  # still reaps the wiki-sync branch. What stays scoped is the fast-forward:
  # main's own HEAD, a branch this worktree never has checked out, is
  # untouched, because the merge command only ever targets $root (the
  # worktree), never main's separate checkout.
  branch_exists "wiki-sync/2026-08-13-6666663" && return 1
  [ "$(git -C "$REPO" rev-parse main)" = "$main_before" ]
}

@test "sweep 8: a worktree that is the current checkout survives the newly routine [gone] trigger" {
  make_repo
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" remote set-head origin -a
  make_gone_branch "wiki-sync/2026-08-14-7777774"

  push_upstream_then_delete "debt/300-current"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/debt/300-current" "debt/300-current"
  wt="$REPO/.claude/worktrees/debt/300-current"
  mkdir -p "$wt/.gaia/local"

  cd "$wt"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/300-current"
}

@test "sweep 8: a worktree with a dirty tree survives the newly routine [gone] trigger" {
  make_repo
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" remote set-head origin -a
  make_gone_branch "wiki-sync/2026-08-15-8888885"

  push_upstream_then_delete "debt/301-dirty"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/debt/301-dirty" "debt/301-dirty"
  wt="$REPO/.claude/worktrees/debt/301-dirty"
  echo dirty > "$wt/dirty.txt"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/301-dirty"
}

@test "sweep 8: a worktree named by a live RUNNING plan survives the newly routine [gone] trigger" {
  make_repo
  ignore_local_state
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" remote set-head origin -a
  make_gone_branch "wiki-sync/2026-08-16-9999996"

  push_upstream_then_delete "debt/302-live"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/debt/302-live" "debt/302-live"
  wt="$REPO/.claude/worktrees/debt/302-live"
  write_plan_sentinel "$wt" "plans/PLAN-910" "debt/302-live"

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/302-live"
}
