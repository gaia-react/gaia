#!/usr/bin/env bats

# Tests for .claude/hooks/block-no-verify.sh.
#
# The hook denies `git commit` / `git push` carrying a hook bypass so the
# Quality Gate floor (typecheck / lint / test, run by the Husky pre-commit
# hook) cannot be skipped. Bypass tokens: --no-verify, `-n` (commit only
# `push -n` is --dry-run), a falsy HUSKY= env prefix, and a `-c
# core.hooksPath=` override. Foreign-repo commands pass via the shared
# repo-scope helper.
#
# Most tests drive the hook exactly as the harness does: a PreToolUse JSON
# payload on stdin, run with the tmp repo as the working directory, which is
# where the shared repo-scope helper resolves the home repository's identity
# from: it reads the toplevel and the remote URLs of whatever repo cwd sits in.
# The hook loads that helper from its own on-disk location rather than from cwd,
# so the degrade cases at the end run a copy of the hook from a staged tree
# instead, with that tree as the working directory, which is what puts a library
# the test controls in front of it. The hook always exits 0; allow vs deny is
# carried in stdout: a deny emits `"permissionDecision": "deny"`, an allow emits
# nothing. The deny cases double as a jq/setup canary: a missing jq would exit
# early with no output and those assertions would fail rather than false-pass.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SRC=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABS="$HOOKS_SRC/block-no-verify.sh"

  REPO=$(mktemp -d -t no-verify-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
  git -C "$REPO" checkout --quiet -b feature

  # A second, distinct repo for the foreign-repo case.
  FOREIGN=$(mktemp -d -t no-verify-foreign-XXXXXX)
  git -C "$FOREIGN" init --quiet --initial-branch=main
  git -C "$FOREIGN" config user.email "test@example.com"
  git -C "$FOREIGN" config user.name "Test"
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  [ -n "${FOREIGN:-}" ] && rm -rf "$FOREIGN" || true
  return 0
}

# Run the hook with a given command, from inside the home repo.
run_hook() {
  local cmd="$1"
  local json
  json=$(jq -n --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABS"
}



# --- denied ---

@test "git commit --no-verify is denied" {
  run_hook 'git commit --no-verify -m "x"'
  assert_denied_by_json
}

# A `-R` belonging to another program in the same tool call was read as gh's
# repository flag, so the shared repo-scope helper answered "foreign" and this
# guard skipped its bypass rule for the whole command (#2011). The remote is
# required: with none, the helper has no repository name to compare and fails
# closed a line earlier, which would pass this test without exercising it.
@test "a trailing program's -R does not exempt a --no-verify commit" {
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  run_hook 'git commit --no-verify -m x && grep -R app/routes .'
  assert_denied_by_json
}

# The repo-scope verdict covers the whole tool call, so any home command in it
# keeps the guard armed: a foreign command before or after a --no-verify commit
# does not exempt it (gaia-react/gaia#2081).
@test "a foreign command in the same call does not exempt a --no-verify commit" {
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  run_hook 'gh pr merge 5 -R other/x && git commit --no-verify -m y'
  assert_denied_by_json
  run_hook 'gh pr merge 5 -R other/x; git commit --no-verify -m y'
  assert_denied_by_json
  run_hook "gh pr merge 5 -R other/x
git commit --no-verify -m y"
  assert_denied_by_json
  run_hook "git commit --no-verify -m y && git -C $FOREIGN status"
  assert_denied_by_json
  run_hook "cd $FOREIGN && git status && cd - && git commit --no-verify -m y"
  assert_denied_by_json
}

# A substitution in a foreign command's own arguments runs in this repository
# before the foreign command does (gaia-react/gaia#2148).
@test "a --no-verify commit inside a substitution in a foreign command's arguments is denied" {
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  run_hook 'gh pr view 5 -R other/x --jq "$(git commit --no-verify -m y)"'
  assert_denied_by_json
  run_hook "git -C $FOREIGN log --format \"\$(git commit --no-verify -m y)\""
  assert_denied_by_json
}

@test "a call whose every command is foreign still passes a --no-verify commit" {
  git -C "$REPO" remote add origin https://github.com/acme/widget.git
  run_hook "gh pr merge 5 -R other/x && git -C $FOREIGN commit --no-verify -m y"
  assert_allowed_by_json
}

@test "git commit -n is denied" {
  run_hook 'git commit -n -m "x"'
  assert_denied_by_json
}

@test "git commit with bundled short flags -anm is denied" {
  run_hook 'git commit -anm "x"'
  assert_denied_by_json
}

@test "HUSKY=0 git commit is denied" {
  run_hook 'HUSKY=0 git commit -m "x"'
  assert_denied_by_json
}

@test "git -c core.hooksPath=/dev/null commit is denied" {
  run_hook 'git -c core.hooksPath=/dev/null commit -m "x"'
  assert_denied_by_json
}

@test "git push --no-verify is denied" {
  run_hook 'git push --no-verify'
  assert_denied_by_json
}

@test "HUSKY=0 git push is denied" {
  run_hook 'HUSKY=0 git push origin feature'
  assert_denied_by_json
}

# --- allowed ---

@test "plain git commit on a feature branch is allowed" {
  run_hook 'git commit -m "x"'
  assert_allowed_by_json
}

@test "git push -n (dry-run) is allowed" {
  run_hook 'git push -n origin feature'
  assert_allowed_by_json
}

@test "git push --dry-run is allowed" {
  run_hook 'git push --dry-run origin feature'
  assert_allowed_by_json
}

@test "plain git push on a feature branch is allowed" {
  run_hook 'git push origin feature'
  assert_allowed_by_json
}

@test "HUSKY=1 git commit is allowed (enabling is not a bypass)" {
  run_hook 'HUSKY=1 git commit -m "x"'
  assert_allowed_by_json
}

@test "home-repo git -C commit (no bypass) is allowed" {
  # Capital -C changes directory; it is not a bypass. The home repo's own
  # `git -C <home> commit` must pass; only lowercase `-c core.hooksPath=`
  # (the next test) carries a bypass.
  run_hook "git -C $REPO commit -m \"x\""
  assert_allowed_by_json
}

@test "foreign-repo commit with a bypass is allowed (out of scope)" {
  run_hook "git -C $FOREIGN commit --no-verify -m \"x\""
  assert_allowed_by_json
}

@test "a non-commit/push git command with a hooksPath override is ignored" {
  run_hook 'git -c core.hooksPath=/dev/null status'
  assert_allowed_by_json
}

@test "a non-git command is ignored" {
  run_hook 'pnpm run build'
  assert_allowed_by_json
}

# --- command-position anchoring: the words appear, but git is not the program ---

@test "grep with -n searching for the text 'git commit' is allowed" {
  # The reported false positive: -n belongs to grep, 'git commit' is the search
  # pattern. git is not in command position, so nothing fires.
  run_hook 'grep -n -e git commit app/foo.ts'
  assert_allowed_by_json
}

@test "echo of 'git commit' piped to grep -n is allowed" {
  run_hook 'echo git commit && grep -n foo bar'
  assert_allowed_by_json
}

@test "real git commit followed by grep -n is allowed (-n is grep's)" {
  # -n is scoped to the git segment; the grep on the other side of && is inert.
  run_hook 'git commit -m "x" && grep -n foo bar'
  assert_allowed_by_json
}

@test "tail -n over a file path containing 'commit' is allowed" {
  run_hook 'tail -n 5 git-commit-notes.txt'
  assert_allowed_by_json
}

# --- command-position anchoring still catches real bypasses ---

@test "git commit -n after an unrelated piped command is denied" {
  run_hook 'echo hi | git commit -n -m "x"'
  assert_denied_by_json
}

@test "bypass orphaned by a pipe inside the commit message is still denied" {
  # Segment-splitting on the quoted '|' would orphan --no-verify from its git
  # segment; the whole-command safety net re-asserts it.
  run_hook 'git commit -m "a|b" --no-verify'
  assert_denied_by_json
}

# --- deny message names the documented over-block case ---

@test "deny message names the commit-message over-block workaround" {
  # A bypass token merely mentioned inside a commit message (never a real
  # bypass attempt) still denies, by design (see the hook's header comment).
  # Drive the actual over-block case (--no-verify inside the -m text, not in
  # flag position) so this test pins the message that case actually gets,
  # not the message a real bypass gets from an identical-looking command.
  run_hook 'git commit -m "use --no-verify next time"'
  assert_denied_by_json
  grep -qF -- "documented over-block" <<<"$output" || return 1
}

@test "deny message on push omits the commit-message workaround (push has no -m)" {
  # floor_msg is shared by commit and push; the over-block note only applies
  # to commit, since push carries no message text a token could be mentioned
  # inside.
  run_hook 'git push --no-verify'
  assert_denied_by_json
  grep -qF -- "documented over-block" <<<"$output" && return 1
  return 0
}

# --- the staged-tree harness the degrade cases below share ---
#
# The repo-scope load resolves off BASH_SOURCE, never off the process working
# directory, so expressing a degraded library needs a COPY of the hook in a tree
# the test controls: running the real $HOOK_ABS leaves it resolving the real
# checkout's library beside itself, whatever a fixture does to a copy anywhere
# else.

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_lib() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

stage_hook_tree() {
  STAGED_ROOT="$BATS_TEST_TMPDIR/staged"
  rm -rf "$STAGED_ROOT"
  mkdir -p "$STAGED_ROOT/.claude"
  # The whole hooks directory, lib/ included, rather than the libraries this
  # hook happens to load today: an enumeration goes short the moment the hook
  # gains a load, and the cases below would then drive a hook degraded in a way
  # none of them names while still reporting green. Each case removes or
  # corrupts only the library it is named for. Staging the directory wholesale
  # also keeps the jq-availability arm present, which runs ahead of the load
  # under test and refuses when it cannot find its own library, answering every
  # case with that refusal instead of with the decision under test.
  cp -R "$HOOKS_SRC" "$STAGED_ROOT/.claude/hooks"
  STAGED_HOOK="$STAGED_ROOT/.claude/hooks/block-no-verify.sh"
}

# Run the staged copy of the hook, from inside the staged tree.
run_staged() {
  local json
  json=$(jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}')
  invoke_hook_in "$STAGED_ROOT" "$json" "$STAGED_HOOK"
}

# --- a degraded repo-scope.sh degrades the hook, it does not deny ---
#
# The repo-scope load sits under this hook's `set -euo pipefail`, so without the
# bracket suspending errexit an unparseable copy abandons the shell ahead of the
# `type cmd_targets_foreign_repo` check on the next line. That exits 2, the
# PreToolUse deny code, refusing every git command the hook matches -- including
# the very edit that would repair the library. Unlike the verb-arming sites,
# this one denies on bash 5 as well as on 3.2, so neither conflict-marker case
# needs a /bin/bash pin to have teeth.
#
# Each pair is what discriminates. The allow case alone is satisfied by a hook
# that stopped enforcing entirely, so the deny twin proves the degrade kept the
# floor: without cmd_targets_foreign_repo the foreign-repo carve-out simply does
# not fire, which is the fail-closed direction the hook's own repo-scope comment
# documents.
#
# The absent-library case pins those same two directions against a different
# trigger, and an unbracketed load alone is not a probe that can red it: with
# the library missing, the `[ -f ]` guard ahead of the source short-circuits,
# and errexit exempts a non-final command in an `&&` list, so that path never
# reaches the source the bracket protects. Dropping that guard along with the
# bracket is what reds it, and the shape of that failure differs from the
# conflict-marker pair above: the shell is abandoned on a status PreToolUse does
# not read as a deny, so the hook returns no verdict at all rather than a
# refusal, and both halves of the pair red on the missing verdict.

@test "repo-scope.sh holding conflict markers: an ordinary git command is still allowed" {
  stage_hook_tree
  write_conflicted_lib "$STAGED_ROOT/.claude/hooks/lib/repo-scope.sh"
  run_staged 'git status'
  assert_allowed_by_json
}

@test "repo-scope.sh holding conflict markers: a --no-verify commit is still denied" {
  stage_hook_tree
  write_conflicted_lib "$STAGED_ROOT/.claude/hooks/lib/repo-scope.sh"
  run_staged 'git commit --no-verify -m x'
  assert_denied_by_json
}

@test "repo-scope.sh absent entirely: an ordinary git command is still allowed" {
  stage_hook_tree
  rm -f "$STAGED_ROOT/.claude/hooks/lib/repo-scope.sh"
  run_staged 'git status'
  assert_allowed_by_json
}

@test "repo-scope.sh absent entirely: a --no-verify commit is still denied" {
  stage_hook_tree
  rm -f "$STAGED_ROOT/.claude/hooks/lib/repo-scope.sh"
  run_staged 'git commit --no-verify -m x'
  assert_denied_by_json
}

# --- command-word derivation: prefixes that hid `git` from the segment walk ---

# `NAME+=value` is a command prefix the shell accepts exactly as `NAME=value`
# (`bash -c 'zz+=1 env'` prints `zz=1`), so a strip reading only the `=`
# spelling leaves the command word unexposed and the whole segment unread.
@test "a NAME+=value prefix does not hide the git command word" {
  run_hook 'zz+=1 git commit -n -m x'
  assert_denied_by_json
  run_hook '(name+=v git commit -n -m x)'
  assert_denied_by_json
  run_hook 'zz+=1 git push --no-verify'
  assert_denied_by_json
  run_hook 'a=1 b+=2 git commit --no-verify -m x'
  assert_denied_by_json
}

# `HUSKY+=0` disables Husky whenever HUSKY is unset, which is the ordinary
# case, so the bypass-token test reads both spellings the command-word strip
# above does rather than closing one half of the same shape.
@test "a falsy HUSKY+= prefix is denied" {
  run_hook 'HUSKY+=0 git commit -m x'
  assert_denied_by_json
  run_hook 'HUSKY+= git push'
  assert_denied_by_json
}

# A reserved word or grouping token stands in command position with no
# `| & ; ( )` between it and the command word, so the segment reaches the walk
# with the reserved word read as its command.
#
# The set is hand-written, because bash's reserved words are not derivable from
# anything in this repository, so it carries its non-members with reasons
# (`.claude/rules/bats-assertions.md`). Every reserved word that can stand
# immediately before a command is driven below. Deliberately not members, each
# because it precedes something other than a command, so the command word is
# not the next token and no segment of theirs reaches the walk unread:
# `function` and `for` and `select` precede a NAME, `case` precedes a WORD,
# `[[` precedes a conditional expression, and `in`, `esac`, `fi`, `done`, `}`
# and `]]` close a construct rather than opening one.
# A command WRAPPER (`env`, `command`, `timeout`) is not a reserved word and is
# not a member either; the derivation's own comment states that limit.
@test "a reserved word or grouping token does not hide the git command word" {
  run_hook 'if true; then git commit -n -m y; fi'
  assert_denied_by_json
  run_hook '{ git commit -n -m y; }'
  assert_denied_by_json
  run_hook '! git commit -n -m y'
  assert_denied_by_json
  run_hook 'time git commit -n -m y'
  assert_denied_by_json
  run_hook 'time -p git commit -n -m y'
  assert_denied_by_json
  run_hook 'time -- git commit -n -m y'
  assert_denied_by_json
  run_hook 'coproc git commit -n -m y'
  assert_denied_by_json
  run_hook 'for f in x; do git commit -n -m y; done'
  assert_denied_by_json
  run_hook 'while :; do git push --no-verify; done'
  assert_denied_by_json
  run_hook 'if git commit -n -m y; then echo ok; fi'
  assert_denied_by_json
  run_hook 'until git push --no-verify; do echo retry; done'
  assert_denied_by_json
  run_hook 'if false; then echo no; else git commit -n -m y; fi'
  assert_denied_by_json
  run_hook 'if false; then echo no; elif git commit -n -m y; then echo ok; fi'
  assert_denied_by_json
}

# An assignment's value may be quoted and carry whitespace, which the shell
# accepts as an ordinary command prefix. A value read as an unquoted run stops
# at the opening quote, leaving the rest of the value standing where the
# command word is read.
@test "a quoted env-assignment value does not hide the git command word" {
  run_hook 'GIT_EDITOR="code --wait" git commit --no-verify -m x'
  assert_denied_by_json
  run_hook 'GIT_AUTHOR_DATE="2024-01-01 12:00" git commit -n -m x'
  assert_denied_by_json
  run_hook "GIT_AUTHOR_DATE='2024-01-01 12:00' git commit -n -m x"
  assert_denied_by_json
  run_hook 'GIT_EDITOR="code --wait" git push --no-verify'
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
  run_hook '>/tmp/gaia-probe git commit --no-verify -m x'
  assert_denied_by_json
  run_hook '2>/dev/null git commit -n -m x'
  assert_denied_by_json
  run_hook '>>/tmp/gaia-probe git push --no-verify'
  assert_denied_by_json
}

# A word merely beginning with a reserved word is an ordinary command name, so
# the strip requires the whitespace that makes the reserved word a word.
@test "a command name beginning with a reserved word is left alone" {
  run_hook 'iffy git commit -n -m y'
  assert_allowed_by_json
  run_hook 'dotimes git commit -n -m y'
  assert_allowed_by_json
}

# A `$( )` inside git's OWN arguments cuts the segment at its parens, so no one
# segment carries both the command word and the bypass flag.
@test "a command substitution inside git's arguments does not orphan the flag" {
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  run_hook 'git commit -m "$(cat f)" -n'
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook 'git commit -m "$(cat f)" --no-verify'
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook 'git -C "$(pwd)" commit -n -m y'
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook 'git -C "$(pwd)" commit -m "$(cat f)" --no-verify'
  assert_denied_by_json
  # shellcheck disable=SC2016
  run_hook 'git commit -m "$(echo "$(date)")" -n'
  assert_denied_by_json
}

# Collapsing the span must not put the substitution's own text back in the
# reader's way: a word produced INSIDE one is not the outer segment's
# subcommand, and the body still reaches the walk as its own segment.
@test "text inside a collapsed substitution does not arm the outer segment" {
  # shellcheck disable=SC2016 # the hook must receive the unexpanded opener
  run_hook 'git log $(echo commit) -n 1'
  assert_allowed_by_json
  # shellcheck disable=SC2016
  run_hook 'echo "$(git log)" --no-verify'
  assert_allowed_by_json
}

# block-no-verify.sh and block-main-destructive-git.sh each derive a segment's
# command word with their own copy of one expression, so a widening applied to
# one and not the other reopens the gap in whichever copy was missed. Pinned on
# the construct, not only on sameness: a copy that agrees with the other at the
# narrow spelling fails here too.
@test "block-no-verify.sh and block-main-destructive-git.sh derive the segment command word the same way" {
  local expected="" f line n
  for f in block-no-verify.sh block-main-destructive-git.sh; do
    # shellcheck disable=SC2016 # the needle is the hooks' literal source text
    n=$(grep -cF 'seg_cmd=$(printf' "$HOOKS_SRC/$f")
    [ "$n" -eq 1 ]
    # shellcheck disable=SC2016
    line=$(grep -F 'seg_cmd=$(printf' "$HOOKS_SRC/$f" | sed -E 's/^[[:space:]]*//')
    if [ -z "$expected" ]; then expected="$line"; fi
    [ "$line" = "$expected" ]
  done
  grep -qF '+?=' <<<"$expected"
  grep -qE '\bthen\b' <<<"$expected"
  true
}

# GAIA's own wiki squash writes a `--no-verify` commit whose message carries a
# `$( )`, the exact shape the collapse above rejoins, so it is the one in-repo
# case where widening the walk could have denied GAIA's own automation. It does
# not: the whole-command safety net already denies this line on the `--no-verify`
# alone, with or without the collapse, so the widening changes nothing for it.
# What makes that harmless is the second pin below: the script reaches the shell
# through the hook runner, where no PreToolUse Bash guard reads it. Both halves
# are pinned so that routing it through a Bash tool call reds here rather than
# silently denying the auto-commit chain.
@test "the wiki squash's own no-verify commit is denied through the Bash tool" {
  local line
  line=$(grep -F -- '--no-verify' "$HOOKS_SRC/wiki-squash-autocommits.sh" \
         | grep -F 'commit -m' | sed -E 's/^[[:space:]]*//; s/[[:space:]]*>.*$//')
  [ -n "$line" ]
  # shellcheck disable=SC2016 # the needle is the substitution opener itself
  grep -qF '$(' <<<"$line"
  run_hook "$line"
  assert_denied_by_json
}

# The route that matters is an instruction surface an agent reads and then
# types into the Bash tool. `.claude/hooks` and `.gaia/scripts` are
# deliberately absent: a script that runs the hook internally is not a route,
# because the guard reads the command the agent typed rather than what that
# command's script does once it is running.
#
# Two searches, because the two surfaces mention the script for different
# reasons. On the instruction surfaces any mention at all is a candidate route,
# so the search is the plain filename. `wiki/` pages are read and acted on too,
# but they also describe the hook by name in prose, so the search there is the
# repo-relative PATH: a page that writes the runnable path is handing an agent
# something to type, where a page naming the file is not. `wiki/meta/` holds
# audit reports, which quote paths by construction and are never executed.
#
# The directory list is hand-written, so each entry is asserted to exist before
# it is searched: a renamed or removed directory would otherwise drop out of
# the scanned set while the search still reported clean.
@test "the wiki squash script is reached only through its hook registration" {
  local root hits d
  root=$(cd "$HOOKS_SRC/../.." && pwd)
  grep -qF 'wiki-squash-autocommits.sh' "$root/.claude/settings.json"

  set -- "$root/.claude/skills" "$root/.claude/commands" "$root/.claude/rules" \
         "$root/.claude/agents" "$root/.claude/instructions" \
         "$root/.specify/extensions/gaia/commands" "$root/.specify/extensions/gaia/rules"
  for d in "$@"; do [ -d "$d" ]; done
  hits=$(grep -rlF 'wiki-squash-autocommits.sh' "$@" 2>/dev/null || true)
  [ -z "$hits" ]

  [ -d "$root/wiki" ]
  hits=$(grep -rlF --exclude-dir=meta '.claude/hooks/wiki-squash-autocommits.sh' \
           "$root/wiki" 2>/dev/null || true)
  [ -z "$hits" ]
}

# The substitution collapse is the second derivation those two copies share.
# This pin holds SAMENESS only, unlike the command-word pin above: a weakening
# applied uniformly to both copies leaves it green. What carries the construct
# is the behavioural pair in each suite, the orphaned-flag test and the
# collapsed-substitution control, which red when the collapse stops rejoining
# or starts over-arming.
@test "block-no-verify.sh and block-main-destructive-git.sh collapse command substitutions the same way" {
  local expected="" f body
  for f in block-no-verify.sh block-main-destructive-git.sh; do
    body=$(sed -n '/^collapsed_substitutions() {$/,/^}$/p' "$HOOKS_SRC/$f")
    [ -n "$body" ]
    if [ -z "$expected" ]; then expected="$body"; fi
    [ "$body" = "$expected" ]
  done
  true
}

