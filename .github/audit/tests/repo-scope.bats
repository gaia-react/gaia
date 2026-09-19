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

@test "--repo value the shell expands: home (enforce, fail closed)" {
  add_widget_remote "$HOME_REPO"
  run in_home 'gh pr merge 5 --repo {acme/widget,}'
  [ "$status" -ne 0 ]
  run in_home 'gh pr merge 5 --repo acme/{widget,}'
  [ "$status" -ne 0 ]
  run in_home 'gh pr merge 5 --repo acme/widge?'
  [ "$status" -ne 0 ]
  run in_home 'gh pr merge 5 --repo ~/widget'
  [ "$status" -ne 0 ]
}

@test "a leading cd target is published for the caller, and cleared when there is none" {
  add_worktree
  run bash -c 'cd "$1" && . "$2" && cmd_targets_foreign_repo "cd '"'"'$3'"'"' && git commit -m x"; printf "%s" "$GAIA_REPO_SCOPE_LEAD_CD"' _ "$HOME_REPO" "$LIB" "$WT"
  [ "$output" = "$WT" ]
  run bash -c 'cd "$1" && . "$2" && GAIA_REPO_SCOPE_LEAD_CD=stale && cmd_targets_foreign_repo "git commit -m x"; printf "%s" "$GAIA_REPO_SCOPE_LEAD_CD"' _ "$HOME_REPO" "$LIB"
  [ -z "$output" ]
  # A -C target belongs to its own segment, never to the command as a whole.
  run bash -c 'cd "$1" && . "$2" && cmd_targets_foreign_repo "git -C $3 status && git commit -m x"; printf "%s" "$GAIA_REPO_SCOPE_LEAD_CD"' _ "$HOME_REPO" "$LIB" "$WT"
  [ -z "$output" ]
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

# -----------------------------------------------------------------------------
# A `-R` that belongs to some other program is not gh's repository flag. The
# value was read from the whole command text, so a slash-bearing path operand
# anywhere in the tool call named a repository none of the home repo's remotes
# match: every commit guard sourcing this helper then skipped its rules for the
# whole command, and the merge gate exited before any clearance check (#2011).
#
# Each case needs a remote, because a home repo with none has no name to
# compare and already fails closed one line earlier, which would pass these
# for a reason that has nothing to do with what they pin.
# -----------------------------------------------------------------------------

@test "another program's -R operand does not name a repository: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home "cp -R app/foo /tmp/x && git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "grep -R app/routes . && git commit -m y"
  [ "$status" -ne 0 ]
}

@test "a trailing command's -R does not decide the gh invocation: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home "gh pr merge 5 && ls -R a/b"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 30 --squash && grep -R app/routes ."
  [ "$status" -ne 0 ]
}

# The scan hands back unquoted WORDS, so a flag value carrying the text of
# another flag stays one word and never reads as that flag.
@test "--repo text inside a quoted flag value does not name a repository: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home 'gh pr merge 30 --squash --body "see --repo foo/bar for context"'
  [ "$status" -ne 0 ]
}

@test "the gh invocation's own --repo still decides: foreign (allow)" {
  add_widget_remote "$HOME_REPO"
  run in_home "gh pr merge 5 --repo other-org/other-repo"
  [ "$status" -eq 0 ]
  run in_home "gh pr merge 5 -R other-org/other-repo --squash"
  [ "$status" -eq 0 ]
}

# A command whose first word is not `gh` carries no repository flag to read, so
# the arms below it decide, and the leading `cd` reaches the publish it used to
# be cut off from by any `-R` in the tool call.
@test "a leading cd is published even when a later command carries a -R" {
  add_worktree
  run bash -c 'cd "$1" && . "$2" && cmd_targets_foreign_repo "cd '"'"'$3'"'"' && git commit -m x && grep -R TODO app"; printf "%s" "$GAIA_REPO_SCOPE_LEAD_CD"' _ "$HOME_REPO" "$LIB" "$WT"
  [ "$output" = "$WT" ]
}

# -----------------------------------------------------------------------------
# One verdict covers the whole tool call, so it has to be HOME whenever any
# command in the call acts on the home repository. Judging the call by one
# command let a foreign first `gh` exempt a home commit after it, a trailing
# foreign `git -C` exempt a home commit before it, and a leading `cd` into a
# sibling exempt a commit made after stepping back out (gaia-react/gaia#2081).
# A call is foreign only when every command in it is foreign-acting or touches
# no repository at all.
# -----------------------------------------------------------------------------

@test "a foreign first gh does not exempt a home command after it: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home "gh pr merge 5 -R other/x && git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x; git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x
git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 --repo=other/x && git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "gh pr view 5 -R other/x && gh pr merge 7 --squash"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x && gh pr merge 7 -R acme/widget"
  [ "$status" -ne 0 ]
}

@test "a trailing foreign git -C does not exempt a home command before it: home (enforce)" {
  run in_home "git commit -m y && git -C $SIBLING_REPO status"
  [ "$status" -ne 0 ]
  run in_home "git commit --no-verify -m y && git -C '$SIBLING_REPO' status"
  [ "$status" -ne 0 ]
}

@test "a cd into a sibling does not exempt a command after stepping back out: home (enforce)" {
  run in_home "cd $SIBLING_REPO && git status && cd - && git commit --no-verify -m y"
  [ "$status" -ne 0 ]
  run in_home "cd $SIBLING_REPO; git status; cd $HOME_REPO; git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "cd $SIBLING_REPO && git status && cd && git commit -m y"
  [ "$status" -ne 0 ]
}

@test "a command after a foreign one that cannot be read stays home (enforce, fail closed)" {
  add_widget_remote "$HOME_REPO"
  run in_home "gh pr merge 5 -R other/x && (git commit -m y)"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x && FOO=1 git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x && env git commit -m y"
  [ "$status" -ne 0 ]
  # shellcheck disable=SC2016 # the unexpanded substitution is the case
  run in_home 'gh pr merge 5 -R other/x && echo $(git commit -m y)'
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x && bash -c 'git commit -m y'"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x # note
git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x && cd $SIBLING_REPO && gh pr merge 7 -Racme/widget"
  [ "$status" -ne 0 ]
}

# The walk stops once nothing left in the call names git or gh, so that check
# has to see a name the shell assembles from quotes, escapes and a line
# continuation exactly as the scan does.
@test "a home git spelled with quotes, escapes or a continuation after a foreign one: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home 'gh pr merge 5 -R other/x && g\it commit -m y'
  [ "$status" -ne 0 ]
  run in_home 'gh pr merge 5 -R other/x && "g"it commit -m y'
  [ "$status" -ne 0 ]
  run in_home "gh pr merge 5 -R other/x && gi\\
t commit -m y"
  [ "$status" -ne 0 ]
}

# A `cd` the shell keeps away from the commands after it must not move the
# directory those commands are read against, or a home command after it reads
# foreign and the whole call is exempted.
@test "a cd the shell scopes away does not move a later home command: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  local f="gh pr view 5 -R other/x"
  run in_home "$f
(
cd $SIBLING_REPO
)
git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f
x=\$(
cd $SIBLING_REPO
)
git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f
f() {
cd $SIBLING_REPO
}
git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f
cat <<EOF
cd $SIBLING_REPO
EOF
git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f; if false; then cd $SIBLING_REPO; fi; git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f; cd $SIBLING_REPO & git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f; cd $SIBLING_REPO | cat; git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f; echo | cd $SIBLING_REPO; git commit -m y"
  [ "$status" -ne 0 ]
}

@test "a cd that may not run does not move a later home command: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  local f="gh pr view 5 -R other/x"
  run in_home "$f; false && cd $SIBLING_REPO; git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f; cd $SIBLING_REPO || git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f; false && cd $SIBLING_REPO # note
git commit -m y"
  [ "$status" -ne 0 ]
}

# A comment on a line of its own does not end the list or pipeline a
# trailing `&&`, `||` or `|` carries onto the next line.
@test "a cd continued past a comment line after &&, || or | does not move a later home command: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  local f="gh pr view 5 -R other/x"
  run in_home "$f; false && # c
cd $SIBLING_REPO
git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f; true || # c
cd $SIBLING_REPO
git commit -m y"
  [ "$status" -ne 0 ]
  run in_home "$f; echo | # c
cd $SIBLING_REPO
git commit -m y"
  [ "$status" -ne 0 ]
}

# The scan models neither heredocs nor ANSI-C quoting, so a stray apostrophe
# can open a span the shell never opened and fold the home commands after it
# into one word of a foreign command.
@test "home commands folded into a foreign command by a quote the shell never opened: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home "cat <<EOF
gh pr view 5 -R other/x --title don't
EOF
git commit -m y
echo \"it's\""
  [ "$status" -ne 0 ]
  local ansi
  ansi="gh pr view 5 -R other/x \$'\\''; git commit --no-verify -m 'x'"
  run in_home "$ansi"
  [ "$status" -ne 0 ]
  run in_home "gh pr create -R other/x --title t --body 'mentions git only'"
  [ "$status" -eq 0 ]
}

# The shell runs a substitution in its own directory before the command that
# holds it, so a foreign command's `-R` or `git -C` never reaches the payload
# (gaia-react/gaia#2148). The scan keeps a quoted substitution as one word and
# splits an unquoted one at its spaces, so both spellings are pinned.
@test "a substitution naming git or gh in a foreign command's arguments: home (enforce)" {
  add_widget_remote "$HOME_REPO"
  run in_home 'gh pr view 5 -R other/x --jq "$(gh pr merge 30 --squash)"'
  [ "$status" -ne 0 ]
  run in_home 'gh pr view 5 -R other/x --jq $( gh pr merge 30 --squash )'
  [ "$status" -ne 0 ]
  run in_home 'gh pr view 5 -R other/x --jq `gh pr merge 30`'
  [ "$status" -ne 0 ]
  run in_home "gh pr create -R other/x --body-file <(git commit -m y)"
  [ "$status" -ne 0 ]
  run in_home "gh pr diff 5 -R other/x --patch >(git apply)"
  [ "$status" -ne 0 ]
  run in_home "git -C $SIBLING_REPO log --format \"\$(git commit -m y)\""
  [ "$status" -ne 0 ]
}

@test "a foreign command with no substitution naming git or gh stays foreign (allow)" {
  add_widget_remote "$HOME_REPO"
  run in_home "gh pr view 5 -R other/x --jq '.number'"
  [ "$status" -eq 0 ]
  run in_home 'gh pr view 5 -R other/x --jq "$(cat filter.jq)"'
  [ "$status" -eq 0 ]
  run in_home "git -C $SIBLING_REPO log --format '%H'"
  [ "$status" -eq 0 ]
}

@test "a cd the shell certainly runs still moves the commands after it: foreign (allow)" {
  run in_home "cd $SIBLING_REPO && git pull; git push"
  [ "$status" -eq 0 ]
  run in_home "cd $SIBLING_REPO
git pull
git push"
  [ "$status" -eq 0 ]
  run in_home "git -C $SIBLING_REPO fetch && cd $SIBLING_REPO && git pull"
  [ "$status" -eq 0 ]
}

# The walk costs the call's length once per command, so it is bounded.
@test "a long call ending in a home command is read home, inside the ceiling" {
  add_widget_remote "$HOME_REPO"
  local big i t0 t1
  big="gh pr view 5 -R other/x"
  for i in $(seq 1 4000); do big="$big
echo line $i with some ordinary prose"; done
  big="$big
git commit -m y"
  t0=$(date +%s)
  run in_home "$big"
  t1=$(date +%s)
  [ "$status" -ne 0 ]
  echo "walk 4000 lines: $((t1 - t0))s (ceiling 3s)" >&2
  [ "$((t1 - t0))" -le 3 ]
}

@test "a foreign call longer than the walk reads is enforced: home (fail closed)" {
  local big i
  big="cd $SIBLING_REPO"
  for i in $(seq 1 200); do big="$big
git status"; done
  run in_home "$big"
  [ "$status" -ne 0 ]
  run in_home "cd $SIBLING_REPO
git status"
  [ "$status" -eq 0 ]
}

# The line the rule must not cross: "nothing may follow a foreign command"
# would over-enforce every legitimate sibling merge paired with a trailer.
@test "a call whose every command is foreign or touches no repository stays foreign (allow)" {
  add_widget_remote "$HOME_REPO"
  run in_home "gh pr merge 5 -R other/x && gh pr checks 5 -R other/x"
  [ "$status" -eq 0 ]
  run in_home "gh pr merge 5 -R other/x && git -C $SIBLING_REPO pull"
  [ "$status" -eq 0 ]
  run in_home "gh pr merge 5 -R other/x && echo done"
  [ "$status" -eq 0 ]
  run in_home "gh pr merge 5 -R other/x # git commit -m y"
  [ "$status" -eq 0 ]
  run in_home "cd $SIBLING_REPO && git pull && gh pr merge 5 --squash"
  [ "$status" -eq 0 ]
  run in_home "git -C $SIBLING_REPO status && git -C $SIBLING_REPO log"
  [ "$status" -eq 0 ]
}

# The scan reports byte offsets and the walk skips a comment by slicing at
# one, so a walk slicing in characters under a UTF-8 locale would miss the `#`
# after multibyte text and read the comment's words as a command.
@test "a comment after multibyte text is skipped, not read as a command: foreign (allow)" {
  local utf8
  utf8=$(locale -a 2>/dev/null | grep -i -m1 -E '^(C|en_US)\.utf-?8$') || skip "no UTF-8 locale"
  add_widget_remote "$HOME_REPO"
  run bash -c 'export LC_ALL="$4"; cd "$1" && . "$2" && cmd_targets_foreign_repo "$3"' _ \
    "$HOME_REPO" "$LIB" "gh pr merge 5 -R other/x --body 'éééééééééé' # see git log" "$utf8"
  [ "$status" -eq 0 ]
}

@test "a call that names no repository at all stays home (enforce)" {
  run in_home "echo done"
  [ "$status" -ne 0 ]
  run in_home "cd $SIBLING_REPO"
  [ "$status" -ne 0 ]
}
