#!/usr/bin/env bats

# Tests for .githooks/pre-push.
#
# The hook holds no check logic. It reads the pushed refs, keeps the non-delete
# branch updates, and hands their shas to the verification runner's `push` mode.
# These tests drive real `git push` commands against a bare remote, with the
# hook installed through core.hooksPath and the runner replaced by a stub that
# logs its argv and exits with the status a control file names. What the
# checks themselves do is the runner suites' business, and the end-to-end suite
# beside this one runs the real distribution checks.

setup() {
  HOOK_SOURCE="$BATS_TEST_DIRNAME/../../../.githooks/pre-push"
  [ -f "$HOOK_SOURCE" ]
  [ -x "$HOOK_SOURCE" ]

  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  REPO="$BATS_TEST_TMPDIR/repo"
  HOOKS="$BATS_TEST_TMPDIR/hooks"
  RUNNER_LOG="$BATS_TEST_TMPDIR/runner.log"
  RUNNER_STATUS="$BATS_TEST_TMPDIR/runner.status"

  git init --quiet --bare --initial-branch=main "$REMOTE"
  git init --quiet --initial-branch=main "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" remote add origin "$REMOTE"

  mkdir -p "$HOOKS" "$REPO/.gaia/tests"
  cp "$HOOK_SOURCE" "$HOOKS/pre-push"
  chmod +x "$HOOKS/pre-push"
  git -C "$REPO" config core.hooksPath "$HOOKS"

  : > "$RUNNER_LOG"
  printf '0\n' > "$RUNNER_STATUS"
  cat > "$REPO/.gaia/tests/verify-harness.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$RUNNER_LOG"
exit "\$(cat "$RUNNER_STATUS")"
STUB

  printf 'base\n' > "$REPO/file.txt"
  git -C "$REPO" add file.txt
  git -C "$REPO" commit --quiet -m "base"
  git -C "$REPO" push --quiet origin main
  : > "$RUNNER_LOG"
}

# commit_on_branch <branch>: a new branch off main with one commit; prints its sha.
commit_on_branch() {
  git -C "$REPO" checkout --quiet -b "$1" main
  printf '%s\n' "$1" > "$REPO/$1.txt"
  git -C "$REPO" add "$1.txt"
  git -C "$REPO" commit --quiet -m "$1"
  git -C "$REPO" rev-parse HEAD
}

# remote_has_branch <branch>
remote_has_branch() {
  git -C "$REMOTE" rev-parse --verify --quiet "refs/heads/$1" > /dev/null
}

NOTE='pre-push: no branch update in this push, nothing to verify'

@test "a tag-only push passes with one note line and never reaches the runner" {
  git -C "$REPO" tag spec/001
  run git -C "$REPO" push origin refs/tags/spec/001
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pre-push:' <<<"$output")" -eq 1 ]
  grep -qxF -- "$NOTE" <<<"$output"
  [ ! -s "$RUNNER_LOG" ]
  git -C "$REMOTE" rev-parse --verify --quiet refs/tags/spec/001 > /dev/null
}

@test "a branch deletion passes with one note line and never reaches the runner" {
  commit_on_branch doomed > /dev/null
  git -C "$REPO" push --quiet origin doomed
  : > "$RUNNER_LOG"
  printf '1\n' > "$RUNNER_STATUS"

  run git -C "$REPO" push origin --delete doomed
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pre-push:' <<<"$output")" -eq 1 ]
  grep -qxF -- "$NOTE" <<<"$output"
  [ ! -s "$RUNNER_LOG" ]
  if remote_has_branch doomed; then return 1; fi
}

@test "a push carrying a tag and a branch hands the runner exactly the branch sha" {
  branch_sha="$(commit_on_branch feat-one)"
  git -C "$REPO" tag spec/002
  run git -C "$REPO" push origin feat-one refs/tags/spec/002
  [ "$status" -eq 0 ]
  [ "$(cat "$RUNNER_LOG")" = "push $branch_sha" ]
  remote_has_branch feat-one
}

@test "two branches pushed at once hand the runner both distinct shas" {
  first_sha="$(commit_on_branch feat-a)"
  second_sha="$(commit_on_branch feat-b)"
  [ "$first_sha" != "$second_sha" ]
  run git -C "$REPO" push origin feat-a feat-b
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$RUNNER_LOG" | tr -d ' ')" -eq 1 ]
  grep -qF -- "$first_sha" "$RUNNER_LOG"
  grep -qF -- "$second_sha" "$RUNNER_LOG"
  grep -qE -- "^push [0-9a-f]{40} [0-9a-f]{40}$" "$RUNNER_LOG"
}

@test "two branches at the same commit hand the runner that sha once" {
  branch_sha="$(commit_on_branch feat-same)"
  git -C "$REPO" branch feat-twin
  run git -C "$REPO" push origin feat-same feat-twin
  [ "$status" -eq 0 ]
  [ "$(cat "$RUNNER_LOG")" = "push $branch_sha" ]
  remote_has_branch feat-twin
}

@test "a runner refusal refuses the push and the ref never reaches the remote" {
  commit_on_branch feat-red > /dev/null
  printf '1\n' > "$RUNNER_STATUS"
  run git -C "$REPO" push origin feat-red
  [ "$status" -ne 0 ]
  [ -s "$RUNNER_LOG" ]
  if remote_has_branch feat-red; then return 1; fi
}

@test "a missing runner fails open with one warning line naming CI" {
  commit_on_branch feat-open > /dev/null
  rm "$REPO/.gaia/tests/verify-harness.sh"
  run git -C "$REPO" push origin feat-open
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pre-push:' <<<"$output")" -eq 1 ]
  grep -qF -- "CI is the remaining check" <<<"$output"
  remote_has_branch feat-open
}

@test "no skip spelling lets a refused push through" {
  commit_on_branch feat-skip > /dev/null
  printf '1\n' > "$RUNNER_STATUS"

  run env SKIP=1 git -C "$REPO" push origin feat-skip
  [ "$status" -ne 0 ]
  if remote_has_branch feat-skip; then return 1; fi

  run env GAIA_SKIP_PREPUSH=1 git -C "$REPO" push origin feat-skip
  [ "$status" -ne 0 ]
  if remote_has_branch feat-skip; then return 1; fi
}
