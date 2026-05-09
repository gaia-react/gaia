#!/usr/bin/env bash
# Polls post-merge CI conclusions on a commit SHA. Emits one-line JSON:
#   {"conclusion":"success","run_url":"<url>"}
#   {"conclusion":"failure","run_url":"<url>"}
#   {"conclusion":"timeout","run_url":""}
# Exit 0 on terminal (success | failure); exit 1 on timeout.
#
# Args:
#   $1 — commit SHA to query.
# Env (required):
#   GITHUB_REPOSITORY — owner/repo (provided by Actions runner).
#   DEFAULT_BRANCH — usually github.event.repository.default_branch.
# Env overrides:
#   TIMEOUT_SECONDS — defaults to 5400 (90 minutes)
#   SLEEP_SECONDS — defaults to 30

set -euo pipefail

COMMIT_SHA="${1:?commit sha required}"
DEADLINE=$(( SECONDS + ${TIMEOUT_SECONDS:-5400} ))
SLEEP_SECONDS="${SLEEP_SECONDS:-30}"

required_contexts=""
required_status_json="$(gh api "repos/${GITHUB_REPOSITORY}/branches/${DEFAULT_BRANCH}/protection/required_status_checks" 2>/dev/null || true)"

if [[ -n "$required_status_json" ]] && jq -e . >/dev/null 2>&1 <<<"$required_status_json"; then
  required_contexts="$(jq -r '.contexts[]?' <<<"$required_status_json" 2>/dev/null || true)"
fi

# A terminal conclusion is one of: success failure cancelled timed_out
# skipped neutral action_required stale. We treat anything other than
# success / skipped / neutral as failure.

while (( SECONDS < DEADLINE )); do
  runs_json="$(gh run list --commit "$COMMIT_SHA" --json conclusion,status,name,url --limit 50 2>/dev/null || echo '[]')"

  # Filter to required contexts when protection is configured. The branch
  # protection API names are workflow contexts; gh run list .name is the
  # workflow name. They line up for repos that use one workflow per
  # required check. Adopters with finer-grained protection may need a
  # different mapping; v1 keeps it simple.
  if [[ -n "$required_contexts" ]]; then
    matched_json="$(jq -c --argjson contexts "$(jq -R -s 'split("\n") | map(select(length > 0))' <<<"$required_contexts")" '[.[] | select(.name as $n | $contexts | index($n))]' <<<"$runs_json")"
  else
    matched_json="$runs_json"
  fi

  total="$(jq 'length' <<<"$matched_json")"

  if [[ "$total" -eq 0 ]]; then
    sleep "$SLEEP_SECONDS"
    continue
  fi

  pending="$(jq '[.[] | select(.status != "completed")] | length' <<<"$matched_json")"

  if [[ "$pending" -gt 0 ]]; then
    sleep "$SLEEP_SECONDS"
    continue
  fi

  # All runs terminal. Look for any non-success conclusion.
  failed_run="$(jq -c '[.[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")] | first // empty' <<<"$matched_json")"

  if [[ -n "$failed_run" && "$failed_run" != "null" ]]; then
    run_url="$(jq -r '.url' <<<"$failed_run")"
    jq -c -n --arg url "$run_url" '{conclusion: "failure", run_url: $url}'
    exit 0
  fi

  jq -c -n '{conclusion: "success", run_url: ""}'
  exit 0
done

echo '{"conclusion":"timeout","run_url":""}'
exit 1
