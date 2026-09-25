#!/usr/bin/env bats

# Tests for .claude/hooks/block-main-destructive-git.sh. The hook's own header
# states what it blocks. It fires only on a real `git` INVOCATION in command
# position; command text that merely mentions `git commit` / `git push` (a grep
# pattern, an echo string, an argument to another program) does not trip it.
#
# Each test drives the hook as the harness does: a PreToolUse JSON payload on
# stdin, run with the repo as the working directory, which is where the hook
# resolves the current branch. The hook always exits 0; allow vs deny is carried
# in stdout.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-main-destructive-git.sh"

  REPO=$(mktemp -d -t block-main-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  # A second, distinct repo for the foreign-repo case.
  FOREIGN=$(mktemp -d -t block-main-foreign-XXXXXX)
  git -C "$FOREIGN" init --quiet --initial-branch=main
  git -C "$FOREIGN" config user.email "test@example.com"
  git -C "$FOREIGN" config user.name "Test"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${FOREIGN:-}" ] && rm -rf "$FOREIGN" || true
  return 0
}

on_main() { git -C "$REPO" checkout --quiet main; }
on_feature() { git -C "$REPO" checkout --quiet -B feature; }

# Run the hook with a given command, from inside the home repo.
run_hook() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABS"
}

# Same, for a case whose verdict turns on the directory the command runs in:
# the payload carries that directory as its cwd and the hook is invoked there.
run_hook_from() {
  local json
  json=$(jq -n --arg c "$1" --arg d "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}')
  invoke_hook_in "$2" "$json" "$HOOK_ABS"
}



# --- denied ---

@test "git commit on main is denied" {
  on_main
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

@test "plain git push from main is denied" {
  on_main
  run_hook 'git push'
  assert_denied_by_json
}

@test "git push origin main (refspec) is denied from a feature branch" {
  on_feature
  run_hook 'git push origin main'
  assert_denied_by_json
}

@test "force-push to main is denied from a feature branch" {
  on_feature
  run_hook 'git push --force origin main'
  assert_denied_by_json
}

@test "home-repo git -C commit on main is denied" {
  on_main
  run_hook "git -C $REPO commit -m \"x\""
  assert_denied_by_json
}

# A `-R` belonging to another program in the same tool call was read as gh's
# repository flag, so the shared repo-scope helper answered "foreign" and this
# guard skipped its commit rule for the whole command (#2011). The remote is
# required: with none, the helper has no repository name to compare and fails
# closed a line earlier, which would pass this test without exercising it.
@test "a trailing program's -R does not exempt a commit on main" {
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  on_main
  run_hook 'git commit -m x && grep -R app/routes .'
  assert_denied_by_json
}

# `-C` after the subcommand is commit's reuse-message option, not a directory.
@test "git commit -C HEAD on main is denied" {
  on_main
  run_hook 'git commit --allow-empty -C HEAD'
  assert_denied_by_json
  run_hook 'git commit --allow-empty -m x -C HEAD'
  assert_denied_by_json
}

# A git global option ahead of the subcommand hid the invocation from the
# commit and push rules, which matched the subcommand only where it sat
# directly after the word `git`, so the PR-only flow was defeated by an option
# with nothing to do with the branch (#2003).
@test "a git global option ahead of commit does not hide it on main" {
  on_main
  run_hook 'git -c user.name=x commit -m "y"'
  assert_denied_by_json
  run_hook 'git --no-pager commit -m "y"'
  assert_denied_by_json
}

@test "a git global option ahead of push does not hide it on main" {
  on_main
  run_hook 'git -c pack.threads=1 push'
  assert_denied_by_json
  run_hook 'git --no-pager push'
  assert_denied_by_json
}

@test "a git global option ahead of a refspec push naming main does not hide it" {
  on_feature
  run_hook 'git -c pack.threads=1 push origin main'
  assert_denied_by_json
  run_hook 'git --no-pager push origin HEAD:main'
  assert_denied_by_json
}

# Arming the push rules on the parsed subcommand brings a global option's own
# VALUE within reach of the force and main/master tests, which the old literal
# `git push` anchor excluded by construction. A `-c` value is not a refspec, so
# reading one as a push target is a false deny the arming must not introduce.
@test "a git -c value naming main does not read as a force-push to main" {
  on_feature
  run_hook 'git -c user.name=main push --force origin feature'
  assert_allowed_by_json
}

# The short force flag is the first word after the subcommand, so a pattern
# demanding whitespace before it matches in the whole segment and misses in the
# argument list.
@test "the short force flag as the first push argument is still denied to main" {
  on_feature
  run_hook 'git push -f origin main'
  assert_denied_by_json
}

# The segment was split on whitespace alone, so a quoted global-option value
# carrying a space arrived as fragments and the fragment after the space landed
# in the slot the subcommand is read from. Every rule armed on that slot then
# read a subcommand nobody spelled, and a commit on main was allowed (#2020).
@test "a quoted global-option value carrying whitespace does not hide the subcommand on main" {
  on_main
  run_hook 'git -c "user.name=a b" commit -m x'
  assert_denied_by_json
  run_hook "git -c 'user.name=a b' commit -m x"
  assert_denied_by_json
  run_hook 'git --namespace "a b" commit -m x'
  assert_denied_by_json
  run_hook 'git -c "user.name=a b" push origin main'
  assert_denied_by_json
  run_hook 'git -c "user.name=a b" push --force origin main'
  assert_denied_by_json
}

# The quoting was never the mechanism. A value-taking global the parser's table
# did not list fell to the unknown-option arm, and its VALUE reached the same
# slot, so these spellings disarm the rules with no quoting and no whitespace at
# all. The `=`-joined form denying is what made the separated ones easy to
# miss (#2020).
@test "a global option taking a separated value does not hide the subcommand on main" {
  on_main
  run_hook 'git --attr-source HEAD commit -m x'
  assert_denied_by_json
  run_hook 'git --config-env user.name=ENVVAR commit -m x'
  assert_denied_by_json
  run_hook 'git --attr-source HEAD push origin main'
  assert_denied_by_json
  run_hook 'git --config-env=user.name=ENVVAR commit -m x'
  assert_denied_by_json
  run_hook 'git --exec-path=/usr/bin commit -m x'
  assert_denied_by_json
}

# `--exec-path` has no separated-value form: without `=`, git prints its exec
# path and exits, so the words after it never run. Skipping the next word as its
# value would deny a command that commits and pushes nothing.
@test "a bare --exec-path is not read as taking the next word as its value" {
  on_main
  run_hook 'git --exec-path /usr/bin commit -m x'
  assert_allowed_by_json
  run_hook 'git --exec-path /usr/bin push origin main'
  assert_allowed_by_json
}

# The same split reaching the directory the branch is read from: the `-C` value
# broke at the space, so the rules resolved a branch from a path git could not
# open, read no branch at all, and allowed the commit (#2020).
@test "a -C path carrying whitespace is still enforced on main" {
  local spaced="$BATS_TEST_TMPDIR/dir with space"
  mkdir -p "$spaced"
  git -C "$spaced" init --quiet --initial-branch=main
  git -C "$spaced" config user.email "test@example.com"
  git -C "$spaced" config user.name "Test"
  git -C "$spaced" config commit.gpgsign false
  echo "# readme" > "$spaced/README.md"
  git -C "$spaced" add README.md
  git -C "$spaced" commit --quiet -m init
  run_hook_from "git -C \"$spaced\" commit -m x" "$spaced"
  assert_denied_by_json
}

# The ref was pinned to the word after the remote, so an option written ahead of
# the remote shifted both positions and the push was allowed. Rule 2 still caught
# the shape when a force flag was present, which is what left the plain push as
# the hole (#2021).
@test "an option ahead of the remote does not hide a refspec push naming main" {
  on_feature
  run_hook 'git push --quiet origin main'
  assert_denied_by_json
  run_hook 'git push -q origin main'
  assert_denied_by_json
  run_hook 'git push --quiet origin HEAD:main'
  assert_denied_by_json
  run_hook 'git push --quiet --no-verify origin master'
  assert_denied_by_json
}

# The operands after the remote are all refspecs, so a push naming several is
# read whole rather than at its first one, and a `--` ends option parsing
# without itself becoming the remote (#2021).
@test "a refspec naming main is read past an earlier refspec and past a -- separator" {
  on_feature
  run_hook 'git push --quiet origin feature main'
  assert_denied_by_json
  run_hook 'git push origin -- main'
  assert_denied_by_json
  run_hook 'git push --quiet origin +main'
  assert_denied_by_json
}

# Two independent conditions reach this deny and their repairs differ, so each
# one carries its own message. An operator denied for the refspec is already
# standing on a feature branch:
# telling them to create one names a cause they have ruled out and never names
# the respelling that clears the deny.
@test "a refspec-triggered push deny names the refspec cause, not the branch" {
  on_feature
  run_hook 'git push origin HEAD'
  assert_denied_by_json
  grep -qF -- 'refspec names main, master or HEAD' <<<"$output"
  grep -qF -- 'Create a feature branch and open a PR' <<<"$output" && return 1
  true
}

# The on-main cause keeps its own repair, and it answers first where both
# conditions hold: leaving main settles the refspec too, so the operator reads
# the repair that clears the push rather than the narrower one.
@test "an on-main push deny names the branch cause, and outranks the refspec cause" {
  on_main
  run_hook 'git push'
  assert_denied_by_json
  grep -qF -- 'Create a feature branch and open a PR' <<<"$output"
  run_hook 'git push origin main'
  assert_denied_by_json
  grep -qF -- 'Create a feature branch and open a PR' <<<"$output"
  grep -qF -- 'refspec names main, master or HEAD' <<<"$output" && return 1
  true
}

# --- allowed ---

# The operand scan must not read an ordinary feature push as a push to main, and
# a push option's own value is not a refspec.
@test "an option ahead of the remote does not create a false deny on a feature push" {
  on_feature
  run_hook 'git push --quiet origin feature'
  assert_allowed_by_json
  run_hook 'git push -o ci.skip origin feature'
  assert_allowed_by_json
  run_hook 'git push --quiet --no-verify origin feature'
  assert_allowed_by_json
}

# Modelling quotes must not buy the deny side at the cost of a false deny: a
# quoted argument carrying a branch name is ordinary text, and a push option's
# own quoted value is not a refspec.
@test "a quoted argument carrying whitespace does not create a false deny on a feature branch" {
  on_feature
  run_hook 'git commit -m "touch up main and master"'
  assert_allowed_by_json
  run_hook 'git push origin feature -o "ci.skip main"'
  assert_allowed_by_json
}

@test "git commit on a feature branch is allowed" {
  on_feature
  run_hook 'git commit -m "x"'
  assert_allowed_by_json
}

@test "git push origin feature from a feature branch is allowed" {
  on_feature
  run_hook 'git push origin feature'
  assert_allowed_by_json
}

@test "plain git push from a feature branch is allowed" {
  on_feature
  run_hook 'git push'
  assert_allowed_by_json
}

@test "foreign-repo commit is allowed even though it targets main" {
  on_main
  run_hook "git -C $FOREIGN commit -m \"x\""
  assert_allowed_by_json
}

# The repo-scope verdict covers the whole tool call, so any home command in it
# keeps the guard armed (gaia-react/gaia#2081).
@test "a foreign command in the same call does not exempt a commit on main" {
  on_main
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  run_hook 'gh pr merge 5 -R other/x && git commit -m y'
  assert_denied_by_json
  run_hook 'gh pr merge 5 -R other/x; git commit -m y'
  assert_denied_by_json
  run_hook "gh pr merge 5 -R other/x
git commit -m y"
  assert_denied_by_json
  run_hook "git commit -m y && git -C $FOREIGN status"
  assert_denied_by_json
}

# A substitution in a foreign command's own arguments runs in this repository
# before the foreign command does (gaia-react/gaia#2148).
@test "a commit inside a substitution in a foreign command's arguments is denied on main" {
  on_main
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  run_hook 'gh pr view 5 -R other/x --jq "$(git commit -m y)"'
  assert_denied_by_json
  run_hook "git -C $FOREIGN log --format \"\$(git commit -m y)\""
  assert_denied_by_json
  run_hook "gh pr create -R other/x --body-file =(git commit -m y)"
  assert_denied_by_json
}

@test "a call whose every command is foreign still passes a commit to main" {
  on_main
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  run_hook "gh pr merge 5 -R other/x && git -C $FOREIGN commit -m y"
  assert_allowed_by_json
}

# A linked worktree is this repository, so a `cd` into one is enforced, and
# enforced against the branch the command runs on rather than the session's.
@test "cd into a linked worktree on its own branch, from a main checkout on main: commit and push are allowed" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$wt' && git commit -m x" "$REPO"
  assert_allowed_by_json
  run_hook_from "cd '$wt' && git push origin wt-branch" "$REPO"
  assert_allowed_by_json
}

@test "cd into the main checkout on main, from a linked worktree: commit is denied" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$REPO' && git commit -m x" "$wt"
  assert_denied_by_json
}

# The walk's own boundary between the command's reading and the collapsed
# re-emission travels on the same line stream the command text does, and the
# arm consuming it clears the tracked directory. A boundary spelled the same
# way on every run would be one the guarded command can write for itself, so
# the fixed spelling must not move the verdict.
@test "command text spelling the walk-reset boundary does not clear the tracked directory" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$REPO';__gaia_walk_reset__;git commit -m x" "$wt"
  assert_denied_by_json
  run_hook_from "cd '$REPO';__gaia_walk_reset__;git push" "$wt"
  assert_denied_by_json
}

@test "a leading cd whose target does not resolve, from a main checkout on main: commit and push are denied" {
  on_main
  # shellcheck disable=SC2016 # the literal, unexpanded variable is the case
  run_hook_from 'cd "$UNSET_VAR" && git commit -m x' "$REPO"
  assert_denied_by_json
  run_hook_from 'cd /nonexistent; git commit -m x' "$REPO"
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook_from 'cd ${ROOT}; git push' "$REPO"
  assert_denied_by_json
}

# A failed `cd` leaves the real shell standing in the directory the previous
# one moved into, so a target that does not resolve must keep the tracked
# directory rather than clear it. The single-`cd` shape above pins the
# clear-to-nothing case from the main checkout, where the fallback happens to
# be main either way.
#
# This case reads the two-hop shape from another checkout. It does not isolate
# the keep on its own: the main checkout is also an ambiguity candidate here,
# so the deny it asserts has two possible sources. The pair further down,
# driving a fixture where no ambiguity candidate stands on main, is what pins
# the keep by itself.
@test "a second cd whose target does not resolve keeps the checkout the first one moved into" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$REPO'; cd /nonexistent; git commit -m x" "$wt"
  assert_denied_by_json
  run_hook_from "cd '$REPO'; cd /nonexistent; git push" "$wt"
  assert_denied_by_json
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from "cd '$REPO'; cd \"\$UNSET_VAR\"; git commit -m x" "$wt"
  assert_denied_by_json
}

# A resolvable second hop still replaces the first, so keeping the previous
# target on a failed resolve does not pin the walk to the leading `cd`.
@test "a second cd that does resolve still replaces the checkout the first one moved into" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$REPO'; cd '$wt'; git commit -m x" "$wt"
  assert_allowed_by_json
}

# The other half of an unresolvable `cd`, and the one keeping the previous
# target cannot answer on its own: the hop may have SUCCEEDED into a checkout
# the scan cannot name. `cd -` is the common spelling and it lands back where
# the shell started, so a command that steps into a worktree and back reads
# the worktree's branch while the commit lands in the main checkout. Neither
# reading is knowable here, so a candidate standing on main arms the rule.
@test "a second cd that may have stepped back into the main checkout is denied" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$wt' && cd - && git commit -m x" "$REPO"
  assert_denied_by_json
  run_hook_from "cd '$wt' && cd - && git push" "$REPO"
  assert_denied_by_json
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from "cd '$wt'; cd \"\$BACK\"; git commit -m x" "$REPO"
  assert_denied_by_json
}

# The ambiguity arm reads candidates, not the session: from a checkout that is
# not on main, an unresolvable hop off a worktree has nothing on main to find
# and stays allowed, so the arm above is not a blanket deny on `cd -`.
@test "an unresolvable second cd is allowed when no candidate checkout is on main" {
  on_feature
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$wt' && cd - && git commit -m x" "$REPO"
  assert_allowed_by_json
}

# The mirror of the two arms above, and the shape a worktree session actually
# spells: from a linked worktree neither the tracked directory nor this hook's
# own is the main checkout, so an unreadable word pointing at it has to be
# tested against that checkout directly or the commit it lands there is read
# against the worktree's own branch and allowed.
@test "an unreadable cd target is read against the main checkout from a worktree" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from 'cd "$MAIN" && git commit -m x' "$wt"
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook_from 'cd "$MAIN" && git push' "$wt"
  assert_denied_by_json
  run_hook_from 'cd - && git commit -m x' "$wt"
  assert_denied_by_json
}

# And the control that keeps it from being a blanket deny on a worktree
# session: with the main checkout off main, the same unreadable hop has no
# candidate on main and is allowed.
@test "an unreadable cd target from a worktree is allowed when the main checkout is off main" {
  on_feature
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from 'cd "$MAIN" && git commit -m x' "$wt"
  assert_allowed_by_json
}

# A directory word the scan CAN read settles which checkout the segment acts
# in, whatever repository that word turns out to name. The ambiguity arm is
# for a word that resolves to NOTHING, and reading a readable sibling
# repository as ambiguous denied a commit landing in that sibling against THIS
# checkout's branch: the foreign stand-down is a whole-call verdict, so a home
# command sharing the call keeps the guard armed and the sibling segment
# reaches the directory read.
#
# These drive it from a linked worktree with the main checkout on main, which
# is the shape that separates the two readings: the worktree's own branch
# allows, and only a candidate found through the ambiguity arm denies.
foreign_on_sidebranch() {
  git -C "$FOREIGN" commit --quiet --allow-empty -m init
  git -C "$FOREIGN" checkout --quiet -B sidebranch
}

@test "a readable foreign -C beside a home command is not ambiguous" {
  on_main
  foreign_on_sidebranch
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "git status && git -C $FOREIGN commit -m x" "$wt"
  assert_allowed_by_json
  run_hook_from "git status && git -C $FOREIGN push" "$wt"
  assert_allowed_by_json
}

@test "a readable foreign cd beside a home command is not ambiguous" {
  on_main
  foreign_on_sidebranch
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "git status && cd $FOREIGN && git commit -m x" "$wt"
  assert_allowed_by_json
  run_hook_from "git status && cd $FOREIGN && git push" "$wt"
  assert_allowed_by_json
}

# The control that keeps the two arms above from reading as a blanket allow:
# with the sibling checkout itself on main, the `-C` read denies, and it
# denies naming the branch the commit actually lands on rather than reporting
# the checkout as unreadable.
@test "a readable foreign -C on main beside a home command denies on its own branch" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "git status && git -C $FOREIGN commit -m x" "$wt"
  assert_denied_by_json
  grep -qF -- 'cannot read' <<<"$output" && return 1
  grep -qF -- "Commits to 'main' are forbidden" <<<"$output"
}

# Rule 3's ambiguity arm answered ahead of its refspec arm, so an operator
# already on a feature branch was told the pushing checkout was unknown and
# offered a repair they had applied: spelling the directory literally only
# surfaces the refspec deny on the next attempt. The refspec verdict does not
# depend on which checkout the push runs from, so it is answered first.
@test "a refspec naming main is reported ahead of an unreadable directory" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from 'cd "$MAIN" && git push origin main' "$wt"
  assert_denied_by_json
  grep -qF -- 'refspec names main' <<<"$output"
}
# The two arms this branch adds to the directory read, each isolated from the
# ambiguity arm that would otherwise answer for them.
#
# Every other case here is driven from a checkout that is itself on main, or
# alongside a main checkout that is, so the ambiguity arm finds a candidate on
# main and denies whatever the two arms do: revert either one and the suite
# stays green. These drive three checkouts instead, with the session's own and
# the main checkout BOTH off main, which leaves the tracked `cd` target and
# the `-C` fallback as the only things that can produce the deny.
three_checkouts() {
  on_feature
  git -C "$REPO" worktree add --quiet -b feature-a "$BATS_TEST_TMPDIR/wt-a"
  git -C "$REPO" worktree add --quiet -b master "$BATS_TEST_TMPDIR/wt-b"
}

@test "the kept cd target is what denies when no ambiguity candidate is on main" {
  three_checkouts
  run_hook_from "cd '$BATS_TEST_TMPDIR/wt-b'; cd /nonexistent; git commit -m x" "$BATS_TEST_TMPDIR/wt-a"
  assert_denied_by_json
  run_hook_from "cd '$BATS_TEST_TMPDIR/wt-b'; cd /nonexistent; git push" "$BATS_TEST_TMPDIR/wt-a"
  assert_denied_by_json
}

@test "the -C fallback is what denies when no ambiguity candidate is on main" {
  three_checkouts
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from "cd '$BATS_TEST_TMPDIR/wt-b'; git -C \"\$UNSET_VAR\" commit -m x" "$BATS_TEST_TMPDIR/wt-a"
  assert_denied_by_json
}

# Same as run_hook_from, with HOME pointed at a named checkout. The directory
# read expands a literal tilde against it, and nothing else in the hook reads
# HOME, so this isolates that one arm.
run_hook_from_home() {
  local json
  json=$(jq -n --arg c "$1" --arg d "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}')
  run bash -c 'cd "$1" && printf %s "$2" | HOME="$4" bash "$3"' _ "$2" "$json" "$HOOK_ABS" "$3"
}

# A tilde reaches the directory read as a literal character: it arrived as text
# inside the tool call rather than through a shell. Both callers route their
# word through the expansion, and with no case driving one the arm can be
# removed with nothing going red, leaving a `-C ~` or a `cd ~` into a checkout
# on main reading nothing and allowing.
#
# Driven from a worktree with every other candidate off main, so the deny can
# only come from the expansion resolving.
# Both spellings the expansion admits are driven, the bare `~` and the `~/`
# prefix, since each is its own case arm and one says nothing about the other.
@test "a literal tilde in a -C is expanded before the branch is read" {
  three_checkouts
  run_hook_from_home 'git -C ~ commit -m x' "$BATS_TEST_TMPDIR/wt-a" "$BATS_TEST_TMPDIR/wt-b"
  assert_denied_by_json
  run_hook_from_home 'git -C ~ push' "$BATS_TEST_TMPDIR/wt-a" "$BATS_TEST_TMPDIR/wt-b"
  assert_denied_by_json
  run_hook_from_home 'git -C ~/. commit -m x' "$BATS_TEST_TMPDIR/wt-a" "$BATS_TEST_TMPDIR/wt-b"
  assert_denied_by_json
}

@test "a literal tilde in a cd is expanded before the branch is read" {
  three_checkouts
  run_hook_from_home 'cd ~ && git commit -m x' "$BATS_TEST_TMPDIR/wt-a" "$BATS_TEST_TMPDIR/wt-b"
  assert_denied_by_json
  run_hook_from_home 'cd ~/. && git commit -m x' "$BATS_TEST_TMPDIR/wt-a" "$BATS_TEST_TMPDIR/wt-b"
  assert_denied_by_json
}

# The expansion has to reach the branch read for a FOREIGN word too, not only
# a same-repository one: classifying on the expanded path and then reading a
# branch out of the literal `~` spelling answers nothing and allows.
@test "a literal tilde in a foreign -C is expanded before the branch is read" {
  three_checkouts
  run_hook_from_home 'git status && git -C ~ commit -m x' "$BATS_TEST_TMPDIR/wt-a" "$FOREIGN"
  assert_denied_by_json
}

# `ambiguous_main_branch` probes this hook's own working directory as well as
# the main checkout, and every other fixture here places the session where the
# main checkout already answers for it. This one separates them: the session's
# own worktree is the only candidate on main/master, and the tracked `cd` names
# a feature checkout, so the deny can only come from the working-directory
# probe.
@test "the working-directory candidate is what denies when the main checkout is off main" {
  three_checkouts
  run_hook_from "cd '$BATS_TEST_TMPDIR/wt-a'; cd /nonexistent; git commit -m x" "$BATS_TEST_TMPDIR/wt-b"
  assert_denied_by_json
  run_hook_from "cd '$BATS_TEST_TMPDIR/wt-a'; cd /nonexistent; git push" "$BATS_TEST_TMPDIR/wt-b"
  assert_denied_by_json
}

@test "a -C into a linked worktree does not lend its branch to a later bare commit on main" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "git -C $wt status && git commit -m x" "$REPO"
  assert_denied_by_json
}

# The `-C` word is read by a scan that models quoting but never expands, so a
# value it cannot resolve names no readable checkout. Reading a branch from it
# answers nothing and every branch-armed rule allows, which is why an
# unresolvable value falls back to the directory the command actually runs in.
@test "an unresolvable -C value does not disarm the branch-armed rules on main" {
  on_main
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from 'git -C "$UNSET_VAR" commit -m x' "$REPO"
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook_from 'git -C "$UNSET_VAR" push' "$REPO"
  assert_denied_by_json
  # shellcheck disable=SC2016 # a substitution is text to the scan, not a path
  run_hook_from 'git -C "$(pwd)" commit -m x' "$REPO"
  assert_denied_by_json
  run_hook_from 'git -C /nonexistent commit -m x' "$REPO"
  assert_denied_by_json
}

# An unresolvable `-C` falls back to the checkout a preceding `cd` named, and
# is ambiguous on the same terms an unresolvable `cd` is: the value the scan
# could not expand may name any checkout, the main one included. So the
# tracked `cd` answers the ordinary case, and a candidate on main still arms
# the rule even when that tracked `cd` is a worktree on its own branch.
@test "an unresolvable -C value is read against every checkout it could name" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from "cd '$wt'; git -C \"\$UNSET_VAR\" commit -m x" "$REPO"
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook_from "cd '$REPO'; git -C \"\$UNSET_VAR\" commit -m x" "$wt"
  assert_denied_by_json
}

# The tracked `cd` still decides a resolvable case: with nothing on main among
# the candidates, an unresolvable `-C` is allowed, so the arm above is driven
# by a candidate on main rather than by unresolvability alone.
@test "an unresolvable -C value is allowed when no candidate checkout is on main" {
  on_feature
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  # shellcheck disable=SC2016 # the hook must receive the unexpanded variable
  run_hook_from "cd '$wt'; git -C \"\$UNSET_VAR\" commit -m x" "$REPO"
  assert_allowed_by_json
}

# The leading `cd` target stood for every segment and a later `cd` did not
# replace it, so a command that stepped into a worktree and back read the
# worktree's branch and allowed a commit that landed on main (#2014).
@test "a later cd in the same command decides the checkout a commit is read against" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$wt' && git status && cd '$REPO' && git commit -m x" "$REPO"
  assert_denied_by_json
  run_hook_from "cd '$wt' && git status && cd '$REPO' && git push" "$REPO"
  assert_denied_by_json
}

@test "a later cd into a linked worktree is read in place of the leading one" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$REPO' && git status && cd '$wt' && git commit -m x" "$REPO"
  assert_allowed_by_json
}

# A `cd` inside a subshell moves nothing once the group closes, and the segment
# walk cannot tell which character it split at, so tracking stands down for the
# whole command and the commit is read against the hook's own directory (#2014).
@test "a cd inside a subshell does not lend its branch to a later commit on main" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "(cd '$wt' && git status) && git commit -m x" "$REPO"
  assert_denied_by_json
}

# The stand-down reads quoting rather than the bare character, because a commit
# subject routinely carries a parenthesis and standing tracking down on one
# would deny an ordinary commit made after a `cd` into a worktree (#2014).
@test "a parenthesis inside a quoted commit subject does not stand down cd tracking" {
  on_main
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hook_from "cd '$wt' && git commit -m 'debt(hooks): x'" "$REPO"
  assert_allowed_by_json
}

@test "a non-git command is ignored" {
  on_main
  run_hook 'pnpm run build'
  assert_allowed_by_json
}

# --- setup standdown: the .gaia/local/setup-in-progress sentinel suspends ---
# enforcement for /setup-gaia's greenfield finalize commit+push, then resumes.

@test "setup sentinel allows git commit on main" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git commit -m "x"'
  assert_allowed_by_json
}

@test "setup sentinel allows git push origin main from main" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git push origin main'
  assert_allowed_by_json
}

@test "enforcement resumes once the setup sentinel is removed" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git commit -m "x"'
  assert_allowed_by_json
  rm -f "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

@test "setup sentinel is a total standdown: force-push to main is allowed" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git push --force origin main'
  assert_allowed_by_json
}

@test "a stale setup sentinel self-heals: enforcement resumes without removal" {
  on_main
  mkdir -p "$REPO/.gaia/local"
  touch "$REPO/.gaia/local/setup-in-progress"
  # Age the sentinel past the freshness window. A leftover from a setup that
  # crashed before cleanup must NOT keep main-branch protection suspended.
  touch -t 200001010000 "$REPO/.gaia/local/setup-in-progress"
  run_hook 'git commit -m "x"'
  assert_denied_by_json
}

# --- command-position anchoring: the words appear, but git is not the program ---

@test "grep for the text 'git commit' is allowed on main" {
  on_main
  run_hook 'grep -n -e git commit app/foo.ts'
  assert_allowed_by_json
}

@test "echo of 'git push origin main' is allowed on main" {
  on_main
  run_hook 'echo "git push origin main"'
  assert_allowed_by_json
}

@test "echo 'git commit' piped to grep is allowed on main" {
  on_main
  run_hook 'echo git commit && grep -n foo bar'
  assert_allowed_by_json
}

# --- command-position anchoring still catches real invocations ---

@test "git commit after an unrelated piped command is denied on main" {
  on_main
  run_hook 'echo hi | git commit -m "x"'
  assert_denied_by_json
}

@test "git push origin main after && is denied" {
  on_feature
  run_hook 'true && git push origin main'
  assert_denied_by_json
}

# --- the staged-tree harness the degrade cases below share ---
#
# Each library load in this hook resolves off BASH_SOURCE, never off the process
# working directory, so expressing a degraded library needs a COPY of the hook in
# a tree the test controls: running the real $HOOK_ABS leaves it resolving the
# real checkout's libraries whatever a fixture does to a copy anywhere else.

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

stage_hook_tree() {
  STAGED_ROOT="$BATS_TEST_TMPDIR/staged"
  rm -rf "$STAGED_ROOT"
  mkdir -p "$STAGED_ROOT/.claude" "$STAGED_ROOT/.gaia/scripts"
  # The whole hooks directory, lib/ included, rather than the libraries this
  # hook happens to load today: an enumeration goes short the moment the hook
  # gains a load, and the cases below would then drive a hook degraded in a way
  # none of them names while still reporting green. Each case then degrades one
  # named library and nothing else, by corrupting it, by removing it, or by
  # relying on it never having been staged at all. Staging the directory
  # wholesale also keeps the jq-availability arm present, which runs ahead of
  # the loads under test and refuses when it cannot find its own library,
  # answering every case with that refusal instead of with the decision under
  # test.
  cp -R "$HOOKS_SRC" "$STAGED_ROOT/.claude/hooks"
  # Outside the hooks directory, so the wholesale copy above does not reach it.
  # This line stays a hand-maintained list for that reason: a further
  # .gaia/scripts load the hook's live path gains has to be added here, or it
  # goes short with nothing red.
  cp "${HOOKS_SRC%/.claude/hooks}/.gaia/scripts/main-root-lib.sh" "$STAGED_ROOT/.gaia/scripts/"
  git -C "$STAGED_ROOT" init --quiet --initial-branch=main
  git -C "$STAGED_ROOT" config user.email "test@example.com"
  git -C "$STAGED_ROOT" config user.name "Test"
  git -C "$STAGED_ROOT" config commit.gpgsign false
  echo "# readme" > "$STAGED_ROOT/README.md"
  git -C "$STAGED_ROOT" add README.md
  git -C "$STAGED_ROOT" commit --quiet -m init
  STAGED_HOOK="$STAGED_ROOT/.claude/hooks/block-main-destructive-git.sh"
}

# run_staged <command> [interpreter]
run_staged() {
  local json interp="${2:-}"
  json=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
  run bash -c 'cd "$1" && printf %s "$2" | $4 "$3"' _ "$STAGED_ROOT" "$json" "$STAGED_HOOK" "$interp"
}

# --- an unparseable repo-scope.sh degrades, it does not deny ---
#
# The repo-scope load sits under this hook's `set -euo pipefail`, so before the
# fix an unparseable copy abandoned the shell ahead of the `type
# cmd_targets_foreign_repo` check on the next line, exiting 2 -- the PreToolUse
# deny code -- for every git command the hook matches. That holds on bash 5 as
# well as on 3.2, so neither conflict-marker case below needs a /bin/bash pin to
# have teeth.
#
# The conflict-marker pair discriminates: the allow case alone is satisfied by a
# hook that stopped enforcing, so the deny twin proves the degrade kept the
# main-branch floor. Without cmd_targets_foreign_repo the foreign-repo carve-out
# does not fire, which is the fail-closed direction the hook's own repo-scope
# comment documents.
#
# The absent-library case pins the other direction, and an unbracketed load is
# not a probe that can red it: with the library missing, the `[ -f ]` guard ahead
# of the source short-circuits, and errexit exempts a non-final command in an
# `&&` list, so that path never reaches the source the bracket protects. What
# reds it is the degrade failing open, a missing library leaving the hook a
# pass-through instead of holding the main-branch floor.

@test "repo-scope.sh holding conflict markers: an ordinary git command is still allowed" {
  stage_hook_tree
  git -C "$STAGED_ROOT" checkout --quiet -B feature
  write_conflicted_lib "$STAGED_ROOT/.claude/hooks/lib/repo-scope.sh"
  run_staged 'git status'
  assert_allowed_by_json
}

@test "repo-scope.sh holding conflict markers: a commit on main is still denied" {
  stage_hook_tree
  write_conflicted_lib "$STAGED_ROOT/.claude/hooks/lib/repo-scope.sh"
  run_staged 'git commit -m "x"'
  assert_denied_by_json
}

@test "repo-scope.sh absent entirely: a commit on main is still denied" {
  stage_hook_tree
  rm -f "$STAGED_ROOT/.claude/hooks/lib/repo-scope.sh"
  run_staged 'git commit -m "x"'
  assert_denied_by_json
}

# --- an unparseable main-root-lib.sh degrades, it does not deny ---
#
# Pinned to stock /bin/bash: the `|| true` arm this load already carried
# survives on bash 5 and is abandoned ahead of on 3.2, so only a /bin/bash run
# tells the fix apart from the arm it replaced. On a bash-5 /bin/bash (Linux
# CI) these pass either way.

@test "control: the staged hook denies a commit on main under stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_tree
  run_staged 'git commit -m "x"' /bin/bash
  assert_denied_by_json
}

@test "main-root-lib.sh holding conflict markers: a commit on main is still denied, on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_tree
  write_conflicted_lib "$STAGED_ROOT/.gaia/scripts/main-root-lib.sh"
  run_staged 'git commit -m "x"' /bin/bash
  assert_denied_by_json
}

@test "main-root-lib.sh holding conflict markers: an ordinary git command is still allowed, on stock /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  stage_hook_tree
  git -C "$STAGED_ROOT" checkout --quiet -B feature
  write_conflicted_lib "$STAGED_ROOT/.gaia/scripts/main-root-lib.sh"
  run_staged 'git status' /bin/bash
  assert_allowed_by_json
}

# --- main-checkout hop guard ---
#
# A peer session moving the main checkout's HEAD off a branch another session
# holds there with an open pull request is denied. `gh` is a stub on PATH whose
# answer GH_STUB selects: `open:<n>` lists one open pull request, `none` lists
# nothing (merged, closed, never opened), `fail` exits non-zero, `hang` never
# answers, `hangwrap` never answers from a child the stub does NOT exec (the
# wrapper shape a real `gh` shim takes), `garbage` answers with something that
# is not a number. The owner is
# proved by the `gh pr create` breadcrumb, written here through the same lib the
# capture hook writes it with, so the path and shape cannot drift from the
# reader's.

stub_gh() {
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "pr list" ] || exit 1
case "${GH_STUB:-none}" in
  open:*) printf '%s\n' "${GH_STUB#open:}" ;;
  none) ;;
  fail) echo "gh: authentication required" >&2; exit 4 ;;
  hang) exec sleep 30 ;;
  hangwrap) sleep 30 ;;
  garbage) echo "not-a-number" ;;
esac
STUB
  chmod +x "$STUB_BIN/gh"
  export PATH="$STUB_BIN:$PATH"
}

# hold_feature_with_pr <number>: the main checkout sits on `feature`, a second
# branch `other` exists to switch to, and `feature` has an open pull request.
hold_feature_with_pr() {
  stub_gh
  git -C "$REPO" branch --quiet other
  git -C "$REPO" checkout --quiet -B feature
  export GH_STUB="open:$1"
}

write_breadcrumb() {
  local branch="$1" sid="$2" bc_path
  # shellcheck source=/dev/null
  . "${HOOKS_SRC%/.claude/hooks}/.gaia/scripts/gh-artifact-lib.sh"
  bc_path="$(gaia_gh_artifact_path "$REPO/.gaia/local/cache" "$branch")"
  gaia_gh_artifact_write "$bc_path" 42 example/repo "$branch" "$sid"
}

# run_hop <command> [session_id] [cwd]
run_hop() {
  local json
  json=$(jq -n --arg c "$1" --arg s "${2:-sid-peer}" --arg d "${3:-$REPO}" \
    '{tool_name: "Bash", session_id: $s, cwd: $d, tool_input: {command: $c}}')
  invoke_hook_in "${3:-$REPO}" "$json" "$HOOK_ABS"
}

@test "hop guard: a peer switching the main checkout off a branch with an open PR is denied" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git switch other' sid-peer
  assert_denied_by_json
  grep -qF -- "'feature'" <<<"$output"
  grep -qF -- '#42' <<<"$output"
  grep -qF -- 'worktree arm' <<<"$output"
  grep -qF -- 'with the ! prefix' <<<"$output"
}

@test "hop guard: a peer's git checkout main off a branch with an open PR is denied" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git checkout main' sid-peer
  assert_denied_by_json
  run_hop 'git checkout main 2>/dev/null' sid-peer
  assert_denied_by_json
  run_hop 'git checkout main > /dev/null' sid-peer
  assert_denied_by_json
}

@test "hop guard: checkout's branch-creating, detaching, and previous-branch forms are denied in a peer-held main checkout" {
  hold_feature_with_pr 42
  run_hop 'git checkout -b brand-new' sid-peer
  assert_denied_by_json
  run_hop 'git checkout -' sid-peer
  assert_denied_by_json
  run_hop 'git checkout --detach' sid-peer
  assert_denied_by_json
  run_hop 'git checkout -B brand-new' sid-peer
  assert_denied_by_json
  run_hop 'git checkout --orphan o2' sid-peer
  assert_denied_by_json
}

# `-C` after `switch` is force-create, not a directory, so reading it as git's
# own `-C` aimed the guard at a directory named for the branch and let it pass.
@test "hop guard: git switch -C in a peer-held main checkout is denied" {
  hold_feature_with_pr 42
  run_hop 'git switch -C other' sid-peer
  assert_denied_by_json
  run_hop 'git switch -C main main' sid-peer
  assert_denied_by_json
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hop "git -C $REPO switch -C other" sid-peer "$wt"
  assert_denied_by_json
}

@test "hop guard: git's own options ahead of the subcommand do not hide it" {
  hold_feature_with_pr 42
  run_hop 'git -c advice.detachedHead=false switch other' sid-peer
  assert_denied_by_json
  run_hop 'git --git-dir .git checkout main' sid-peer
  assert_denied_by_json
}

@test "hop guard: a checkout aimed at a different repository's main checkout is allowed" {
  hold_feature_with_pr 42
  git -C "$FOREIGN" commit --quiet --allow-empty -m init
  git -C "$FOREIGN" branch --quiet other
  git -C "$FOREIGN" checkout --quiet -B feature
  run_hop "git -C $FOREIGN switch other" sid-peer
  assert_allowed_by_json
}

@test "hop guard: a worktree session aiming git -C at the peer-held main checkout is denied" {
  hold_feature_with_pr 42
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hop "git -C $REPO checkout main" sid-peer "$wt"
  assert_denied_by_json
}

@test "hop guard: the session that created the PR may hop off its own branch" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git switch other' sid-owner
  assert_allowed_by_json
}

@test "hop guard: the owner is matched before any gh call" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  export GH_STUB=hang
  local start=$SECONDS
  run_hop 'git switch other' sid-owner
  assert_allowed_by_json
  grep -qF -- 'timed out' <<<"$output" && return 1
  [ $((SECONDS - start)) -lt 4 ]
}

@test "hop guard: a missing breadcrumb counts as not the owner" {
  hold_feature_with_pr 42
  run_hop 'git switch other' sid-owner
  assert_denied_by_json
}

@test "hop guard: a branch whose PR is merged or closed is allowed" {
  hold_feature_with_pr 42
  export GH_STUB=none
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
}

@test "hop guard: a gh failure fails open with one stderr line naming the cause" {
  hold_feature_with_pr 42
  export GH_STUB=fail
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'could not check' <<<"$output"
  grep -qF -- 'exited 4' <<<"$output"
}

@test "hop guard: a gh answer that is not a PR number fails open" {
  hold_feature_with_pr 42
  export GH_STUB=garbage
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'could not check' <<<"$output"
}

@test "hop guard: a gh call that never answers is cut off and fails open" {
  hold_feature_with_pr 42
  export GH_STUB=hang
  local start=$SECONDS
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'timed out' <<<"$output"
  [ $((SECONDS - start)) -lt 20 ]
}

# The bound killed the pid it backgrounded, but the output was read through the
# command substitution's pipe, which stays open until every process holding it
# exits. A `gh` that runs the real binary without `exec` leaves that child
# holding the pipe, so the bound did not hold and the diagnostic claimed one
# that had (#2004).
@test "hop guard: a gh wrapper that does not exec is still cut off at the bound" {
  hold_feature_with_pr 42
  export GH_STUB=hangwrap
  local start=$SECONDS
  run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'timed out' <<<"$output"
  [ $((SECONDS - start)) -lt 20 ]
}

@test "hop guard: gh missing from PATH fails open with the named cause" {
  hold_feature_with_pr 42
  # A PATH holding every tool the hook and its libraries call, and no gh.
  local tools="$BATS_TEST_TMPDIR/tools" tool src
  mkdir -p "$tools"
  for tool in bash cat jq git sed tr dirname basename find env mkdir grep head \
      wc date sleep rm shasum sha256sum perl awk; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -s "$src" "$tools/$tool"
  done
  PATH="$tools" run_hop 'git checkout main' sid-peer
  assert_allowed_by_json
  grep -qF -- 'gh is not on PATH' <<<"$output"
}

@test "hop guard: an unloadable breadcrumb library fails open with the named cause" {
  stage_hook_tree
  stub_gh
  export GH_STUB=open:42
  git -C "$STAGED_ROOT" branch --quiet other
  git -C "$STAGED_ROOT" checkout --quiet -B feature
  [ ! -e "$STAGED_ROOT/.gaia/scripts/gh-artifact-lib.sh" ]
  run_staged 'git switch other'
  assert_allowed_by_json
  grep -qF -- 'gh-artifact-lib.sh did not load' <<<"$output"
  # The lookup that failed is whose session opened the pull request, not whether
  # one is open: that answer is already in hand by the time this arm runs (#2007).
  grep -qF -- 'whether this session opened' <<<"$output"
}

# The guard's header promises a stderr line for anything it cannot check, and
# the arm taken when the main-root resolver is missing returned silently, so a
# peer's hop was allowed with no diagnostic anywhere (#2007).
@test "hop guard: an unloadable main-root-lib.sh fails open with the named cause" {
  stage_hook_tree
  stub_gh
  export GH_STUB=open:42
  rm -f "$STAGED_ROOT/.gaia/scripts/main-root-lib.sh"
  git -C "$STAGED_ROOT" branch --quiet other
  git -C "$STAGED_ROOT" checkout --quiet -B feature
  run_staged 'git switch other'
  assert_allowed_by_json
  grep -qF -- 'main-root-lib.sh did not load' <<<"$output"
}

# The switch arm returned before the no-op carve-out ever inspected the operand,
# so a switch to the branch HEAD already holds was denied although it moves
# nothing, which is the same no-op deny the carve-out repairs on the checkout
# arm. The session most likely to hit it is the branch's own owner after a
# restart, whose new session id no longer matches the breadcrumb (#2018).
@test "hop guard: a switch that moves nothing is allowed in a peer-held main checkout" {
  hold_feature_with_pr 42
  run_hop 'git switch feature' sid-peer
  assert_allowed_by_json
  # The controls: a switch that really moves HEAD is still denied, and so is
  # every branch-creating and detaching spelling the arm lists, each of which
  # moves HEAD whatever the operand says. Driven per spelling rather than
  # sampled, because this test is the arm's only coverage and a spelling
  # dropped from the case list is invisible to a suite that drives its siblings.
  run_hop 'git switch other' sid-peer
  assert_denied_by_json
  run_hop 'git switch -c brand-new' sid-peer
  assert_denied_by_json
  run_hop 'git switch -C feature' sid-peer
  assert_denied_by_json
  run_hop 'git switch --create brand-new' sid-peer
  assert_denied_by_json
  run_hop 'git switch --force-create feature' sid-peer
  assert_denied_by_json
  run_hop 'git switch --orphan o2' sid-peer
  assert_denied_by_json
  run_hop 'git switch --detach' sid-peer
  assert_denied_by_json
}

# A bare name resolves against refs/remotes/<name>, never
# refs/remotes/origin/<name>, so a branch that exists only on the remote fails
# the operand's commit-ish test and reads as moving nothing. `git switch` DWIMs
# that same name into a new tracking branch and moves HEAD, which is the hop the
# guard exists to refuse, and the fail-open diagnostic is never reached either
# (gaia-react/gaia#2018).
@test "hop guard: a switch to a remote-only branch is denied in a peer-held main checkout" {
  hold_feature_with_pr 42
  git -C "$REPO" update-ref refs/remotes/origin/remoteonly HEAD
  # The precondition the case turns on: the bare name does not resolve locally.
  [ -z "$(git -C "$REPO" rev-parse --verify -q remoteonly 2>/dev/null)" ] || return 1
  run_hop 'git switch remoteonly' sid-peer
  assert_denied_by_json
  # A name with no local and no remote counterpart takes the same path. Denying
  # it refuses a command git would reject anyway, which is the safe direction
  # for a guard whose escape is running it with the ! prefix.
  run_hop 'git switch nonexistent' sid-peer
  assert_denied_by_json
}

# A checkout naming the branch HEAD already holds, or HEAD itself, moves
# nothing, so denying it refuses a no-op (#2005).
@test "hop guard: a checkout that moves nothing is allowed in a peer-held main checkout" {
  hold_feature_with_pr 42
  run_hop 'git checkout feature' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout HEAD' sid-peer
  assert_allowed_by_json
  # The control: a checkout that really moves HEAD is still denied.
  run_hop 'git checkout other' sid-peer
  assert_denied_by_json
}

@test "hop guard: a checkout run inside a linked worktree is allowed" {
  hold_feature_with_pr 42
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$wt"
  run_hop 'git switch other' sid-peer "$wt"
  assert_allowed_by_json
}

@test "hop guard: path-restore forms are allowed" {
  hold_feature_with_pr 42
  run_hop 'git checkout -- README.md' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout main -- README.md' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout -p main' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout -- main' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout main README.md' sid-peer
  assert_allowed_by_json
  run_hop 'git checkout README.md' sid-peer
  assert_allowed_by_json
}

@test "hop guard: hopping off the default branch is allowed" {
  hold_feature_with_pr 42
  git -C "$REPO" checkout --quiet main
  run_hop 'git switch other' sid-peer
  assert_allowed_by_json
}

@test "hop guard: hopping off the default branch origin/HEAD names is allowed" {
  hold_feature_with_pr 42
  git -C "$REPO" checkout --quiet -B trunk
  git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  run_hop 'git switch other' sid-peer
  assert_allowed_by_json
}

@test "hop guard: hopping off a detached HEAD is allowed" {
  hold_feature_with_pr 42
  git -C "$REPO" checkout --quiet --detach
  run_hop 'git switch other' sid-peer
  assert_allowed_by_json
}

# The collapsed line re-emits the WHOLE command, so every intact git segment
# in a command that carries a `$( )` anywhere is walked twice, not only the
# segment the substitution sits in. Every other rule reaches the same verdict
# both times at no cost; the hop arm is the one that can spend a bounded
# pull-request lookup, so without the memo this command's worst-case wait
# doubles and the diagnostic prints twice.
#
# Pinned on the ALLOW path: a deny exits the hook on the first visit, so the
# second one can never be observed there.
@test "hop guard: a target beside a substitution is answered once, not twice" {
  hold_feature_with_pr 42
  export GH_STUB=fail
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  run_hop 'git checkout main && echo "$(date)"' sid-peer
  assert_allowed_by_json
  [ "$(grep -cF -- 'could not check' <<<"$output")" -eq 1 ]
}

# The memo above spans the lookup only. Whether a segment moves HEAD at all is
# a property of that segment's own operands, so a memo covering that question
# answers a later segment with an earlier one's verdict: a pathspec restore and
# a checkout of the branch HEAD already holds both leave HEAD where it is, and
# either one standing in for the branch switch beside it takes the guard off.
@test "hop guard: each checkout segment is judged on its own operands" {
  hold_feature_with_pr 42
  write_breadcrumb feature sid-owner
  run_hop 'git checkout -- README.md && git checkout main' sid-peer
  assert_denied_by_json
  run_hop 'git checkout feature && git checkout main' sid-peer
  assert_denied_by_json
}

# The collapsed line re-emits the whole command, its own `cd` segments
# included, so the walk has to enter it with no tracked directory standing.
# Reading it under the directory the FIRST pass ended in puts a `cd` that
# follows a git segment in front of it on the second pass, and the commit is
# then read against a checkout the command reaches only afterwards.
@test "the collapsed re-emission is not governed by a cd that follows the segment it re-reads" {
  on_feature
  local wt="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet "$wt" main
  run_hook_from "git commit -m \"\$(date)\" && cd '$wt'" "$REPO"
  assert_allowed_by_json
}

# --- command-word derivation: prefixes that hid `git` from the segment walk ---

# `NAME+=value` is a command prefix the shell accepts exactly as `NAME=value`
# (`bash -c 'zz+=1 env'` prints `zz=1`), so a strip reading only the `=`
# spelling leaves the command word unexposed and the whole segment unread.
@test "a NAME+=value prefix does not hide the git command word" {
  on_main
  run_hook 'zz+=1 git commit -m x'
  assert_denied_by_json
  run_hook '(name+=v git commit -m x)'
  assert_denied_by_json
  run_hook 'zz+=1 git push'
  assert_denied_by_json
  run_hook 'a=1 b+=2 git commit -m x'
  assert_denied_by_json
}

# A reserved word or grouping token stands in command position with no
# `| & ; ( )` between it and the command word, so the segment reaches the walk
# with the reserved word read as its command.
@test "a reserved word or grouping token does not hide the git command word" {
  on_main
  run_hook 'if true; then git commit -m y; fi'
  assert_denied_by_json
  run_hook '{ git commit -m y; }'
  assert_denied_by_json
  run_hook '! git commit -m y'
  assert_denied_by_json
  run_hook 'time git commit -m y'
  assert_denied_by_json
  run_hook 'time -p git commit -m y'
  assert_denied_by_json
  run_hook 'coproc git commit -m y'
  assert_denied_by_json
  run_hook 'for f in x; do git commit -m y; done'
  assert_denied_by_json
  run_hook 'while :; do git push; done'
  assert_denied_by_json
  run_hook 'until git push; do echo retry; done'
  assert_denied_by_json
  run_hook 'if false; then echo no; else git commit -m y; fi'
  assert_denied_by_json
}

# A word merely beginning with a reserved word is an ordinary command name, so
# the strip requires the whitespace that makes the reserved word a word.
@test "a command name beginning with a reserved word is left alone" {
  on_main
  run_hook 'iffy git commit -m y'
  assert_allowed_by_json
  run_hook 'dotimes git commit -m y'
  assert_allowed_by_json
  run_hook 'coprocess git commit -m y'
  assert_allowed_by_json
}

# An assignment's value may be quoted and carry whitespace, which the shell
# accepts as an ordinary command prefix. A value read as an unquoted run stops
# at the opening quote, leaving the rest of the value standing where the
# command word is read.
@test "a quoted env-assignment value does not hide the git command word" {
  on_main
  run_hook 'GIT_EDITOR="code --wait" git commit -m x'
  assert_denied_by_json
  run_hook 'GIT_AUTHOR_DATE="2024-01-01 12:00" git commit --amend'
  assert_denied_by_json
  run_hook "GIT_AUTHOR_DATE='2024-01-01 12:00' git push"
  assert_denied_by_json
}

# A redirection may lead a simple command, so one written ahead of the
# invocation occupies the slot the command word is read from and the segment
# goes unread.
#
# Deliberately not a member: a redirection whose target is another descriptor
# (`2>&1`, `>&2`). The walk cuts segments at `&` before the strip sees them, so
# that form never reaches the expression under test; the hook's own second
# honest limit states it.
@test "a leading redirection does not hide the git command word" {
  on_main
  run_hook '>/tmp/gaia-probe git commit -m x'
  assert_denied_by_json
  run_hook '2>/dev/null git commit -m x'
  assert_denied_by_json
  run_hook '>>/tmp/gaia-probe git push'
  assert_denied_by_json
}

# A `$( )` inside git's OWN arguments cuts the segment at its parens, so no one
# segment carries both the command word and the subcommand the rules arm on.
#
# A `-C` whose value is a substitution is asserted by the branch read's own
# fail-closed case rather than here: an unresolvable directory word falls back
# to the checkout the command runs in, so the rules stay armed. This test pins
# the narrower claim that the walk reads the subcommand past a substitution
# standing in git's other arguments.
@test "a command substitution inside git's arguments does not hide the subcommand" {
  on_main
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  run_hook 'git -c user.name="$(whoami)" commit -m y'
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook 'git commit -m "$(date)"'
  assert_denied_by_json
  on_feature
  # shellcheck disable=SC2016
  run_hook 'git push "$(echo origin)" main'
  assert_denied_by_json
}

# The collapse must not hand a non-git segment the substitution's own text: the
# body still reaches the walk as its own segment, which is where a command
# inside one is read.
@test "text inside a collapsed substitution does not arm the outer segment" {
  on_feature
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  run_hook 'echo "$(git log)" main'
  assert_allowed_by_json
  # shellcheck disable=SC2016
  run_hook 'grep -R "$(echo commit)" .'
  assert_allowed_by_json
}
