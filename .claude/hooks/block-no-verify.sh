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
cmd=$(echo "$payload" | jq -r '.tool_input.command // empty')

# Only act on git commands, short-circuit everything else. (Fast path only;
# correctness comes from the command-position scan below.)
[[ "$cmd" =~ (^|[[:space:]&;|()])git([[:space:]]|$) ]] || exit 0

# Repo-scope: this repo's commit-floor policy governs this repo only. A git
# command aimed at a different repo (e.g. `git -C ../other commit --no-verify`)
# is out of scope, allow it. Fail-closed: any ambiguity falls through and the
# policy still enforces. Mirrors block-main-destructive-git.sh.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
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
    msg="$msg If this token appears only inside your commit message text, not as a real flag, that is this hook's documented over-block: rephrase the message, the gate was not bypassed."
  fi
  echo "$msg"
}

# Walk each command-position segment. Separators (`| & ; ( )`, newlines) become
# line breaks so every line begins at a command word; leading env-var
# assignments are stripped to expose it. A segment acts only when its command
# word is `git` and it carries a `commit` / `push` subcommand token, so a
# `-n` that belongs to a different program on the same command line (the
# `git commit && grep -n …` case) never trips the commit branch.
saw_commit=0
saw_push=0
while IFS= read -r seg; do
  # Command word = the first token after any leading whitespace + env-var
  # assignments (`WORD=value `). bash 3.2 does not populate BASH_REMATCH
  # reliably, so strip with sed rather than a capture loop.
  seg_cmd=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
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

  # Falsy HUSKY= prefix (HUSKY=0, HUSKY=false, HUSKY=no, or empty), both.
  if [[ "$seg" =~ (^|[[:space:]])HUSKY=(0|false|no)?([[:space:]]|$) ]]; then
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
done < <(printf '%s\n' "$cmd" | tr '|&;()' '\n')

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
  if [[ "$cmd" =~ (^|[[:space:]])HUSKY=(0|false|no)?([[:space:]]|$) ]]; then
    deny "$(floor_msg 'HUSKY disabled')"
  fi
  if grep -iqE -- '-c[[:space:]]+core\.hookspath=' <<<"$cmd"; then
    deny "$(floor_msg '-c core.hooksPath override')"
  fi
fi

exit 0
