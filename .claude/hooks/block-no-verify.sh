#!/usr/bin/env bash
# PreToolUse Bash hook: deny `git commit` / `git push` that carry a hook
# bypass, so GAIA's commit-time deterministic floor (typecheck / lint / test,
# run by the Husky pre-commit hook) cannot be silently skipped.
#
# "Enforced, not advisory" applies to GAIA's own gate: a floor the agent can
# opt out of is advisory. This closes the commit/push layer. The apex merge
# gate (pr-merge-audit-check.sh) already holds and is untouched.
#
# Bypass tokens denied (on commit OR push, unless noted):
#   --no-verify                     skips client-side hooks
#   -n                              COMMIT ONLY (= --no-verify). On `push`, -n
#                                   means --dry-run and is harmless, never block it.
#   HUSKY=0 (or falsy HUSKY= prefix) disables Husky for the invocation
#   -c core.hooksPath=<path>        redirects hooks to a path with no floor
#
# Command-position anchoring: a token is only a bypass when it belongs to a
# real `git commit` / `git push` INVOCATION, i.e. `git` is the command word of
# a pipeline segment (start of command, after a `| & ; ( )` separator, or after
# an env-var prefix like `HUSKY=0`). Command TEXT that merely mentions the words
# (a grep pattern, an echo string, a path, an argument to another program such
# as `grep -n -e git commit file`) is not an invocation and never fires. Without
# this anchor the matcher fired on free-floating substrings: any command whose
# text contained `commit` plus a `-n` flag tripped, even when `git` was not the
# program being run.
#
# No carve-out is needed for GAIA's own legitimate --no-verify automation
# (audit-stamp trailer, wiki autocommit squash): those run as hook scripts
# (Stop / PreToolUse), not as Bash-tool calls, so a PreToolUse Bash hook never
# intercepts them. Do not "fix" the missing carve-out, there is no bug.
#
# Residual fail-closed edge: a bypass token written literally INSIDE a commit
# message (e.g. `git commit -m "use --no-verify"`) still over-blocks. That is
# the safe direction; rephrase the message. The unambiguous tokens
# (--no-verify, falsy HUSKY=, core.hooksPath=) also get a whole-command
# fail-closed safety net so segment-splitting on a shell metacharacter inside a
# message can never let a real bypass slip. Policy: wiki/decisions/Quality Gate.md
set -euo pipefail

payload=$(cat)
# jq-availability arm: refuse loudly rather than fail open when the interpreter
# this hook reads its payload with is absent. What that buys, and the contract
# the literals below satisfy, live in .claude/hooks/lib/jq-availability.sh.
_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-no-verify.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the commit-floor bypass guard' "$payload" tool_input 'git'

cmd=$(echo "$payload" | jq -r '.tool_input.command // empty')

# Only act on git commands, short-circuit everything else. (Fast path only;
# correctness comes from the command-position scan below.) Any non-word
# character may stand before `git`, since a zsh glob qualifier puts a quote or
# its own delimiter there.
[[ "$cmd" =~ (^|[^[:alnum:]_])git([[:space:]]|$) ]] || exit 0

# Repo-scope: this repo's commit-floor policy governs this repo only. A git
# command aimed at a different repo (e.g. `git -C ../other commit --no-verify`)
# is out of scope, allow it. Fail-closed: any ambiguity falls through and the
# policy still enforces. Mirrors block-main-destructive-git.sh.
#
# Bracketed in `set +e` because errexit is armed above. An unparseable copy (an
# unresolved merge conflict, a truncated write) would otherwise abandon the shell
# before the `type` check below can degrade, and that exit is 2 -- the deny code --
# refusing every matching call including the edit that would repair the library.
# Suspending errexit for the one command lets the `type` check do the degrading, at
# no fork and at any source depth. `bash -n` cannot: it does not recurse.
#
# Rooted at this file's own on-disk location, never at the process working
# directory: a bare test is false from anywhere below the repository root, and
# the `type` degrade below reads that as a missing library. Resolved through the
# ancestor rather than a lib child, for the reason
# block-main-destructive-git.sh states at the same load: the ancestor cannot
# fail, so no degrade branch is owed, and a missing carve-out here is a silent
# fail-open rather than a deny.
_hook_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)" || _hook_root=''
_scope_lib="$_hook_root/.claude/hooks/lib/repo-scope.sh"
set +e; [ -n "$_hook_root" ] && [ -f "$_scope_lib" ] && . "$_scope_lib" 2>/dev/null; set -e
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

floor_msg() {
  local msg="Hook bypass on 'git $sub' is forbidden ($1). The Quality Gate floor (typecheck/lint/test) runs via the Husky pre-commit hook, fix the failures, don't skip the gate. See wiki/decisions/Quality Gate.md."
  # The over-block workaround applies to commit only: push carries no -m text
  # a bypass token could be merely mentioned inside.
  if [ "$sub" = "commit" ]; then
    msg="$msg If this token appears only inside your commit message text, not as a real flag, that is this hook's documented over-block: rephrase the message, the gate was not bypassed. A shell reserved word inside that quoted text ('then', 'do', 'if', an open brace) can put the words after it in command position for this check, so quoted prose describing a bypass reaches the over-block more readily than the flag alone would."
  fi
  echo "$msg"
}

# hidden_bodies <text>: print, one per line, the body of every construct that
# runs a command in the current shell with no `| & ; ( )` cut in front of it:
# bash 5.3's `${ cmd; }` function substitution, and a zsh glob qualifier's
# `e<delim>code<delim>` or `+cmd` (optionally behind `#q` or other qualifier
# flags). The walk below reads these lines AFTER the command's own lines,
# which it reads byte for byte as before, so this can only add segments and
# never hides one: a spurious match (an `e_` inside `(file_1=a git …)`) adds a
# harmless extra line while the real segment stays intact. A spurious body
# that happens to begin with `git commit` inside quoted text over-blocks, the
# safe direction. Each pass re-reads the bodies the last one found, so nested
# funsubs surface; bodies only shrink, and the pass bound is a backstop.
# block-main-destructive-git.sh carries the same function, and
# block-no-verify.bats pins the two copies identical.
hidden_bodies() {
  local text="$1" pass=0
  # shellcheck disable=SC2016 # a literal opener matched in the text, not an expansion
  case "$text" in *'${'* | *'('*) ;; *) return 0 ;; esac
  while [ -n "$text" ] && [ "$pass" -lt 8 ]; do
    text=$(printf '%s\n' "$text" \
      | { grep -oE '\$\{[[:space:]]+[^;|&()]*|\([^()[:space:]]*(e[^[:alnum:][:space:]]|\+)[^;|&()]*' || true; } \
      | sed -E -e 's/^\$\{[[:space:]]+//' \
          -e 's/^\([^()[:space:]]*(e[^[:alnum:][:space:]]|\+)//' \
          -e 's/^["'"'"']//' \
          -e 's/["'"'"']?[^[:alnum:][:space:]]?$//')
    [ -n "$text" ] && printf '%s\n' "$text"
    pass=$((pass + 1))
  done
  return 0
}

# collapsed_substitutions <text>: print the command once more with every
# `$( … )` span replaced by a single placeholder word, and print nothing when
# the text carries none or the collapse changes nothing. Cutting at every `(`
# and `)` is what lets the walk read a command INSIDE a substitution, and is
# also what splits a substitution standing in git's OWN arguments away from the
# command word: `git -C "$(pwd)" commit --no-verify` leaves no segment carrying
# both `git` and `commit`, and `git commit -m "$(cat f)" -n` orphans the `-n`.
# This line is read IN ADDITION to the command's own, so the body still reaches
# the walk as its own segment and only the outer invocation is rejoined. The
# placeholder is a bare `_` so a `commit`, a `push`, or a flag written inside
# the span cannot arm the rejoined segment with something it never spelled.
#
# Innermost first, so a nested span collapses over successive passes; the bound
# is a backstop. A span crossing a newline is left alone, since sed reads a
# line at a time: that leaves the segment cut where it already was, which is
# the direction that hides nothing the walk reads today.
# block-main-destructive-git.sh and red-verify-commit-check.sh carry the same
# function, and block-no-verify.bats pins the copies identical.
collapsed_substitutions() {
  local text="$1" prev pass=0
  # shellcheck disable=SC2016 # a literal opener matched in the text, not an expansion
  case "$text" in *'$('*) ;; *) return 0 ;; esac
  while [ "$pass" -lt 8 ]; do
    prev="$text"
    text=$(printf '%s' "$text" | sed -E 's/\$\([^()]*\)/_/g')
    [ "$text" = "$prev" ] && break
    pass=$((pass + 1))
  done
  [ "$text" = "$1" ] || printf '%s\n' "$text"
  return 0
}

# Walk each command-position segment. Separators (`| & ; ( )`, newlines) become
# line breaks so every line begins at a command word; leading env-var
# assignments and shell reserved words are stripped to expose it. A segment
# acts only when its command word is `git` and it carries a `commit` / `push`
# subcommand token, so a `-n` that belongs to a different program on the same
# command line (the `git commit && grep -n …` case) never trips the commit
# branch.
saw_commit=0
saw_push=0
while IFS= read -r seg; do
  # Command word = the first token past any leading whitespace, env-var
  # assignment prefix, or shell reserved word. Three things the shell accepts
  # in that run, each of which hid the whole invocation from a narrower
  # reading: `NAME+=value` is a command prefix exactly as `NAME=value` is
  # (`bash -c 'zz+=1 env'` prints `zz=1`); an assignment's value may be quoted
  # and carry whitespace (`GIT_AUTHOR_DATE="2024-01-01 12:00" git commit`), so
  # a value read as an unquoted run stops at the opening quote; and a reserved
  # word or grouping token stands in command position with no `| & ; ( )` ahead
  # of the command word for the walk to cut at, with `time` taking an optional
  # `-p` or `--` of its own. bash 3.2 does not populate BASH_REMATCH reliably,
  # so strip with sed rather than a capture loop.
  #
  # Honest limit: a command WRAPPER (`env`, `command`, `exec`, `nohup`,
  # `timeout`, `xargs`) also stands where the command word is read and is NOT
  # stripped, so it still hides the invocation. Each carries its own option
  # grammar, and a blind strip would misread `env -i git …` and `timeout 5 git
  # …`, so closing them needs a per-wrapper option table rather than this list.
  #
  # block-main-destructive-git.sh and red-verify-commit-check.sh carry this
  # expression too, and block-no-verify.bats pins the copies identical: a
  # widening applied to one and not the rest leaves the gap open in whichever
  # copy was missed.
  seg_cmd=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*\+?=([^[:space:]"'"'"']+|"[^"]*"|'"'"'[^'"'"']*'"'"')*|[{!]|coproc|elif|else|while|until|then|time([[:space:]]+(-p|--))?|do|if)[[:space:]]+)*//')
  [[ "$seg_cmd" =~ ^git([[:space:]]|$) ]] || continue

  is_commit=0
  is_push=0
  [[ "$seg" =~ (^|[[:space:]])commit([[:space:]]|$) ]] && is_commit=1
  [[ "$seg" =~ (^|[[:space:]])push([[:space:]]|$) ]] && is_push=1
  [[ "$is_commit" -eq 1 || "$is_push" -eq 1 ]] || continue

  [[ "$is_commit" -eq 1 ]] && saw_commit=1
  [[ "$is_push" -eq 1 ]] && saw_push=1

  sub="commit"
  [[ "$is_commit" -eq 1 ]] || sub="push"

  # All bypass checks are scoped to THIS git segment.

  # --no-verify, both commit and push.
  if [[ "$seg" =~ (^|[[:space:]])--no-verify([[:space:]]|=|$) ]]; then
    deny "$(floor_msg '--no-verify')"
  fi

  # Falsy HUSKY= prefix (HUSKY=0, HUSKY=false, HUSKY=no, or empty), both. The
  # `+=` spelling is read too: it appends, so on the unset HUSKY that is the
  # ordinary case it assigns the same falsy value the `=` spelling does.
  if [[ "$seg" =~ (^|[[:space:]])HUSKY\+?=(0|false|no)?([[:space:]]|$) ]]; then
    deny "$(floor_msg 'HUSKY disabled')"
  fi

  # -c core.hooksPath=<path> override, both. Git config keys are
  # case-insensitive, so match the key case-insensitively.
  if grep -iqE -- '-c[[:space:]]+core\.hookspath=' <<<"$seg"; then
    deny "$(floor_msg '-c core.hooksPath override')"
  fi

  # -n short flag = --no-verify, COMMIT ONLY. `git push -n` is --dry-run and
  # must pass. Matches a single-dash short-flag bundle containing n (-n, -nm,
  # -anm), never the long --no-verify (handled above) or --dry-run. Scoped to
  # the git segment so a `-n` on another program (grep/head/sort/tail) is inert.
  if [[ "$is_commit" -eq 1 ]] \
     && [[ "$seg" =~ (^|[[:space:]])-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$) ]]; then
    deny "$(floor_msg '-n (= --no-verify)')"
  fi
done < <({ printf '%s\n' "$cmd"; collapsed_substitutions "$cmd"; hidden_bodies "$cmd"; } | tr '|&;()' '\n')

# Fail-closed safety net for the UNAMBIGUOUS tokens. Segment-splitting on a
# `| & ; ( )` that is actually inside a quoted commit message could orphan a
# trailing bypass flag from its `git` segment (e.g. `git commit -m "a|b"
# --no-verify`). These three tokens are specific enough that a whole-command
# match, given a confirmed command-position commit/push above, is a real bypass
#, re-assert it. (`-n` is deliberately excluded: it is too common in other
# programs to test whole-command without re-introducing false positives.)
if [[ "$saw_commit" -eq 1 || "$saw_push" -eq 1 ]]; then
  sub="commit"
  [[ "$saw_commit" -eq 1 ]] || sub="push"
  if [[ "$cmd" =~ (^|[[:space:]])--no-verify([[:space:]]|=|$) ]]; then
    deny "$(floor_msg '--no-verify')"
  fi
  if [[ "$cmd" =~ (^|[[:space:]])HUSKY\+?=(0|false|no)?([[:space:]]|$) ]]; then
    deny "$(floor_msg 'HUSKY disabled')"
  fi
  if grep -iqE -- '-c[[:space:]]+core\.hookspath=' <<<"$cmd"; then
    deny "$(floor_msg '-c core.hooksPath override')"
  fi
fi

exit 0
