#!/usr/bin/env bats
#
# Preservation guard for .gaia/tests/hooks/local-janitor-worktree-reap.bats.
# The reap suite's pre-existing tests have to survive rewrites of the guard
# they exercise: none renamed, reworded, or dropped, and the suite's total
# test count only grows. A green run of the reap suite alone cannot prove
# that; it proves the survivors pass, not that nothing was quietly removed
# to get there. This suite pins the pre-existing test names and count from
# the merge-base revision rather than the working tree, because the working
# tree is the version under suspicion: reading the names out of a file that
# could itself have been edited to drop a test defeats the point of pinning
# them.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-worktree-reap-suite-preserved.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SUITE="$REPO_ROOT/.gaia/tests/hooks/local-janitor-worktree-reap.bats"
}

# The 17 test names the reap suite carried before this change, pinned
# verbatim as full "@test "..." {" lines so a rewording is as visible as a
# deletion.
PRESERVED_TEST_LINES=(
  "@test \"reaps a [gone]-branch worktree with a clean working tree\" {"
  "@test \"prunes the empty parent directory left behind by a slashed worktree name\" {"
  "@test \"reaps a [gone]-branch worktree wedged locked-initializing by a crashed add\" {"
  "@test \"keeps a worktree whose branch upstream is still live\" {"
  "@test \"keeps a [gone]-branch worktree that has uncommitted changes\" {"
  "@test \"never reaps the current checkout even when its own branch is gone\" {"
  "@test \"leaves a detached-HEAD worktree untouched\" {"
  "@test \"reaps a [gone]-branch worktree even when the repo's absolute path contains a space\" {"
  "@test \"keeps a [gone]-branch worktree whose own tree holds a live RUNNING plan\" {"
  "@test \"keeps a [gone]-branch worktree named by a RUNNING plan in the main checkout\" {"
  "@test \"keeps a [gone]-branch worktree whose own RUNNING sentinel names no branch\" {"
  "@test \"reaps a [gone]-branch worktree when the only RUNNING plan names another branch\" {"
  "@test \"sweep 1: a worktree checked out on base fast-forwards main via its own tree, not main_root's\" {"
  "@test \"sweep 8: a worktree that is the current checkout survives the newly routine [gone] trigger\" {"
  "@test \"sweep 8: a worktree with a dirty tree survives the newly routine [gone] trigger\" {"
  "@test \"sweep 8: a worktree named by a live RUNNING plan survives the newly routine [gone] trigger\" {"
  "@test \"sweep 8: a worktree branch with an unpushed follow-up commit survives its upstream going [gone]\" {"
)

# The suite's test count as of this change; a future edit may only grow it.
PRESERVED_TEST_FLOOR=38

@test "the reap suite file exists" {
  [ -f "$SUITE" ]
}

@test "every pre-existing reap test name is still present verbatim" {
  local line
  for line in "${PRESERVED_TEST_LINES[@]}"; do
    grep -qF -- "$line" "$SUITE" && continue
    printf 'missing pre-existing reap test: %s\n' "$line"
    return 1
  done
}

@test "the reap suite's test count has not dropped below the pinned floor" {
  local count
  count="$(grep -c '^@test' "$SUITE")"
  [ "$count" -ge "$PRESERVED_TEST_FLOOR" ]
}
