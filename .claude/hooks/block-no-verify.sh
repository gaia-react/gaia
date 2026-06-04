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
#                                   means --dry-run and is harmless — never block it.
#   HUSKY=0 (or falsy HUSKY= prefix) disables Husky for the invocation
#   -c core.hooksPath=<path>        redirects hooks to a path with no floor
#
# No carve-out is needed for GAIA's own legitimate --no-verify automation
# (audit-stamp trailer, wiki autocommit squash): those run as hook scripts
# (Stop / PreToolUse), not as Bash-tool calls, so a PreToolUse Bash hook never
# intercepts them. Do not "fix" the missing carve-out — there is no bug.
#
# Fail-closed: a commit message that literally contains a bypass token (e.g.
# `git commit -m "use --no-verify"`) over-blocks. That is the safe direction;
# rephrase the message. Policy: wiki/decisions/Quality Gate.md
set -euo pipefail

payload=$(cat)
cmd=$(echo "$payload" | jq -r '.tool_input.command // empty')

# Only act on git commands — short-circuit everything else.
[[ "$cmd" =~ (^|[[:space:]&;|])git([[:space:]]|$) ]] || exit 0

# Repo-scope: this repo's commit-floor policy governs this repo only. A git
# command aimed at a different repo (e.g. `git -C ../other commit --no-verify`)
# is out of scope — allow it. Fail-closed: any ambiguity falls through and the
# policy still enforces. Mirrors block-main-destructive-git.sh.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Only commit and push carry the floor — ignore every other git subcommand.
# Detect the subcommand by token presence so global options between `git` and
# the subcommand (e.g. `git -c core.hooksPath=… commit`) don't hide it. The
# `[[:space:]]` word boundaries keep `commit` from matching `commit-graph`.
is_commit=0
is_push=0
[[ "$cmd" =~ (^|[[:space:]])commit([[:space:]]|$) ]] && is_commit=1
[[ "$cmd" =~ (^|[[:space:]])push([[:space:]]|$) ]] && is_push=1
[[ "$is_commit" -eq 1 || "$is_push" -eq 1 ]] || exit 0

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

sub="commit"
[[ "$is_commit" -eq 1 ]] || sub="push"

floor_msg() {
  echo "Hook bypass on 'git $sub' is forbidden ($1). The Quality Gate floor (typecheck/lint/test) runs via the Husky pre-commit hook — fix the failures, don't skip the gate. See wiki/decisions/Quality Gate.md."
}

# --no-verify — both commit and push.
if [[ "$cmd" =~ (^|[[:space:]])--no-verify([[:space:]]|=|$) ]]; then
  deny "$(floor_msg '--no-verify')"
fi

# Falsy HUSKY= env prefix (HUSKY=0, HUSKY=false, HUSKY=no, or empty) — both.
if [[ "$cmd" =~ (^|[[:space:]])HUSKY=(0|false|no)?([[:space:]]|$) ]]; then
  deny "$(floor_msg 'HUSKY disabled')"
fi

# -c core.hooksPath=<path> override — both. Git config keys are
# case-insensitive, so match the key case-insensitively.
if grep -iqE -- '-c[[:space:]]+core\.hookspath=' <<<"$cmd"; then
  deny "$(floor_msg '-c core.hooksPath override')"
fi

# -n short flag = --no-verify, COMMIT ONLY. `git push -n` is --dry-run and must
# pass. Matches a single-dash short-flag bundle containing n (-n, -nm, -anm),
# never the long --no-verify (handled above) or --dry-run.
if [[ "$is_commit" -eq 1 ]] \
   && [[ "$cmd" =~ (^|[[:space:]])-[a-zA-Z]*n[a-zA-Z]*([[:space:]]|$) ]]; then
  deny "$(floor_msg '-n (= --no-verify)')"
fi

exit 0
