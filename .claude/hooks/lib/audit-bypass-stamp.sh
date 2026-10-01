#!/usr/bin/env bash
# Posts the GAIA-Audit commit status for a pull request that needs no audit.
# Sourced, never executed; does no work at source time.
#
#   audit_post_bypass_status <pr-number> <description>
#
# Branch protection that requires GAIA-Audit waits on that context for every
# pull request, including the ones no Code Audit Team member is dispatched
# for. post-audit-status.sh posts it only off a member marker, so a pull
# request cleared by a bypass would wait forever without this. The caller
# decides that a bypass applies; this file only posts, and it posts exactly
# the description it is given.
#
# Best-effort and silent on stdout: it always returns 0, because the caller is
# a PreToolUse hook whose stdout is its decision channel and whose allow must
# not turn into a failure over a status it could not post. Any failure (gh
# absent or unauthenticated, an unresolvable repository or head sha, a
# rejected POST) prints one stderr line naming the manual command instead.
#
# The status lands on the head sha GitHub reports for the pull request, which
# is the commit branch protection reads. Whether that sha is the content the
# caller classified is the caller's question to settle before calling.

audit_post_bypass_status() {
  local pr_number="${1-}" description="${2-}" repository='' head_sha='' failure=''

  case "$pr_number" in
    '' | *[!0-9]*) failure="'${pr_number}' is not a pull request number" ;;
  esac

  if [ -z "$failure" ] && ! command -v gh >/dev/null 2>&1; then
    failure='gh is not on PATH'
  fi

  if [ -z "$failure" ]; then
    repository="${GITHUB_REPOSITORY:-}"
    if [ -z "$repository" ]; then
      repository=$(GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
        gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null </dev/null) || repository=''
    fi
    case "$repository" in
      */*/*) failure="the repository resolved to '${repository}', not owner/name" ;;
      ?*/?*) ;;
      *) failure='gh could not resolve this repository' ;;
    esac
  fi

  if [ -z "$failure" ]; then
    head_sha=$(GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
      gh pr view "$pr_number" --json headRefOid --jq .headRefOid 2>/dev/null </dev/null) || head_sha=''
    if ! [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
      failure="gh could not resolve the head sha of pull request ${pr_number}"
      head_sha=''
    fi
  fi

  if [ -z "$failure" ]; then
    if ! GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
      gh api -X POST "repos/${repository}/statuses/${head_sha}" \
      -f state=success -f context=GAIA-Audit -f "description=${description}" \
      >/dev/null 2>&1 </dev/null; then
      failure="gh api rejected the status POST for ${head_sha}"
    fi
  fi

  if [ -n "$failure" ]; then
    # {owner}/{repo} is gh api's own placeholder, which it fills from the
    # current repository, so the line stays runnable when the slug is unknown.
    local manual_repository='{owner}/{repo}'
    case "$repository" in ?*/?*) manual_repository="$repository" ;; esac
    printf 'GAIA-Audit bypass status not posted (%s). Post it by hand: gh api -X POST repos/%s/statuses/%s -f state=success -f context=GAIA-Audit -f description='"'"'%s'"'"'\n' \
      "$failure" "$manual_repository" "${head_sha:-<sha>}" "$description" >&2
  fi
  return 0
}
