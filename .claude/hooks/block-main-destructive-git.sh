#!/usr/bin/env bash
# PreToolUse Bash hook: block commits to main/master and force-push to main/master.
# Policy: wiki/concepts/Git Workflow.md
set -euo pipefail

payload=$(cat)
cmd=$(echo "$payload" | jq -r '.tool_input.command // empty')

# Only act on git commands — short-circuit everything else
[[ "$cmd" =~ (^|[[:space:]&;|])git([[:space:]]|$) ]] || exit 0

# Repo-scope: this repo's main-branch policy governs this repo only. A git
# command aimed at a different repo (e.g. `git -C ../other push origin main`
# or `cd ../other && git push`) is out of scope — allow it. Fail-closed: any
# ambiguity falls through and the policy still enforces.
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

# Normalize: strip EVERY -C <path> for regex matching; capture the path git
# would actually use for git queries. git applies multiple -C cumulatively
# with the last absolute one winning, so capture the LAST occurrence (greedy
# .* consumes through it) — a first-only capture lets `git -C <a> -C <b>
# commit` slip past the commit/push regexes. Handles `git -C /abs/path`
# (required by shell-cwd rule). Uses sed — bash 3.2 (macOS default) doesn't
# populate BASH_REMATCH reliably.
git_cwd=$(echo "$cmd" | sed -nE 's/.*[[:space:]]-C[[:space:]]+([^[:space:]]+).*/\1/p')
norm=$(echo "$cmd" | sed -E 's/[[:space:]]-C[[:space:]]+[^[:space:]]+//g')

current_branch() {
  if [[ -n "$git_cwd" ]]; then
    git -C "$git_cwd" symbolic-ref --short HEAD 2>/dev/null || echo ""
  else
    git symbolic-ref --short HEAD 2>/dev/null || echo ""
  fi
}

# 1. Block commits while HEAD is on main or master.
if [[ "$norm" =~ git[[:space:]]+commit([[:space:]]|$) ]]; then
  branch=$(current_branch)
  if [[ "$branch" == "main" || "$branch" == "master" ]]; then
    deny "Commits to '$branch' are forbidden (wiki/concepts/Git Workflow.md). Create a feature branch first."
  fi
fi

# 2. Block force-push when target mentions main or master.
if [[ "$norm" =~ git[[:space:]]+push ]] \
   && [[ "$norm" =~ (--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)) ]] \
   && [[ "$norm" =~ (main|master)([[:space:]]|$|:) ]]; then
  deny "Force-push to main/master is forbidden (wiki/concepts/Git Workflow.md)."
fi

# 3. Block any `git push` originating from main/master (PR-only flow).
#    Triggers when HEAD is on main/master OR when the push refspec explicitly
#    names main/master/HEAD as the source. Closes the "forgot to switch
#    branches" footgun.
if [[ "$norm" =~ git[[:space:]]+push ]]; then
  branch=$(current_branch)
  on_main=0
  [[ "$branch" == "main" || "$branch" == "master" ]] && on_main=1

  # Refspec-targeted push from main/master/HEAD: e.g. `git push origin main`,
  # `git push origin HEAD:main`, `git push origin main:main`.
  refspec_main=0
  if [[ "$norm" =~ git[[:space:]]+push[[:space:]]+[^[:space:]]+[[:space:]]+(HEAD|main|master)([[:space:]]|:|$) ]]; then
    refspec_main=1
  fi

  if [[ "$on_main" -eq 1 || "$refspec_main" -eq 1 ]]; then
    deny "Plain 'git push' from main/master is forbidden (wiki/concepts/Git Workflow.md). Create a feature branch and open a PR."
  fi
fi

exit 0
