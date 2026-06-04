#!/usr/bin/env bats

# Tests for .claude/hooks/lib/repo-scope.sh's cmd_targets_foreign_repo().
#
# The helper decides whether a `git`/`gh` command targets a SIBLING repo
# (return 0 = foreign, allow) versus the HOME repo (return 1 = enforce the
# main-push / audit guards). block-main-destructive-git.sh and
# pr-merge-audit-check.sh both source it.
#
# This suite lives under .github/audit/tests/ because that is the only
# directory the CI bats runner (audit-ci-tests.yml, check name
# "bats (.github/audit)") executes, co-locating it keeps the helper under
# regression coverage.
#
# Each test sources the helper, then calls it from inside a `git init`'d HOME
# fixture so its cwd-based `git rev-parse --show-toplevel` resolves to that
# fixture. A second `git init`'d SIBLING fixture stands in for the foreign
# repo. Both toplevels are canonicalised with `pwd -P`, so the macOS
# /var → /private/var symlink under BATS_TEST_TMPDIR does not matter.
#
# Coverage:
#   1. quoted `git -C "<sibling>"` push           → foreign (regression)
#   2. quoted `cd '<sibling>' &&` push            → foreign (regression)
#   3. unquoted `git -C <sibling>` push           → foreign (guard)
#   4. quoted `git -C "<home>"` push              → home (quote-strip safe)
#   5. plain home `git push origin main`          → home (enforce)
#   6. literal `$CG` token `git -C "$CG"` push    → home (unexpandable var, enforce)

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  LIB="$REPO_ROOT/.claude/hooks/lib/repo-scope.sh"
  [ -f "$LIB" ] || skip "repo-scope.sh not found"
  # shellcheck source=/dev/null
  . "$LIB"

  HOME_REPO="$BATS_TEST_TMPDIR/home"
  SIBLING_REPO="$BATS_TEST_TMPDIR/sibling"
  init_repo "$HOME_REPO"
  init_repo "$SIBLING_REPO"
}

init_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init --quiet --initial-branch=main
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" config commit.gpgsign false
  echo "# readme" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit --quiet -m "init"
}

# Evaluate a command string as if issued from inside the HOME repo, so the
# helper's cwd-based home-repo lookup resolves to HOME_REPO.
in_home() {
  ( cd "$HOME_REPO" && cmd_targets_foreign_repo "$1" )
}

# -----------------------------------------------------------------------------
# 1. Quoted `git -C "<sibling>"` resolves as foreign.
# -----------------------------------------------------------------------------

@test "quoted git -C sibling push: foreign (allow)" {
  run in_home "git -C \"$SIBLING_REPO\" push origin main"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# 2. Quoted `cd '<sibling>' &&` resolves as foreign.
# -----------------------------------------------------------------------------

@test "quoted cd sibling && git push: foreign (allow)" {
  run in_home "cd '$SIBLING_REPO' && git push origin main"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# 3. Unquoted `git -C <sibling>` still resolves as foreign (guard).
# -----------------------------------------------------------------------------

@test "unquoted git -C sibling push: foreign (allow)" {
  run in_home "git -C $SIBLING_REPO push origin main"
  [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# 4. Quoted `git -C "<home>"` resolves as HOME, quote-strip stays safe.
# -----------------------------------------------------------------------------

@test "quoted git -C home push: home (enforce)" {
  run in_home "git -C \"$HOME_REPO\" push origin main"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# 5. Plain home `git push origin main` resolves as HOME (enforce).
# -----------------------------------------------------------------------------

@test "plain git push from home: home (enforce)" {
  run in_home "git push origin main"
  [ "$status" -ne 0 ]
}

# -----------------------------------------------------------------------------
# 6. A literal `$CG` token is NOT a path. repo-scope.sh reads the raw command
#    string and never expands shell variables, so `git -C "$CG"` resolves the
#    target to the literal three characters `$CG`, the git lookup fails, and the
#    helper fails closed (return 1 = enforce). This is why the gaia-release
#    runbook inlines the literal absolute path into sibling pushes rather than
#    passing $CG/$WEB, a $VAR form would trip the home-repo main-push deny.
# -----------------------------------------------------------------------------

@test "literal \$CG token (unexpandable variable): home (enforce)" {
  run in_home 'git -C "$CG" push origin main'
  [ "$status" -ne 0 ]
}
