#!/usr/bin/env bats

# NOTE: The on-main + gh-auto-merge-failure path is not unit-testable here
# without a real remote. Smoke test scenario .gaia/tests/smoke/04-non-claude-merge.sh
# exercises that path end-to-end. The non-main test below is the proxy for
# "reset must be conditional, not unconditional."

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  HOOK_ABS=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)/wiki-squash-autocommits.sh
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  [ -n "${ORIGIN:-}" ] && rm -rf "$ORIGIN"
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
  return 0
}

# make_gh_shim: a PATH-shimmed `gh` that reports success for the pr create and
# pr merge calls the on-main arm makes. That arm sets should_reset only on a
# positive merge confirmation, so without this the reset the test exists to
# exercise never runs and the test passes vacuously.
make_gh_shim() {
  SHIM_DIR=$(mktemp -d -t gaia-squash-shim-XXXXXX)
  cat > "$SHIM_DIR/gh" <<'SHIM'
#!/bin/bash
exit 0
SHIM
  chmod +x "$SHIM_DIR/gh"
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

@test "on main: a tag named origin/main never decides the reset target" {
  # The on-main reset moves local main to the remote-tracking ref. git resolves
  # a bare `origin/main` through refs/tags/ first, so a tag of that name would
  # be what local main is reset onto, and `--mixed` would stage the difference
  # as working-tree changes rather than returning main to the remote.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  ORIGIN=$(mktemp -d -t gaia-squash-origin-XXXXXX)
  git init -q --bare --initial-branch=main "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push -q -u origin main
  remote_tip=$(git -C "$REPO" rev-parse refs/remotes/origin/main)

  # Two auto-commits so the squash arm runs, then a tag named origin/main on
  # the resulting local tip, which is strictly ahead of the remote.
  echo "a" > "$REPO/wiki/a.md"
  git -C "$REPO" add wiki/a.md
  git -C "$REPO" commit --quiet -m "wiki: auto-commit 2026-05-03 12:00"
  echo "b" > "$REPO/wiki/b.md"
  git -C "$REPO" add wiki/b.md
  git -C "$REPO" commit --quiet -m "wiki: auto-commit 2026-05-03 12:01"
  git -C "$REPO" tag "origin/main" HEAD

  make_gh_shim
  cd "$REPO"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  # Local main is back on the remote-tracking ref, not on the tag. Both sides
  # spelled fully qualified so the assertion itself cannot be shadowed.
  [ "$(git -C "$REPO" rev-parse refs/heads/main)" = "$remote_tip" ] || return 1
  # And the tag is still ahead of it, so a green above means the hook read past
  # the tag rather than the fixture having failed to plant a distinguishing one.
  [ "$(git -C "$REPO" rev-parse refs/tags/origin/main)" != "$remote_tip" ] || return 1
  true
}

@test "on main: a tag named main does not skip the on-main arm entirely" {
  # Distinct from the tag named `origin/main` above, and the distinction is the
  # point: `origin/main` does not make the bare spelling `main` ambiguous, so
  # that fixture cannot observe this. A tag named `main` does, and it shortens
  # the branch read to `heads/main`, which misses the compare and skips the
  # whole arm -- no wiki branch pushed, no PR, no reset, and the squashed
  # commit left on local main.
  REPO=$("$HELPERS/tmp-git-repo.sh")
  ORIGIN=$(mktemp -d -t gaia-squash-origin-XXXXXX)
  git init -q --bare --initial-branch=main "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
  git -C "$REPO" push -q -u origin main

  echo "a" > "$REPO/wiki/a.md"
  git -C "$REPO" add wiki/a.md
  git -C "$REPO" commit --quiet -m "wiki: auto-commit 2026-05-03 12:00"
  echo "b" > "$REPO/wiki/b.md"
  git -C "$REPO" add wiki/b.md
  git -C "$REPO" commit --quiet -m "wiki: auto-commit 2026-05-03 12:01"
  git -C "$REPO" tag main HEAD

  make_gh_shim
  cd "$REPO"
  PATH="$SHIM_DIR:$PATH" run bash "$HOOK_ABS"
  [ "$status" -eq 0 ]

  # The arm ran: a wiki/* branch reached the remote. That is the observable the
  # skip destroys, and it does not depend on the reset having happened.
  [ "$(git -C "$ORIGIN" for-each-ref --format='%(refname)' 'refs/heads/wiki/*' | wc -l | tr -d ' ')" -ge 1 ]
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
