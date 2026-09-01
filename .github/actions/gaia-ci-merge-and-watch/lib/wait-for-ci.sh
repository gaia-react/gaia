#!/usr/bin/env bash
# Polls post-merge CI conclusions on a commit SHA. Emits one-line JSON:
#   {"conclusion":"success","run_url":"<url>"}
#   {"conclusion":"failure","run_url":"<url>"}
#   {"conclusion":"timeout","run_url":""}
#   {"conclusion":"query-failed","run_url":"","error":"<last poll's stderr>"}
# Exit 0 on terminal (success | failure); exit 1 on timeout and query-failed.
#
# Exhausting the deadline is reachable from two conditions, and they are
# reported apart because their repairs are opposites. `timeout` means the polls
# were answered and no run reached a terminal state, which a longer deadline can
# fix. `query-failed` means the poll itself never got an answer -- an expired
# token, a rate limit, a network fault, a repository the token cannot see --
# which no deadline can fix, so it carries the query's own stderr as the
# evidence the operator picks a repair from. The last poll decides which is
# emitted, so the verdict describes the state the script actually left off in.
#
# Args:
#   $1: commit SHA to query.
# Env (required):
#   GITHUB_REPOSITORY: owner/repo (provided by Actions runner).
#   DEFAULT_BRANCH: usually github.event.repository.default_branch.
# Env overrides:
#   TIMEOUT_SECONDS: defaults to 5400 (90 minutes)
#   SLEEP_SECONDS: defaults to 30

set -euo pipefail

COMMIT_SHA="${1:?commit sha required}"
DEADLINE=$(( SECONDS + ${TIMEOUT_SECONDS:-5400} ))
SLEEP_SECONDS="${SLEEP_SECONDS:-30}"

# Holds the most recent poll's stderr while that poll is the last one to have
# run, and is cleared by any poll that answers. Non-empty once the deadline is
# reached therefore means the script never got an answer out of the poll it
# stopped on, which is the state `query-failed` reports.
query_error=""
query_stderr="$(mktemp)"
trap 'rm -f "$query_stderr"' EXIT

required_contexts=""
required_status_json="$(gh api "repos/${GITHUB_REPOSITORY}/branches/${DEFAULT_BRANCH}/protection/required_status_checks" 2>/dev/null || true)"

if [[ -n "$required_status_json" ]] && jq -e . >/dev/null 2>&1 <<<"$required_status_json"; then
  required_contexts="$(jq -r '.contexts[]?' <<<"$required_status_json" 2>/dev/null || true)"
fi

# A terminal conclusion is one of: success failure cancelled timed_out
# skipped neutral action_required stale. We treat anything other than
# success / skipped / neutral as failure.

while (( SECONDS < DEADLINE )); do
  # `rc=0` then `|| rc=$?`, never a bare assignment followed by `rc=$?`: an
  # assignment takes its command substitution's status, so under `set -e` a
  # failing `gh` would kill the script on the assignment line and every branch
  # below would be dead code.
  #
  # Discarding stderr and substituting `[]` on failure is the shorter spelling
  # and the one that collapses the two states: `[]` is byte-identical to what an
  # answered poll with no runs yet returns, so the status is the only thing that
  # separates a query nobody answered from a CI that has not started, and
  # throwing it away leaves nothing downstream able to tell them apart.
  rc=0
  runs_json="$(gh run list --commit "$COMMIT_SHA" --json conclusion,status,name,url --limit 50 2>"$query_stderr")" || rc=$?

  if [[ $rc -ne 0 ]]; then
    # The tail rather than the whole stream: gh prints its usage block on some
    # failures and the operative line is the last one.
    query_error="$(tail -n 3 "$query_stderr" | tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
    if [[ -z "$query_error" ]]; then
      query_error="gh run list exited $rc without writing to stderr"
    fi
    # `tail -n 3` bounds lines, not bytes, so a single unbroken stderr line (a
    # proxy returning an HTML body) survives whole and then reaches jq through
    # argv, where Linux caps one argument at 131,072 bytes. Past that the exec
    # fails and this script dies emitting nothing, losing the very diagnosis the
    # value carries. Bounded with a shell slice rather than a `head -c` stage in
    # the pipeline above: `head` exits as soon as it has its bytes, and the
    # SIGPIPE that sends upstream makes the whole pipeline non-zero under
    # `pipefail`, trading a lost message for a dead script. The slice counts
    # codepoints under a UTF-8 locale and bytes under C, so the worst case is
    # 4000 four-byte characters, 16,000 bytes against that cap. Under C it can
    # also split a character; jq replaces the invalid tail with U+FFFD and the
    # emission site's own slice trims it back off.
    query_error="${query_error:0:4000}"
    sleep "$SLEEP_SECONDS"
    continue
  fi

  query_error=""

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

if [[ -n "$query_error" ]]; then
  # Slice by codepoint, so the cut cannot halve a multibyte character. This is
  # the bound on what action.yml writes into $GITHUB_OUTPUT, where an oversized
  # value would trip the per-output size limit and fail the step with a size
  # error in place of the diagnosis. It is not the only bound the value needs:
  # the argv limit is upstream of this program, so the capture site applies its
  # own.
  jq -c -n --arg err "$query_error" '{conclusion: "query-failed", run_url: "", error: ($err[0:500])}'
  exit 1
fi

echo '{"conclusion":"timeout","run_url":""}'
exit 1
