#!/usr/bin/env bash
# PreToolUse Bash hook on `gh pr merge`: the deterministic caller for
# post-findings-block.sh. Under local audit mode no code path posted the
# machine-readable findings block, only a hand-run snippet did, so a local
# merge contributed nothing to the finding-recurrence tally. This hook closes
# that gap: on a real `gh pr merge` invocation whose resolved audit mode is
# `local`, it resolves the incremental audit base and calls the existing
# producer. Pure side effect: it never blocks the merge and never emits a
# permission decision.

set -euo pipefail
trap 'exit 0' ERR

command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
tool_name=$(jq -r '.tool_name // ""' <<<"$payload")
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(jq -r '.tool_input.command // ""' <<<"$payload")

# Match `gh pr merge` as a real shell invocation, at command start or right
# after a shell separator (&&, ;, ||, |, newline), not when mentioned mid-line
# in prose or a quoted string. Mirrors token-rollup-merge.sh's command match.
start_re='^[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
sep_re=$'(\\&\\&|;|\\|\\||\\||\n)[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'
if [[ "$cmd" =~ $start_re ]]; then
  :
elif [[ "$cmd" =~ $sep_re ]]; then
  :
else
  exit 0
fi

# `gh pr merge` aimed at a different repo has no bearing on this repo's audit
# posting; allow it.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Resolve the PR number: prefer a literal <N> in the command, else ask gh for
# the PR bound to the current branch.
pr_re='gh[[:space:]]+pr[[:space:]]+merge[[:space:]]+([0-9]+)'
PR=""
if [[ "$cmd" =~ $pr_re ]]; then
  PR="${BASH_REMATCH[1]}"
fi
if [ -z "$PR" ]; then
  PR="$(gh pr view --json number --jq .number 2>/dev/null || true)"
fi
[ -n "$PR" ] || exit 0

# Resolve the audit mode via the shared resolver: the SAME resolved_mode CI
# reads for this author, so the two producers can never disagree about who
# posts. Proceed ONLY when resolved_mode is exactly `local`; any other value,
# or any resolution failure/ambiguity, means posting here could clobber CI's
# own findings block, so this exits without posting.
is_fork="$(gh pr view "$PR" --json isCrossRepository --jq .isCrossRepository 2>/dev/null || true)"
author="$(gh pr view "$PR" --json author --jq .author.login 2>/dev/null || true)"
[ -n "$author" ] || exit 0

resolved_mode=""
eval "$(PR_IS_FORK="$is_fork" bash .gaia/scripts/read-audit-ci-config.sh --resolve-author "$author" 2>/dev/null)" || true
[ "$resolved_mode" = "local" ] || exit 0

# Resolve the incremental audit base the same way the audited member(s) do.
BASE_REF="$(.github/audit/resolve-audit-base.sh 2>/dev/null || true)"
[ -n "$BASE_REF" ] || exit 0
BASE_SHA="$(git merge-base "$BASE_REF" HEAD 2>/dev/null || true)"
[ -n "$BASE_SHA" ] || exit 0

# Best-effort: post-findings-block.sh always exits 0 and declines cleanly
# when no sidecars exist, so an early merge attempt before the audit ran
# posts nothing rather than an empty block.
bash .gaia/scripts/post-findings-block.sh --base "$BASE_SHA" --pr "$PR" >/dev/null 2>&1 || true

exit 0
