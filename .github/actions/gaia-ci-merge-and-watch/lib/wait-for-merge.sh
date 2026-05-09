#!/usr/bin/env bash
# Polls `gh pr view <N> --json state,mergeCommit,title` until the PR reaches
# a terminal state (MERGED or CLOSED). Emits one-line JSON to stdout:
#   {"state":"MERGED","sha":"<oid>","title":"<title>"}
#   {"state":"CLOSED","sha":null,"title":null}
#   {"state":"TIMEOUT","sha":null,"title":null}
# Exit 0 on terminal state; exit 1 on timeout.
#
# Env overrides:
#   TIMEOUT_SECONDS — defaults to 14400 (4 hours)
#   SLEEP_SECONDS — defaults to 30

set -euo pipefail

PR_NUMBER="${1:?pr number required}"
DEADLINE=$(( SECONDS + ${TIMEOUT_SECONDS:-14400} ))
SLEEP_SECONDS="${SLEEP_SECONDS:-30}"

while (( SECONDS < DEADLINE )); do
  state_json="$(gh pr view "$PR_NUMBER" --json state,mergeCommit,title 2>/dev/null || true)"
  state="$(jq -r '.state // ""' <<<"$state_json")"
  case "$state" in
    MERGED)
      jq -c '{state, sha: (.mergeCommit.oid // null), title}' <<<"$state_json"
      exit 0
      ;;
    CLOSED)
      jq -c '{state, sha: null, title: null}' <<<"$state_json"
      exit 0
      ;;
  esac
  sleep "$SLEEP_SECONDS"
done

echo '{"state":"TIMEOUT","sha":null,"title":null}'
exit 1
