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
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  return 0
}

# Stand up a repo with a real bare origin so upstream-track state is faithful.
make_repo() {
  ORIGIN=$(mktemp -d -t gaia-janitor-wt-origin-XXXXXX)
  # --initial-branch=main: an unpinned bare init follows ambient
  # init.defaultBranch, which is unset on CI (falls back to "master"); a
  # fetch or set-head against that name then cannot resolve. Pin it
  # explicitly, matching local-janitor.bats's make_repo_default_branch.
  git init -q --bare --initial-branch=main "$ORIGIN"
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
  # Push main and pin origin/HEAD so origin/<base> resolves: sweep #8's
  # cherry-based reap guard treats an unresolvable base as unanswerable and
  # keeps the worktree, so a fixture that never establishes one can never
  # exercise a genuine reap.
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" remote set-head origin -a
}

# make_repo_spaced: identical to make_repo, but REPO's absolute path contains
# a space (e.g. an adopter under ~/My Projects/...). Regression fixture for
# the porcelain path-truncation defect: `git worktree list --porcelain` does
# not quote the path, so a naive awk $2 split truncates at the first space.
make_repo_spaced() {
  ORIGIN=$(mktemp -d -t gaia-janitor-wt-origin-XXXXXX)
  # --initial-branch=main: same ambient-config hazard as make_repo above.
  git init -q --bare --initial-branch=main "$ORIGIN"
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
  # Same rationale as make_repo above: pin a resolvable origin/<base>.
  git -C "$REPO" push -q -u origin main
  git -C "$REPO" remote set-head origin -a
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
  # Keep origin/main current with this new commit: sweep #8's cherry-based
  # reap guard compares a candidate branch against origin/<base>, and a
  # branch cut from local main after this commit would otherwise carry a
  # commit origin/main does not have, reading as unanswerable regardless of
  # the branch's own merge state.
  git -C "$REPO" push -q origin main
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

# PATH-shimmed `git`: appends every invocation's argv to a witness file, then
# passes through to the real binary. Deliberate duplicate of the identical
# helper in local-janitor.bats: bats helpers are file-scoped and this suite
# has no `load`, so the idiom is duplicated rather than shared.
make_argv_witness_shim() {
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  witness="$SHIM_DIR/witness"
  : > "$witness"
  local real_git
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
echo "\$*" >> "$witness"
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
}

# advance_base <message>: pushes one unrelated commit to origin/<base> via a
# throwaway clone, without touching REPO's own history, then fetches so
# origin/main is current in REPO. Load-bearing per the SPEC's fixture-shape
# requirement: a fixture whose base never moves does not model a real merge.
advance_base() {
  local message="$1" clone
  ADVANCE_BASE_SEQ=$(( ${ADVANCE_BASE_SEQ:-0} + 1 ))
  clone=$(mktemp -d -t gaia-janitor-wt-adv-XXXXXX)
  git clone -q "$ORIGIN" "$clone"
  git -C "$clone" config user.email test@example.com
  git -C "$clone" config user.name Test
  git -C "$clone" config commit.gpgsign false
  echo "$message" >> "$clone/advance-$ADVANCE_BASE_SEQ.txt"
  git -C "$clone" add -A
  git -C "$clone" commit -q -m "$message"
  git -C "$clone" push -q origin main
  rm -rf "$clone"
  git -C "$REPO" fetch -q origin
}

# make_squash_merged_worktree <rel> <branch> <substantive-count>: builds a
# branch in the shape a real squash-merged candidate has -- N substantive
# commits plus the audit gate's empty trailer commit, base advanced between
# the branch cut and the merge, genuinely squash-merged into origin/main, the
# remote head deleted and pruned -- and checks it out into a linked worktree
# at $REPO/.claude/worktrees/<rel>.
make_squash_merged_worktree() {
  local rel="$1" br="$2" count="$3" i
  git -C "$REPO" branch "$br"
  git -C "$REPO" checkout -q "$br"
  i=1
  while [ "$i" -le "$count" ]; do
    echo "commit $i" > "$REPO/${br//\//-}-$i.txt"
    git -C "$REPO" add "${br//\//-}-$i.txt"
    git -C "$REPO" commit -q -m "substantive commit $i"
    i=$((i + 1))
  done
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  git -C "$REPO" push -q -u origin "$br"

  advance_base "advance base for $br"

  # Fast-forward REPO's own main onto the advanced base. advance_base only
  # fetches into REPO, so REPO's local main is one commit behind origin/main
  # here; without this step the squash-merge push below is rejected
  # non-fast-forward, origin/main never carries the squash commit, and the
  # guard finds no matching upstream patch id.
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --ff-only origin/main

  # Squash-merge for real, so origin/main carries a commit whose diff equals
  # the branch's combined diff -- the upstream patch id the guard looks for.
  git -C "$REPO" merge -q --squash "$br"
  git -C "$REPO" commit -q -m "$br (#1)"
  git -C "$REPO" push -q origin main

  git -C "$REPO" push -q origin --delete "$br"
  git -C "$REPO" fetch -q --prune

  mkdir -p "$(dirname "$REPO/.claude/worktrees/$rel")"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$rel" "$br"
}

# combined_patch_id <rev-a> <rev-b>: reads a patch id the same way the guard
# will. `git patch-id` prints two whitespace-separated fields, the patch id
# and a commit id that differs between reads, so only field one is compared.
combined_patch_id() {
  git -C "$REPO" diff --no-ext-diff --no-textconv --end-of-options "$1" "$2" \
    | git -C "$REPO" patch-id --verbatim | awk '{print $1}'
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

@test "sweep 1: a worktree checked out on base fast-forwards main via its own tree, not main_root's" {
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

  # Free `main` for the worktree: git refuses the same branch checked out in
  # two working trees at once, so REPO's own checkout has to move off it
  # first. Detaching leaves REPO's checkout on the same commit main was on
  # before the advance above -- a worktree checked out on some OTHER branch
  # would never reach the merge command at all, since the on-base gate
  # declines before it, which is exactly what made the previous fixture here
  # unable to tell `-C "$root"` from `-C "$main_root"` apart.
  git -C "$REPO" checkout -q --detach main
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/main-side" main
  wt="$REPO/.claude/worktrees/main-side"

  main_before=$(git -C "$REPO" rev-parse main)
  cd "$wt"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  # The fetch and the reap are NOT tree-scoped -- refs and the object store
  # are shared, so this invocation, run from the worktree, still fetches and
  # still reaps the wiki-sync branch.
  branch_exists "wiki-sync/2026-08-13-6666663" && return 1
  # `main` is a single ref shared across every worktree of this repo, and it
  # only advances when the merge runs where main is actually checked out
  # (the worktree, $root). Targeting main_root's own checkout instead --
  # detached at an unrelated commit -- fast-forwards that detached HEAD in
  # place without ever touching the `main` ref, leaving it exactly where it
  # started; that divergence is what proves the merge is scoped to $root.
  [ "$(git -C "$REPO" rev-parse main)" != "$main_before" ] || return 1
  [ "$(git -C "$REPO" rev-parse main)" = "$(git -C "$REPO" rev-parse origin/main)" ]
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

# Regression: sweep #1's prune-fetch is repo-global and flips EVERY branch
# whose remote head is absent to [gone], not only wiki-sync/* ones. A branch
# whose pull request squash-merged reads [gone] the moment sweep #1's fetch
# resolves it, exactly like a genuinely abandoned one -- ancestry cannot tell
# the two apart, only a PATCH-ID (`git cherry`) comparison against
# origin/<base> can. This models a developer who pushed the branch, its PR
# squash-merged (GitHub auto-deletes the head branch), and then kept
# committing follow-ups locally without pushing again: before the hook runs
# the branch reads [ahead 1]; the hook's own fetch is what makes it [gone].
# Sweep #8 must refuse to reap it, the same way sweep #1's own reap already
# refuses a wiki-sync/* branch in the identical shape.
@test "sweep 8: a worktree branch with an unpushed follow-up commit survives its upstream going [gone]" {
  make_repo
  make_gone_branch "wiki-sync/2026-08-17-1111112"

  push_upstream_then_delete "debt/303-followup"
  mkdir -p "$REPO/.claude/worktrees"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/debt/303-followup" "debt/303-followup"
  wt="$REPO/.claude/worktrees/debt/303-followup"

  # The unpushed follow-up commit: made locally after the squash merge, never
  # pushed, and reachable from no remote-tracking ref.
  echo followup > "$wt/followup.txt"
  git -C "$wt" add followup.txt
  git -C "$wt" commit -q -m followup
  followup_sha=$(git -C "$wt" rev-parse HEAD)

  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/303-followup"
  git -C "$REPO" cat-file -e "$followup_sha" 2>/dev/null
}

# Fixture-integrity check for make_squash_merged_worktree: proves the helper
# builds a branch whose combined diff really does reproduce the upstream
# squash commit's patch id -- the shape a real squash-merged candidate has,
# and the reproduction the repaired guard depends on. Asserts nothing about
# sweep #8 and never invokes local-janitor.sh.
@test "fixture: make_squash_merged_worktree builds a branch whose combined patch id matches the upstream squash" {
  make_repo
  make_squash_merged_worktree "squash/900-fixture" "squash/900-fixture" 2
  wt="$REPO/.claude/worktrees/squash/900-fixture"

  track=$(git -C "$REPO" for-each-ref --format='%(upstream:track)' "refs/heads/squash/900-fixture")
  [ "$track" = "[gone]" ]

  [ -d "$wt" ]
  [ -z "$(git -C "$wt" status --porcelain)" ]

  mb=$(git -C "$REPO" merge-base origin/main refs/heads/squash/900-fixture)
  ahead=$(git -C "$REPO" rev-list --count "$mb..refs/heads/squash/900-fixture")
  [ "$ahead" -eq 3 ]

  branch_pid=$(combined_patch_id "$mb" refs/heads/squash/900-fixture)
  squash_pid=$(combined_patch_id origin/main~1 origin/main)
  [ -n "$branch_pid" ]
  [ "$branch_pid" = "$squash_pid" ]
}

# --- Combined-diff patch-id merge evidence ---------------------------------
#
# Sweep #8 proves a merge by comparing the candidate branch's COMBINED diff,
# by whitespace-verbatim patch id, against the patch ids of
# <merge-base>..origin/<base>. A per-commit comparison answers the wrong
# question: a squash merge lands the whole branch as ONE upstream commit, so
# it matches none of a two-commit branch's commits and nothing at all for the
# audit gate's empty trailer commit.
#
# Every question the guard cannot answer from git keeps the worktree: an
# unresolvable base, an unresolvable merge base, a failed rev-list, diff,
# patch-id, or log read, an empty patch id on a branch that is ahead, and a
# bounded scan that ends without a match.

# make_failing_git_shim <extended-regex> [exit-code]: extends the argv-witness
# idiom above. Every invocation's argv is appended to $witness; the ONE
# invocation whose argv matches <extended-regex> prints nothing and exits
# <exit-code> (default 1) instead of running git, while every other invocation
# execs the real binary untouched. Matching narrowly is load-bearing twice
# over: a shim that broke git wholesale would keep every worktree and green
# these tests for entirely the wrong reason, and `status --porcelain` is not
# unique to sweep #8 -- sweep #1 reads it against the main checkout in the
# same hook process, so that shim is scoped by `-C <path>` as well.
make_failing_git_shim() {
  local match="$1" code="${2:-1}" real_git
  SHIM_DIR=$(mktemp -d -t gaia-janitor-shim-XXXXXX)
  witness="$SHIM_DIR/witness"
  : > "$witness"
  real_git=$(command -v git)
  cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
echo "\$*" >> "$witness"
if printf '%s' "\$*" | grep -qE -- '$match'; then
  exit $code
fi
exec "$real_git" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
}

# UAT-001: the shape a real candidate has -- one substantive commit plus the
# audit gate's empty trailer, a base that advanced between the branch cut and
# the merge, a genuine squash merge, and a slashed worktree name whose empty
# parent directory has to be pruned along with the leaf.
@test "reaps a squash-merged worktree carrying one substantive commit plus the audit trailer" {
  make_repo
  make_squash_merged_worktree "plan/spec-901-a" "plan/spec-901-a" 1
  wt="$REPO/.claude/worktrees/plan/spec-901-a"
  [ -d "$wt" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "plan/spec-901-a" && return 1
  [ ! -d "$REPO/.claude/worktrees/plan" ]
  [ -d "$REPO/.claude/worktrees" ]
  [ ! -e "$wt" ]
}

# UAT-002: two substantive commits plus the trailer. The squash collapses all
# three into one upstream commit, so a per-commit patch-id comparison matches
# none of them and refuses a candidate that is provably merged.
@test "reaps a squash-merged worktree carrying two substantive commits plus the audit trailer" {
  make_repo
  make_squash_merged_worktree "plan/spec-902-b" "plan/spec-902-b" 2
  wt="$REPO/.claude/worktrees/plan/spec-902-b"
  [ -d "$wt" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "plan/spec-902-b" && return 1
  [ ! -e "$wt" ]
}

# UAT-003a: a merged branch that kept moving. The follow-up commit reached no
# remote-tracking ref, so the branch's combined diff no longer reproduces the
# upstream squash's patch id and the scan ends without a match. Built on a
# genuinely squash-merged branch so the keep comes from a walk that actually
# walked, not from an empty upstream range.
@test "keeps a squash-merged worktree carrying an unpushed substantive follow-up commit" {
  make_repo
  make_squash_merged_worktree "plan/spec-903-a" "plan/spec-903-a" 1
  wt="$REPO/.claude/worktrees/plan/spec-903-a"
  echo followup > "$wt/followup.txt"
  git -C "$wt" add followup.txt
  git -C "$wt" commit -q -m "unpushed follow-up"
  followup_sha=$(git -C "$wt" rev-parse HEAD)
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "plan/spec-903-a"
  git -C "$REPO" cat-file -e "$followup_sha" 2>/dev/null
}

# UAT-003b: the same shape, but the unpushed commit changes only whitespace on
# a line the squash already carries. Under the default whitespace-normalizing
# patch-id mode this branch's combined diff reproduces the upstream squash's
# id exactly and the commit is reaped and destroyed; --verbatim is the whole
# reason it survives.
@test "keeps a squash-merged worktree carrying an unpushed whitespace-only follow-up commit" {
  make_repo
  make_squash_merged_worktree "plan/spec-904-b" "plan/spec-904-b" 1
  wt="$REPO/.claude/worktrees/plan/spec-904-b"
  printf 'commit 1 \n' > "$wt/plan-spec-904-b-1.txt"
  git -C "$wt" add plan-spec-904-b-1.txt
  git -C "$wt" commit -q -m "whitespace-only follow-up"
  ws_sha=$(git -C "$wt" rev-parse HEAD)
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "plan/spec-904-b"
  git -C "$REPO" cat-file -e "$ws_sha" 2>/dev/null
}

# UAT-004: the zero-commits-ahead reap arm. The branch's tree IS the merge
# base's tree, so it holds nothing a deletion could lose and no upstream match
# is owed. Regression duplicate of the suite's first test, guarding the arm
# through the rewrite.
@test "reaps a [gone]-branch worktree zero commits ahead of the merge base" {
  make_repo
  make_gone_worktree "debt/400-zero" "debt/400-zero"
  wt="$REPO/.claude/worktrees/debt/400-zero"
  [ "$(git -C "$REPO" rev-list --count origin/main..refs/heads/debt/400-zero)" -eq 0 ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "debt/400-zero" && return 1
  [ ! -e "$wt" ]
}

# UAT-005: commits that cancel out. The combined diff is empty while the
# branch holds two real commits, whose content becomes unreachable the moment
# the branch is deleted -- so emptiness on a branch that is ahead is an
# unanswerable question, never a reap signal.
@test "keeps a [gone]-branch worktree whose two commits cancel out to an empty combined diff" {
  make_repo
  make_gone_worktree "debt/401-cancel" "debt/401-cancel"
  wt="$REPO/.claude/worktrees/debt/401-cancel"
  echo cancelled > "$wt/cancelled.txt"
  git -C "$wt" add cancelled.txt
  git -C "$wt" commit -q -m "adds a file"
  add_sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" rm -q cancelled.txt
  git -C "$wt" commit -q -m "reverts it exactly"
  mb=$(git -C "$REPO" merge-base origin/main refs/heads/debt/401-cancel)
  [ "$(git -C "$REPO" rev-list --count "$mb..refs/heads/debt/401-cancel")" -eq 2 ]
  [ -z "$(git -C "$REPO" diff "$mb" refs/heads/debt/401-cancel)" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/401-cancel"
  git -C "$REPO" cat-file -e "$add_sha" 2>/dev/null
}

# UAT-006: an unresolvable merge base. The remote-tracking ref is deleted
# outright, so the merge-base read exits non-zero and the worktree stays.
# Deliberately built with NO wiki-sync/* branch: sweep #1's repo-global
# prune-fetch fires whenever one is present and would recreate
# refs/remotes/origin/main before sweep #8 ever reads it, leaving this test
# passing while proving nothing. The witness assertion pins the refusal to the
# merge-base read rather than to an earlier gate.
@test "keeps a [gone]-branch worktree when the merge-base read fails" {
  make_repo
  make_gone_worktree "debt/402-nomb" "debt/402-nomb"
  wt="$REPO/.claude/worktrees/debt/402-nomb"
  git -C "$REPO" update-ref -d refs/remotes/origin/main
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/402-nomb"
  grep -qE "merge-base .*refs/heads/debt/402-nomb" "$witness"
}

# UAT-007a: the combined-diff read fails while printing nothing. A guard that
# read emptiness rather than exit status would take the failed read for an
# empty diff. The sibling candidate proves the shim is narrow enough that git
# still works for everything else in the same run.
@test "keeps a candidate carrying unpushed work when the combined-diff read fails" {
  make_repo
  make_squash_merged_worktree "plan/spec-905-diff" "plan/spec-905-diff" 1
  make_gone_worktree "debt/409-control" "debt/409-control"
  wt="$REPO/.claude/worktrees/plan/spec-905-diff"
  ctl="$REPO/.claude/worktrees/debt/409-control"
  echo followup > "$wt/followup.txt"
  git -C "$wt" add followup.txt
  git -C "$wt" commit -q -m "unpushed follow-up"
  followup_sha=$(git -C "$wt" rev-parse HEAD)
  make_failing_git_shim "diff .*refs/heads/plan/spec-905-diff"
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "plan/spec-905-diff"
  git -C "$REPO" cat-file -e "$followup_sha" 2>/dev/null
  branch_exists "debt/409-control" && return 1
  [ ! -e "$ctl" ]
}

# UAT-007b: the patch-id read fails while printing nothing. The shim matches
# every patch-id invocation, so no sibling candidate can serve as a positive
# control here; the witness assertions instead pin the refusal past the cheap
# gates and onto the shimmed read.
@test "keeps a candidate carrying unpushed work when the patch-id read fails" {
  make_repo
  make_squash_merged_worktree "plan/spec-906-pid" "plan/spec-906-pid" 1
  wt="$REPO/.claude/worktrees/plan/spec-906-pid"
  echo followup > "$wt/followup.txt"
  git -C "$wt" add followup.txt
  git -C "$wt" commit -q -m "unpushed follow-up"
  followup_sha=$(git -C "$wt" rev-parse HEAD)
  make_failing_git_shim "patch-id"
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "plan/spec-906-pid"
  grep -qE "merge-base .*refs/heads/plan/spec-906-pid" "$witness"
  grep -qF "patch-id" "$witness"
  git -C "$REPO" cat-file -e "$followup_sha" 2>/dev/null
}

# UAT-007c: patch-id exits ZERO while printing nothing. An empty patch id is a
# failed read, never a match -- the branch is one or more commits ahead, so
# there is real content a deletion would lose.
@test "keeps a candidate carrying unpushed work when the patch-id read returns an empty id" {
  make_repo
  make_squash_merged_worktree "plan/spec-907-empty" "plan/spec-907-empty" 1
  wt="$REPO/.claude/worktrees/plan/spec-907-empty"
  echo followup > "$wt/followup.txt"
  git -C "$wt" add followup.txt
  git -C "$wt" commit -q -m "unpushed follow-up"
  followup_sha=$(git -C "$wt" rev-parse HEAD)
  make_failing_git_shim "patch-id" 0
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "plan/spec-907-empty"
  grep -qE "merge-base .*refs/heads/plan/spec-907-empty" "$witness"
  grep -qF "patch-id" "$witness"
  git -C "$REPO" cat-file -e "$followup_sha" 2>/dev/null
}

# UAT-007d: the isolating shape for the combined-diff read's exit status. On a
# ZERO-commits-ahead candidate a failed diff read lands in the empty-diff arm
# with nothing left to refuse it, so dropping that read's status check reaps a
# worktree on a read that failed. UAT-007a cannot show this: its fixture is
# ahead, so the empty-diff arm refuses it anyway.
@test "keeps a zero-commits-ahead candidate when the combined-diff read fails" {
  make_repo
  make_gone_worktree "debt/403-diffrc" "debt/403-diffrc"
  make_gone_worktree "debt/404-control" "debt/404-control"
  wt="$REPO/.claude/worktrees/debt/403-diffrc"
  ctl="$REPO/.claude/worktrees/debt/404-control"
  [ "$(git -C "$REPO" rev-list --count origin/main..refs/heads/debt/403-diffrc)" -eq 0 ]
  make_failing_git_shim "diff .*refs/heads/debt/403-diffrc"
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/403-diffrc"
  branch_exists "debt/404-control" && return 1
  [ ! -e "$ctl" ]
}

# UAT-007e: the isolating shape for the patch-id read's exit status, same
# reasoning as UAT-007d. On a zero-commits-ahead candidate a failed patch-id
# read reaches the empty-diff arm unopposed.
@test "keeps a zero-commits-ahead candidate when the patch-id read fails" {
  make_repo
  make_gone_worktree "debt/405-pidrc" "debt/405-pidrc"
  wt="$REPO/.claude/worktrees/debt/405-pidrc"
  [ "$(git -C "$REPO" rev-list --count origin/main..refs/heads/debt/405-pidrc)" -eq 0 ]
  make_failing_git_shim "patch-id"
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/405-pidrc"
  grep -qE "merge-base .*refs/heads/debt/405-pidrc" "$witness"
  grep -qF "patch-id" "$witness"
}

# UAT-008: the working-tree status read fails while printing nothing. Reading
# that silence as "clean" permits the reap of a worktree nobody can see into.
# The shim is scoped by `-C <worktree path>` so sweep #1's own
# `status --porcelain` against the main checkout passes through untouched, and
# the sibling candidate proves the rest of the run still reaps normally.
@test "keeps a candidate that would otherwise be reaped when the status read fails" {
  make_repo
  make_gone_worktree "debt/406-status" "debt/406-status"
  make_gone_worktree "debt/407-control" "debt/407-control"
  wt="$REPO/.claude/worktrees/debt/406-status"
  ctl="$REPO/.claude/worktrees/debt/407-control"
  # Scoped by the worktree's own -C argument, but matched on the path's tail:
  # the janitor reads its roots through git, which resolves symlinks, so the
  # argv carries the physical path while $REPO carries the one mktemp handed
  # back (on macOS, /private/var/... against /var/...).
  make_failing_git_shim "-C .*/\.claude/worktrees/debt/406-status status --porcelain"
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  branch_exists "debt/406-status"
  branch_exists "debt/407-control" && return 1
  [ ! -e "$ctl" ]
}

# The unresolvable-base keep-condition. $base is read from
# refs/remotes/origin/HEAD and then shape-validated: a name carrying a
# character outside [A-Za-z0-9._/-] clears it to empty. Deleting
# refs/remotes/origin/HEAD outright would NOT do it -- the resolution falls
# back to `main` -- so the fixture repoints it at an unsafely-shaped name.
@test "keeps a [gone]-branch worktree when the base cannot be resolved to a safe name" {
  make_repo
  make_gone_worktree "debt/408-nobase" "debt/408-nobase"
  wt="$REPO/.claude/worktrees/debt/408-nobase"
  git -C "$REPO" branch 'odd+base' main
  git -C "$REPO" push -q -u origin 'odd+base'
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/odd+base
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  # The base gate is what refused, and it refused before any merge-evidence
  # read: sweep #8 enumerated the worktrees but never reached its merge base.
  grep -qF "worktree list --porcelain" "$witness"
  grep -qE "merge-base .*refs/heads/debt/408-nobase" "$witness" && return 1
  branch_exists "debt/408-nobase"
}

# --- Observability: the scan bound, the gate order, and output silence ----
#
# Both properties below concern what the guard does NOT do, so they cannot be
# observed behaviorally: the upstream scan's bound has to come from git log's
# own -n option, never a downstream `head -n` (which would close the pipe and
# raise SIGPIPE 141 under this file's pipefail, silently disabling the guard
# again), and the merge-evidence reads must run only after the cheap refusal
# gates (dirty tree, live RUNNING sentinel) have already declined.

# UAT-009: the bound is applied by git log's own -n option. Asserts the
# literal count, not just the flag, so a re-tuned bound has to be published in
# this test's diff. The patch-id assertion guards against a vacuous green: a
# fixture that never reached the scan would record neither.
@test "UAT-009: the upstream scan bound is applied by git log's own -n option" {
  make_repo
  make_squash_merged_worktree "plan/spec-908-bound" "plan/spec-908-bound" 1
  wt="$REPO/.claude/worktrees/plan/spec-908-bound"
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "plan/spec-908-bound" && return 1
  [ ! -e "$wt" ]
  grep -qE "log .*-n 1000" "$witness"
  [ "$(grep -c 'patch-id' "$witness")" -ge 1 ]
}

# UAT-010: the expensive merge-evidence scan runs only after the cheap
# refusal gates. Both candidates are built with make_squash_merged_worktree,
# the same builder UAT-009 uses -- a candidate built with make_gone_branch is
# zero commits ahead and reaps through the empty-diff arm without ever
# reaching the upstream scan, which would make this test's negative counts
# true for a reason that has nothing to do with gate ordering.
@test "UAT-010: the merge-evidence scan runs only after the cheap refusal gates" {
  make_repo
  ignore_local_state
  make_squash_merged_worktree "plan/spec-909-dirty" "plan/spec-909-dirty" 1
  make_squash_merged_worktree "plan/spec-910-sentinel" "plan/spec-910-sentinel" 1
  dirty_wt="$REPO/.claude/worktrees/plan/spec-909-dirty"
  sentinel_wt="$REPO/.claude/worktrees/plan/spec-910-sentinel"
  echo dirty > "$dirty_wt/dirty.txt"
  write_plan_sentinel "$sentinel_wt" "plans/PLAN-920" "plan/spec-910-sentinel"
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$dirty_wt" ]
  [ -d "$sentinel_wt" ]
  branch_exists "plan/spec-909-dirty"
  branch_exists "plan/spec-910-sentinel"
  [ "$(grep -c 'patch-id' "$witness")" -eq 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 0 ]
  [ "$(grep -cE "merge-base .*refs/heads/plan/spec-909-dirty" "$witness")" -eq 0 ]
  [ "$(grep -cE "merge-base .*refs/heads/plan/spec-910-sentinel" "$witness")" -eq 0 ]
  [ "$(grep -cE "rev-list .*refs/heads/plan/spec-909-dirty" "$witness")" -eq 0 ]
  [ "$(grep -cE "rev-list .*refs/heads/plan/spec-910-sentinel" "$witness")" -eq 0 ]
  [ "$(grep -cE "diff .*refs/heads/plan/spec-909-dirty" "$witness")" -eq 0 ]
  [ "$(grep -cE "diff .*refs/heads/plan/spec-910-sentinel" "$witness")" -eq 0 ]
}

# UAT-010 positive control, same fixture shape with the dirty file and the
# sentinel removed. Without this the negative counts above could green
# vacuously through an early short-circuit further up the sweep and prove
# nothing about gate ordering.
@test "UAT-010 positive control: the merge-evidence scan runs when no cheap gate refuses" {
  make_repo
  make_squash_merged_worktree "plan/spec-911-control-a" "plan/spec-911-control-a" 1
  make_squash_merged_worktree "plan/spec-912-control-b" "plan/spec-912-control-b" 1
  wt_a="$REPO/.claude/worktrees/plan/spec-911-control-a"
  wt_b="$REPO/.claude/worktrees/plan/spec-912-control-b"
  [ -d "$wt_a" ]
  [ -d "$wt_b" ]
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "plan/spec-911-control-a" && return 1
  branch_exists "plan/spec-912-control-b" && return 1
  [ ! -e "$wt_a" ]
  [ ! -e "$wt_b" ]
  [ "$(grep -c 'patch-id' "$witness")" -gt 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -gt 0 ]
  [ "$(grep -cE "merge-base .*refs/heads/plan/spec-911-control-a" "$witness")" -gt 0 ]
  [ "$(grep -cE "merge-base .*refs/heads/plan/spec-912-control-b" "$witness")" -gt 0 ]
  [ "$(grep -cE "rev-list .*refs/heads/plan/spec-911-control-a" "$witness")" -gt 0 ]
  [ "$(grep -cE "rev-list .*refs/heads/plan/spec-912-control-b" "$witness")" -gt 0 ]
  [ "$(grep -cE "diff .*refs/heads/plan/spec-911-control-a" "$witness")" -gt 0 ]
  [ "$(grep -cE "diff .*refs/heads/plan/spec-912-control-b" "$witness")" -gt 0 ]
}

# --- The negative merge-evidence memo --------------------------------------
#
# The upstream scan is the sweep's one expensive read, and its answer is a
# pure function of the branch tip and the origin/<base> tip. A candidate that
# is kept because no upstream commit matches -- an abandoned branch, or a
# merged one carrying unpushed follow-up work -- re-walks the identical range
# at every session start for as long as its worktree sits there. The memo
# records that negative answer under both tips and skips the repeat.
#
# Only the negative answer is memoized, so a stale entry can only ever cause a
# keep, the direction every unanswerable question in this sweep already fails
# toward. The tests below assert both halves: the repeat is skipped while
# neither tip moves, AND the scan comes back the moment either one does.

# memo_file: where the sweep anchors the memo, at MAIN's cache, matching the
# registry's worktree-reap-miss-memo entry.
memo_file() {
  printf '%s' "$REPO/.gaia/local/cache/worktree-reap-misses.txt"
}

# make_unmerged_worktree <rel> <branch>: the candidate shape whose walk repeats
# every session -- a [gone]-upstream branch carrying real work that never
# landed, the way a pull request closed without merging and then branch-deleted
# reads. Identical to make_squash_merged_worktree up to the merge, which it
# deliberately never performs, so the scan walks a genuinely non-empty upstream
# range (the advanced base) and ends without a match. The keep therefore comes
# from a completed scan, never from a short-circuit above it.
make_unmerged_worktree() {
  local rel="$1" br="$2"
  git -C "$REPO" branch "$br"
  git -C "$REPO" checkout -q "$br"
  echo "commit 1" > "$REPO/${br//\//-}-1.txt"
  git -C "$REPO" add "${br//\//-}-1.txt"
  git -C "$REPO" commit -q -m "substantive commit 1"
  git -C "$REPO" commit -q --allow-empty -m "chore: code review audit passed"
  git -C "$REPO" push -q -u origin "$br"

  advance_base "advance base for $br"

  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --ff-only origin/main

  git -C "$REPO" push -q origin --delete "$br"
  git -C "$REPO" fetch -q --prune

  mkdir -p "$(dirname "$REPO/.claude/worktrees/$rel")"
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/$rel" "$br"
}

# land_squash <branch>: squash-merge the branch as it now stands into
# origin/<base>, the event that turns a previously unmatched candidate into a
# provably merged one. Moves the base tip, which is exactly the condition that
# has to invalidate a memoized miss.
land_squash() {
  local br="$1"
  git -C "$REPO" checkout -q main
  git -C "$REPO" merge -q --ff-only origin/main
  git -C "$REPO" merge -q --squash "$br"
  git -C "$REPO" commit -q -m "$br (#1)"
  git -C "$REPO" push -q origin main
  git -C "$REPO" fetch -q --prune
}

@test "does not repeat the upstream scan for an unmatched candidate while neither tip moves" {
  make_repo
  make_unmerged_worktree "plan/spec-920-memo" "plan/spec-920-memo"
  wt="$REPO/.claude/worktrees/plan/spec-920-memo"
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  # The first run walks, exactly once, and records the miss.
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 1 ]
  [ -f "$(memo_file)" ]
  grep -qF -- "plan/spec-920-memo" "$(memo_file)"
  # The second run answers from the memo: the cumulative count on the shared
  # witness does not move, and the worktree is still kept.
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 1 ]
  [ -d "$wt" ]
  branch_exists "plan/spec-920-memo"
}

@test "walks again for an unmatched candidate once the base tip moves" {
  make_repo
  make_unmerged_worktree "plan/spec-921-basemove" "plan/spec-921-basemove"
  wt="$REPO/.claude/worktrees/plan/spec-921-basemove"
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 1 ]
  # origin/<base> moves, so the memoized answer no longer covers the question.
  advance_base "advance base past the memo"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 2 ]
  [ -d "$wt" ]
  branch_exists "plan/spec-921-basemove"
}

@test "walks again for an unmatched candidate once the branch tip moves" {
  make_repo
  make_unmerged_worktree "plan/spec-922-tipmove" "plan/spec-922-tipmove"
  wt="$REPO/.claude/worktrees/plan/spec-922-tipmove"
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 1 ]
  # The branch moves, so the memoized answer no longer covers the question.
  echo second > "$wt/second.txt"
  git -C "$wt" add second.txt
  git -C "$wt" commit -q -m "second unpushed follow-up"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 2 ]
  [ -d "$wt" ]
  branch_exists "plan/spec-922-tipmove"
}

# The memo can never hold a worktree past the point its merge becomes
# provable. The candidate is memoized as unmatched, then its follow-up work
# genuinely lands upstream; the next run re-walks (the base moved) and reaps.
@test "reaps a memoized candidate once its work genuinely lands upstream" {
  make_repo
  make_unmerged_worktree "plan/spec-923-lands" "plan/spec-923-lands"
  wt="$REPO/.claude/worktrees/plan/spec-923-lands"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  grep -qF -- "plan/spec-923-lands" "$(memo_file)"
  land_squash "plan/spec-923-lands"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "plan/spec-923-lands" && return 1
  [ ! -e "$wt" ]
}

# Two candidates sharing one base each pay their own walk in the first run,
# and neither pays again in the second. The cited case for the repeat cost:
# the gate-order positive control already records two distinct walks.
@test "memoizes each of two candidates sharing a base, so neither walks twice" {
  make_repo
  make_unmerged_worktree "plan/spec-924-pair-a" "plan/spec-924-pair-a"
  make_unmerged_worktree "plan/spec-925-pair-b" "plan/spec-925-pair-b"
  make_argv_witness_shim
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 2 ]
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ "$(grep -cE 'log .*-n 1000' "$witness")" -eq 2 ]
  [ -d "$REPO/.claude/worktrees/plan/spec-924-pair-a" ]
  [ -d "$REPO/.claude/worktrees/plan/spec-925-pair-b" ]
}

# The memo is rewritten from each run's own misses, so an entry for a worktree
# that is gone does not outlive it. Without this the file only ever grows: a
# branch tip and a base tip both move over a repo's life, and every pair either
# ever held would accumulate forever.
@test "drops a memo entry for a candidate that is no longer present" {
  make_repo
  make_unmerged_worktree "plan/spec-926-stays" "plan/spec-926-stays"
  make_unmerged_worktree "plan/spec-927-goes" "plan/spec-927-goes"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- "plan/spec-926-stays" "$(memo_file)"
  grep -qF -- "plan/spec-927-goes" "$(memo_file)"
  # Remove one candidate the way a person would, outside the sweep.
  git -C "$REPO" worktree remove --force "$REPO/.claude/worktrees/plan/spec-927-goes"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  grep -qF -- "plan/spec-926-stays" "$(memo_file)"
  grep -qF -- "plan/spec-927-goes" "$(memo_file)" && return 1
  [ -d "$REPO/.claude/worktrees/plan/spec-926-stays" ]
}

# The memo records only a COMPLETED scan that found no match. A failed upstream
# read proves nothing, so it must not be recorded: otherwise one transient
# failure would suppress the guard's real scan for as long as both tips held,
# and the reap would go silently inert.
@test "records no memo entry when the upstream scan itself fails" {
  make_repo
  make_unmerged_worktree "plan/spec-928-failed" "plan/spec-928-failed"
  wt="$REPO/.claude/worktrees/plan/spec-928-failed"
  make_failing_git_shim "log .*-n 1000"
  cd "$REPO"
  run env PATH="$SHIM_DIR:$PATH" bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  grep -qE "log .*-n 1000" "$witness"
  [ ! -f "$(memo_file)" ]
}

# The memo file is the only cache child this sweep writes, and sweep #9 puts
# every cache/ child to the state registry: an unrecognized one is reported on
# stderr at every session start, forever. The sweep is silent on every path, so
# a memo write that the registry does not recognize would surface here.
@test "the memo write leaves the sweep silent and the cache registry-clean" {
  make_repo
  make_unmerged_worktree "plan/spec-929-quiet" "plan/spec-929-quiet"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$(memo_file)" ]
}

# COV-006: the sweep emits nothing at all, on any path. Two arms, keep and
# reap, on fixtures already established above.
@test "COV-006: a kept worktree produces no output" {
  make_repo
  make_gone_worktree "debt/410-silent-keep" "debt/410-silent-keep"
  wt="$REPO/.claude/worktrees/debt/410-silent-keep"
  echo dirty > "$wt/dirty.txt"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -d "$wt" ]
  branch_exists "debt/410-silent-keep"
}

@test "COV-006: a reaped squash-merged worktree produces no output" {
  make_repo
  make_squash_merged_worktree "plan/spec-913-silent-reap" "plan/spec-913-silent-reap" 1
  wt="$REPO/.claude/worktrees/plan/spec-913-silent-reap"
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  branch_exists "plan/spec-913-silent-reap" && return 1
  [ ! -e "$wt" ]
}

# The default branch resolved once at the top of the hook has to survive every
# sweep that runs between that resolution and this one. Sweep #4's audit-marker
# walk runs in between and iterates over whatever `.gaia/local/audit/` holds, so
# a checkout carrying even one marker is the ordinary case, not an edge case:
# every real one does. If that walk leaves its own loop variable behind in the
# name this sweep reads, the merge-base read below resolves nothing, every
# candidate is declined, and the reap goes silently inert while still exiting 0.
@test "reaps a [gone]-branch worktree when the audit directory holds markers" {
  make_repo
  make_gone_worktree "debt/500-marker" "debt/500-marker"
  wt="$REPO/.claude/worktrees/debt/500-marker"
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{}\n' > "$REPO/.gaia/local/audit/deadbeefcafe.ok"
  [ -d "$wt" ]
  cd "$REPO"
  run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]
  branch_exists "debt/500-marker" && return 1
  [ ! -e "$wt" ]
}
