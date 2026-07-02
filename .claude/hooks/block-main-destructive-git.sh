#!/usr/bin/env bash
# PreToolUse Bash hook: block commits to main/master and force-push to main/master.
#
# Command-position anchoring: the rules fire only when `git` is the command word
# of a pipeline segment (start of command, after a `| & ; ( )` separator, or
# after an env-var prefix), a real `git commit` / `git push` INVOCATION.
# Command TEXT that merely contains the words (a grep pattern, an echo string,
# a path, an argument to another program such as `grep -n -e git commit file`)
# is not an invocation and never fires.
#
# Policy: wiki/concepts/Git Workflow.md
set -euo pipefail

payload=$(cat)
cmd=$(echo "$payload" | jq -r '.tool_input.command // empty')

# Only act on git commands, short-circuit everything else. (Fast path only;
# correctness comes from the command-position scan below.)
[[ "$cmd" =~ (^|[[:space:]&;|()])git([[:space:]]|$) ]] || exit 0

# Repo-scope: this repo's main-branch policy governs this repo only. A git
# command aimed at a different repo (e.g. `git -C ../other push origin main`
# or `cd ../other && git push`) is out of scope, allow it. Fail-closed: any
# ambiguity falls through and the policy still enforces.
[ -f .claude/hooks/lib/repo-scope.sh ] && . .claude/hooks/lib/repo-scope.sh
if type cmd_targets_foreign_repo >/dev/null 2>&1 \
   && cmd_targets_foreign_repo "$cmd"; then
  exit 0
fi

# Setup standdown: while /setup-gaia provisions a greenfield repo it lands
# GAIA's own known-safe CI-install commit directly on main (main is not yet a
# collaboration surface and the commit has nothing to audit). setup-gaia
# creates this machine-local sentinel around that single commit+push and
# removes it right after, suspending the PR-only policy only for that window.
# The sentinel lives in .gaia/local/ (gitignored), so it never rides along in a
# teammate's clone: a fresh checkout always has this hook fully enforcing. The
# resting state is ON; this is the one explicit, temporary exception.
#
# Self-healing freshness bound: the sentinel is honored only while its mtime is
# within the last 10 minutes. The finalize commit+push completes in seconds, so
# a live setup is always inside that window; a sentinel a crashed or killed
# setup left behind goes stale on its own and enforcement resumes WITHOUT
# waiting for a /setup-gaia re-run to remove it. `find` returning empty (stale,
# missing, or unreadable) falls through to full enforcement, fail-closed.
if [ -f .gaia/local/setup-in-progress ] \
   && [ -n "$(find .gaia/local/setup-in-progress -mmin -10 2>/dev/null)" ]; then
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

current_branch() {
  local cwd="$1"
  if [[ -n "$cwd" ]]; then
    git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || echo ""
  else
    git symbolic-ref --short HEAD 2>/dev/null || echo ""
  fi
}

# Walk each command-position segment. Separators (`| & ; ( )`, newlines) become
# line breaks so every line begins at a command word; leading env-var
# assignments are stripped to expose it. The commit/push rules act only on
# segments whose command word is `git`, so `git commit` / `git push` appearing
# as TEXT in another program's arguments never trips the gate.
while IFS= read -r seg; do
  # Command word = the first token after any leading whitespace + env-var
  # assignments (`WORD=value `). bash 3.2 does not populate BASH_REMATCH
  # reliably, so strip with sed rather than a capture loop.
  seg_cmd=$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  [[ "$seg_cmd" =~ ^git([[:space:]]|$) ]] || continue

  # Normalize this segment: strip EVERY -C <path> for regex matching; capture
  # the path git would actually use for branch queries. git applies multiple -C
  # cumulatively with the last absolute one winning, so capture the LAST
  # occurrence (greedy .* consumes through it), a first-only capture lets
  # `git -C <a> -C <b> commit` slip past the commit/push regexes. Handles
  # `git -C /abs/path` (required by shell-cwd rule).
  git_cwd=$(printf '%s' "$seg" | sed -nE 's/.*[[:space:]]-C[[:space:]]+([^[:space:]]+).*/\1/p')
  norm=$(printf '%s' "$seg" | sed -E 's/[[:space:]]-C[[:space:]]+[^[:space:]]+//g')

  # 1. Block commits while HEAD is on main or master.
  if [[ "$norm" =~ git[[:space:]]+commit([[:space:]]|$) ]]; then
    branch=$(current_branch "$git_cwd")
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
    branch=$(current_branch "$git_cwd")
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
done < <(printf '%s\n' "$cmd" | tr '|&;()' '\n')

exit 0
