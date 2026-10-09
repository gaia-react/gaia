#!/usr/bin/env bash
# Posts the GAIA-Audit commit status for a pull request that needs no audit.
# Sourced, never executed; does no work at source time.
#
#   audit_post_bypass_status <pr-number> <head-sha> <description>
#
# Branch protection that requires GAIA-Audit waits on that context for every
# pull request, including the ones no Code Audit Team member is dispatched
# for. post-audit-status.sh posts it only off a member marker, so a pull
# request cleared by a bypass would wait forever without this. The caller
# decides that a bypass applies; this file only posts, and it posts exactly
# the description it is given.
#
# Best-effort and silent on stdout: the caller is a PreToolUse hook whose
# stdout is its decision channel and whose allow must not turn into a failure
# over a status it could not post, so a status that is not posted returns 0.
# Any failure (gh absent or unauthenticated, an unresolvable repository or head
# sha, a rejected POST) prints one stderr line naming the manual command
# instead.
#
# Pull requests open as drafts, and a draft cannot be merged, so once the
# status has posted this marks the pull request ready for review
# (`gh pr ready <pr-number>`), strictly after the status, and only when the
# pull request is a draft. A flip that fails
# prints one stderr line naming the manual command and returns 1; the posted
# status is never rolled back, and the caller ignores the return value.
#
# The status lands on exactly the <head-sha> it is given, which the caller has
# already proven is the content it classified; this file never re-reads the
# pull request head from GitHub, so a push landing after the classification
# cannot move the status onto a commit nobody classified. If the pull request
# head has since moved, the status sits on a commit branch protection does not
# read and the merge stays blocked.

audit_post_bypass_status() {
  local pr_number="${1-}" head_sha="${2-}" description="${3-}" repository='' failure=''

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

  if [ -z "$failure" ] && ! [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
    failure="'${head_sha}' is not a 40-character head sha"
    head_sha=''
  fi

  if [ -z "$failure" ]; then
    if ! GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
      gh api -X POST "repos/${repository}/statuses/${head_sha}" \
      -f state=success -f context=GAIA-Audit -f "description=${description}" \
      >/dev/null 2>&1 </dev/null; then
      failure="gh api rejected the status POST for ${head_sha}"
    fi
  fi

  if [ -z "$failure" ]; then
    # Only a draft needs the flip; a pull request opened ready (a private
    # repository where GitHub refuses drafts) has none to make. An unreadable
    # draft state falls through to the flip so a failure is reported.
    local is_draft=''
    is_draft=$(GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
      gh pr view "$pr_number" --json isDraft --jq .isDraft 2>/dev/null </dev/null) || is_draft=''
    if [ "$is_draft" = false ]; then
      return 0
    fi
    if ! GH_NO_UPDATE_NOTIFIER=1 GH_PROMPT_DISABLED=1 \
      gh pr ready "$pr_number" >/dev/null 2>&1 </dev/null; then
      printf 'GAIA-Audit bypass status posted, but the draft flip failed. Mark the pull request ready by hand: gh pr ready %s\n' \
        "$pr_number" >&2
      return 1
    fi
    return 0
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
