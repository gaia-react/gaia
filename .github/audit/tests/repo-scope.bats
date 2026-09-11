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
# "Audit CI Tests") executes, co-locating it keeps the helper under
# regression coverage.
#
# Each test sources the helper, then calls it from inside a `git init`'d HOME
# fixture so its cwd-based home-repo lookup resolves to that fixture. A second
# `git init`'d SIBLING fixture stands in for the foreign repo. The helper
# compares physically resolved roots, so the macOS /var → /private/var symlink
# under BATS_TEST_TMPDIR does not matter.
#

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

@test "quoted git -C sibling push: foreign (allow)" {
  run in_home "git -C \"$SIBLING_REPO\" push origin main"
  [ "$status" -eq 0 ]
}

@test "quoted cd sibling && git push: foreign (allow)" {
  run in_home "cd '$SIBLING_REPO' && git push origin main"
  [ "$status" -eq 0 ]
}

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

# -----------------------------------------------------------------------------
# 7. The home repository is a repository, not a directory. Two checkouts get
#    this wrong under a directory-name or toplevel comparison: a linked
#    worktree, whose toplevel is its own directory, and any checkout whose
#    directory is not named for the repository. HOME_REPO's directory is
#    `home` and its worktree's is `wt`, while the repository is acme/widget,
#    so every case below is both at once.
# -----------------------------------------------------------------------------

add_widget_remote() {
  git -C "$1" remote add origin https://github.com/acme/widget.git
}

add_worktree() {
  WT="$BATS_TEST_TMPDIR/wt"
  git -C "$HOME_REPO" worktree add --quiet -b wt "$WT" main
}

in_dir() {
  ( cd "$1" && cmd_targets_foreign_repo "$2" )
}

@test "--repo <home> from a checkout not named for the repository: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home "gh pr merge 5 --repo acme/widget --squash"
  [ "$status" -ne 0 ]
}

@test "--repo <home> from a linked worktree: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  add_worktree
  run in_dir "$WT" "gh pr merge 5 --repo acme/widget --squash"
  [ "$status" -ne 0 ]
}

@test "-R, =, URL, .git and case spellings of <home> from a linked worktree: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  add_worktree
  run in_dir "$WT" "gh pr merge 5 -R acme/widget"
  [ "$status" -ne 0 ]
  run in_dir "$WT" "gh pr merge 5 --repo=acme/widget"
  [ "$status" -ne 0 ]
  run in_dir "$WT" "gh pr merge 5 --repo https://github.com/acme/widget.git"
  [ "$status" -ne 0 ]
  run in_dir "$WT" "gh pr merge 5 --repo github.com/acme/widget"
  [ "$status" -ne 0 ]
  run in_dir "$WT" "gh pr merge 5 --repo ACME/Widget"
  [ "$status" -ne 0 ]
}

# The capture reads the raw command text, so a quoted value arrives with its
# quotes while gh receives it without them.
@test "quoted spellings of <home>: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home 'gh pr merge 5 --repo "acme/widget"'
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 --repo 'acme/widget'"
  [ "$status" -ne 0 ]
  run in_home 'gh pr merge 5 -R "acme/widget"'
  [ "$status" -ne 0 ]
  run in_home 'gh pr merge 5 --repo="acme/widget"'
  [ "$status" -ne 0 ]
}

@test "quoted spelling of another repository: foreign (allow)" {
  add_widget_remote "$HOME_REPO"
  run in_home 'gh pr merge 5 --repo "acme/other"'
  [ "$status" -eq 0 ]
}

@test "--repo value still carrying a quote after one layer is stripped: home (enforce, fail closed)" {
  add_widget_remote "$HOME_REPO"
  run in_home 'gh pr merge 5 --repo "acme/other x"'
  [ "$status" -ne 0 ]
  run in_home 'gh pr merge 5 --repo acme/other\"'
  [ "$status" -ne 0 ]
}

@test "--repo naming another repository from a linked worktree: foreign (allow)" {
  add_widget_remote "$HOME_REPO"
  add_worktree
  run in_dir "$WT" "gh pr merge 5 --repo acme/other --squash"
  [ "$status" -eq 0 ]
}

@test "--repo <name> of any remote reads as home, so a same-named fork over-enforces" {
  git -C "$HOME_REPO" remote add origin git@github.com:me/widget.git
  run in_home "gh pr merge 5 --repo acme/widget"
  [ "$status" -ne 0 ]
}

@test "--repo with no remote to name the home repository: home (enforce, fail closed)" {
  run in_home "gh pr merge 5 --repo acme/other"
  [ "$status" -ne 0 ]
}

@test "--repo value not shaped [HOST/]OWNER/REPO: home (enforce, fail closed)" {
  add_widget_remote "$HOME_REPO"
  run in_home "gh pr merge 5 --repo other"
  [ "$status" -ne 0 ]
}

@test "git -C <main checkout> from a linked worktree: home (enforce)" {
  add_worktree
  run in_dir "$WT" "git -C \"$HOME_REPO\" push origin main"
  [ "$status" -ne 0 ]
}

@test "git -C <linked worktree> from the main checkout: home (enforce)" {
  add_worktree
  run in_home "git -C $WT commit -m x"
  [ "$status" -ne 0 ]
}

@test "cd <main checkout> && git push from a linked worktree: home (enforce)" {
  add_worktree
  run in_dir "$WT" "cd '$HOME_REPO' && git push origin main"
  [ "$status" -ne 0 ]
}

@test "git -C <sibling repository> from a linked worktree: foreign (allow)" {
  add_worktree
  run in_dir "$WT" "git -C \"$SIBLING_REPO\" push origin main"
  [ "$status" -eq 0 ]
}

@test "two git -C flags: home (enforce, the last-wins form is not modelled)" {
  run in_home "git -C $SIBLING_REPO -C $SIBLING_REPO push origin main"
  [ "$status" -ne 0 ]
}

# A copy of the library with no main-checkout resolver beside it cannot say
# which repository a -C target belongs to, so it must enforce rather than
# fall back to comparing toplevels, which is the comparison that misreads a
# linked worktree.
@test "git -C <sibling> with the main-root resolver unavailable: home (enforce, fail closed)" {
  local stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage/.claude/hooks/lib"
  cp "$LIB" "$stage/.claude/hooks/lib/repo-scope.sh"
  run bash -c 'cd "$1" && . "$2" && cmd_targets_foreign_repo "$3"' _ \
    "$HOME_REPO" "$stage/.claude/hooks/lib/repo-scope.sh" \
    "git -C $SIBLING_REPO push origin main"
  [ "$status" -ne 0 ]
}

# An exported GIT_DIR answers every git call regardless of -C, so read
# through it the sibling and home would share one common directory.
@test "git -C <sibling> with GIT_DIR exported for the home repo: foreign (allow)" {
  run bash -c 'cd "$1" && . "$2" && GIT_DIR="$1/.git" && export GIT_DIR && cmd_targets_foreign_repo "$3"' _ \
    "$HOME_REPO" "$LIB" "git -C $SIBLING_REPO push origin main"
  [ "$status" -eq 0 ]
}
