#!/usr/bin/env bats

# NOTE: The on-main + gh-auto-merge-failure path is not unit-testable here
# without a real remote. Smoke test scenario .gaia/tests/smoke/04-non-claude-merge.sh
# exercises that path end-to-end. The non-main test below is the proxy for
# "reset must be conditional, not unconditional."

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../.claude/hooks" && pwd)/wiki-squash-autocommits.sh
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
}

@test "no wiki auto-commits at HEAD: silent no-op" {
  REPO=$("$HELPERS/tmp-git-repo.sh" --commits 2)
  cd "$REPO"
  run "$HOOK_ABS"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # No squash should have happened
  current_subject=$(git log -1 --format='%s')
  [[ "$current_subject" != "wiki: auto-commit"* ]]
}

@test "single wiki auto-commit: no squash needed, exits 0" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  echo "x" > wiki/foo.md
  git add wiki/foo.md
  git commit --quiet -m "wiki: auto-commit 2026-05-03 12:00"
  before_sha=$(git rev-parse HEAD)
  run "$HOOK_ABS"
  [ "$status" -eq 0 ]
  # On a non-main branch with no gh + no remote, nothing further happens
  after_sha=$(git rev-parse HEAD)
  [ "$before_sha" = "$after_sha" ]
}

@test "two consecutive wiki auto-commits: squashed into one" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  # Switch off main so the on-main push path is not taken
  git checkout -b feat/test
  echo "a" > wiki/a.md && git add wiki/a.md && git commit --quiet -m "wiki: auto-commit 2026-05-03 12:00"
  echo "b" > wiki/b.md && git add wiki/b.md && git commit --quiet -m "wiki: auto-commit 2026-05-03 12:01"
  before_count=$(git rev-list --count HEAD)
  run "$HOOK_ABS"
  [ "$status" -eq 0 ]
  after_count=$(git rev-list --count HEAD)
  # One commit should have been squashed away
  [ $((before_count - after_count)) -eq 1 ]
}

@test "non-main branch: never resets working tree (regression for silent-loss bug)" {
  REPO=$("$HELPERS/tmp-git-repo.sh")
  cd "$REPO"
  git checkout -b feat/test
  echo "a" > wiki/a.md && git add wiki/a.md && git commit --quiet -m "wiki: auto-commit a"
  echo "b" > wiki/b.md && git add wiki/b.md && git commit --quiet -m "wiki: auto-commit b"
  # Add an uncommitted wiki edit
  echo "WIP" > wiki/wip.md
  run "$HOOK_ABS"
  [ "$status" -eq 0 ]
  # WIP file must still be there
  [ -f wiki/wip.md ]
  [ "$(cat wiki/wip.md)" = "WIP" ]
}
