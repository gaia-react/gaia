#!/usr/bin/env bats
#
# Bats suite for the foreign-repository half of .gaia/scripts/usage-merge.sh's
# operand scan: a `-R`/`--repo` flag, or a PR URL naming a repository other
# than the local origin's, leaves no resolvable operand, so the hook never
# reads the LOCAL repository's pull request of the same number. Split from
# usage-merge.bats to keep that suite under the file-size budget; the shared
# setup lives in helpers/usage-merge-env.sh.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/tests/hooks/usage-merge-repo-flag.bats

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/usage-merge-env.sh"
  # shellcheck disable=SC2034  # read by build_repo in the helper
  SRC="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  TMP="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  export GAIA_RATES_STATE_DIR="$BATS_TEST_TMPDIR/rates-state" GAIA_RATES_FEED_DISABLE=1
  unset CLAUDE_CODE_SESSION_ID GAIA_TALLY_PROJECTS_ROOT GITHUB_ACTIONS GAIA_USAGE_HOOKS_DISABLE
  unset GAIA_LEDGER_LOCK_FORCE_FALLBACK GAIA_LEDGER_LOCK_TIMEOUT_SECS GAIA_USAGE_MERGE_CAP_SECS GAIA_USAGE_RENDER_CAP_SECS
  export GAIA_LEDGER_LOCK_POLL_SECS=0.1
  export GIT_AUTHOR_NAME="GAIA Test" GIT_AUTHOR_EMAIL="gaia-test@example.com"
  export GIT_COMMITTER_NAME="GAIA Test" GIT_COMMITTER_EMAIL="gaia-test@example.com"
  GHSTUB_DIR="$TMP/ghstub"
  mkdir -p "$GHSTUB_DIR" "$TMP/bin"
  export GHSTUB_DIR
  make_stubs
  export PATH="$TMP/bin:$PATH"
  build_repo
  {
    seg branch:fix/foo s74 2026-09-23T09:00:00Z 400000 40000
  } >"$TD/usage.jsonl"
  gh_view 45 45 fix/foo MERGED 2026-09-25T02:00:00Z
}

# No merge row and no pr edge for 45, no block naming it, and the local PR 45
# never read through gh.
assert_foreign_ignored() {
  [ "$status" -eq 0 ]
  lacks "pr:45"
  lacks "tokens:"
  [ ! -f "$TD/links.jsonl" ] || [ "$(merge_rows 45)" -eq 0 ] || return 1
  [ ! -f "$TD/links.jsonl" ] || ! grep -q '"pr:45"' "$TD/links.jsonl" || return 1
  [ ! -f "$GHSTUB_DIR/argv.log" ] || ! grep -q 'pr view 45' "$GHSTUB_DIR/argv.log" || return 1
}

@test "a repo flag after the number leaves no resolvable operand" {
  run_merge "gh pr merge 45 --repo x/y"
  assert_foreign_ignored
}

@test "a repo flag before the number leaves no resolvable operand" {
  run_merge "gh pr merge --repo x/y 45"
  assert_foreign_ignored
}

@test "-R before the number leaves no resolvable operand" {
  run_merge "gh pr merge -R x/y 45"
  assert_foreign_ignored
}

@test "--repo=value leaves no resolvable operand" {
  run_merge "gh pr merge --repo=x/y 45"
  assert_foreign_ignored
}

@test "a PR URL for another repository leaves no resolvable operand" {
  git -C "$REPO" remote add origin https://github.com/o/r.git
  run_merge "gh pr merge https://github.com/x/y/pull/45"
  assert_foreign_ignored
}

@test "a PR URL with no origin remote counts as foreign" {
  run_merge "gh pr merge https://github.com/o/r/pull/45"
  assert_foreign_ignored
}

@test "a PR URL for the origin repository still resolves, https and ssh remotes" {
  # The stub answers a URL operand from view.json.
  cp "$GHSTUB_DIR/view-45.json" "$GHSTUB_DIR/view.json"
  git -C "$REPO" remote add origin git@github.com:O/R.git
  run_merge "gh pr merge https://github.com/o/r/pull/45"
  [ "$status" -eq 0 ]
  has_line "[PR cost] pr:45 branch:fix/foo"
  [ "$(merge_rows 45)" -eq 1 ]
  git -C "$REPO" remote set-url origin https://github.com/o/r.git
  run_merge "gh pr merge https://github.com/o/r/pull/45"
  has_line "[PR cost] pr:45 branch:fix/foo"
  [ "$(merge_rows 45)" -eq 2 ]
  # The stub's view.json fallback answers an operand-less read too, so the
  # operand itself must have reached gh.
  [ "$(grep -c '^pr view https://github.com/o/r/pull/45 ' "$GHSTUB_DIR/argv.log")" -eq 2 ]
}
