#!/usr/bin/env bash
# PreToolUse Bash hook: block commits to main/master and force-push to main/master.
# Policy: wiki/concepts/Git Workflow.md
set -euo pipefail

payload=$(cat)
cmd=$(echo "$payload" | jq -r '.tool_input.command // empty')

# Only act on git commands — short-circuit everything else
[[ "$cmd" =~ (^|[[:space:]&;|])git([[:space:]]|$) ]] || exit 0

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

# 1. Block commits while HEAD is on main or master.
if [[ "$cmd" =~ git[[:space:]]+commit([[:space:]]|$) ]]; then
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [[ "$branch" == "main" || "$branch" == "master" ]]; then
    deny "Commits to '$branch' are forbidden (wiki/concepts/Git Workflow.md). Create a feature branch first."
  fi
fi

# 2. Block force-push when target mentions main or master.
if [[ "$cmd" =~ git[[:space:]]+push ]] \
   && [[ "$cmd" =~ (--force|--force-with-lease|[[:space:]]-f([[:space:]]|$)) ]] \
   && [[ "$cmd" =~ (main|master)([[:space:]]|$|:) ]]; then
  deny "Force-push to main/master is forbidden (wiki/concepts/Git Workflow.md)."
fi

# 3. Block any `git push` originating from main/master (PR-only flow).
#    Triggers when HEAD is on main/master OR when the push refspec explicitly
#    names main/master/HEAD as the source. Closes the "forgot to switch
#    branches" footgun. See open question #1 in the release-prep README.
if [[ "$cmd" =~ git[[:space:]]+push ]]; then
  branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
  on_main=0
  [[ "$branch" == "main" || "$branch" == "master" ]] && on_main=1

  # Refspec-targeted push from main/master/HEAD: e.g. `git push origin main`,
  # `git push origin HEAD:main`, `git push origin main:main`.
  refspec_main=0
  if [[ "$cmd" =~ git[[:space:]]+push[[:space:]]+[^[:space:]]+[[:space:]]+(HEAD|main|master)([[:space:]]|:|$) ]]; then
    refspec_main=1
  fi

  if [[ "$on_main" -eq 1 || "$refspec_main" -eq 1 ]]; then
    deny "Plain 'git push' from main/master is forbidden (wiki/concepts/Git Workflow.md). Create a feature branch and open a PR."
  fi
fi

exit 0
