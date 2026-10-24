#!/usr/bin/env bash
# report-main-status.sh: keep one open `ci-red-main` issue while main is red.
#
# Run by the push-to-main reporting job in audit-ci-tests.yml. The interface is
# environment-only, no arguments: GH_TOKEN, REPOSITORY, RUN_ID, RUN_ATTEMPT,
# RUN_URL, BEFORE_SHA, HEAD_SHA, SHARDS_RESULT. Every value arrives through the
# environment and is passed to `gh` as an argument or written to a body file,
# never spliced into a shell command string.
#
# Only the commit range, the run link and failing job names reach the issue.
# Commit messages, authors and ref names are never read, so event text an
# author controls cannot land in the title or body.
#
# Exit 0 on every handled path, 2 on a missing variable (before any `gh` call),
# non-zero with a `report-main-status:` stderr line on a `gh` failure.

set -euo pipefail

readonly LABEL_NAME="ci-red-main"
readonly ISSUE_TITLE="Main is red: GAIA: Audit CI Tests"
readonly ZERO_SHA="0000000000000000000000000000000000000000"

for required_variable in GH_TOKEN REPOSITORY RUN_ID RUN_ATTEMPT RUN_URL HEAD_SHA SHARDS_RESULT; do
  if [ -z "${!required_variable:-}" ]; then
    printf 'report-main-status: missing required variable %s\n' "$required_variable" >&2
    exit 2
  fi
done
BEFORE_SHA="${BEFORE_SHA:-}"

# Cancelled, skipped or any other result is not a verdict on main.
case "$SHARDS_RESULT" in
  failure | success) ;;
  *) exit 0 ;;
esac

run_gh() {
  local description="$1"
  shift
  if ! gh "$@"; then
    printf 'report-main-status: %s failed\n' "$description" >&2
    exit 1
  fi
}

body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT

open_issue_numbers=$(run_gh "listing open ci-red-main issues" issue list --repo "$REPOSITORY" --label "$LABEL_NAME" --state open --json number --jq '.[].number')
issue_number=""
if [ -n "$open_issue_numbers" ]; then
  issue_number=$(printf '%s\n' "$open_issue_numbers" | sort -n | head -n 1)
  if [ "$(printf '%s\n' "$open_issue_numbers" | wc -l)" -gt 1 ]; then
    printf 'report-main-status: more than one open %s issue; acting on #%s only\n' "$LABEL_NAME" "$issue_number" >&2
  fi
fi

if [ "$SHARDS_RESULT" = "success" ]; then
  if [ -z "$issue_number" ]; then
    exit 0
  fi

  # Anyone can comment on a public issue, so only text the workflow token wrote can carry the marker.
  issue_text=$(run_gh "reading issue $issue_number" issue view "$issue_number" --repo "$REPOSITORY" --json body,author,comments --jq '[{author: .author, body: .body}] + .comments | map(select(.author.login == "github-actions" or .author.login == "app/github-actions") | .body) | join("\n")')
  red_sha=$(printf '%s\n' "$issue_text" | grep -o 'red-main-sha: [0-9a-f]\{7,64\}' | tail -n 1 | sed 's/^red-main-sha: //' || true)

  compare_status=""
  if [ -n "$red_sha" ]; then
    compare_status=$(gh api "repos/$REPOSITORY/compare/$red_sha...$HEAD_SHA" --jq '.status' 2>/dev/null || true)
  fi

  case "$compare_status" in
    identical | ahead)
      printf 'Main is green again: [this run](%s) passed on %s.\n' "$RUN_URL" "$HEAD_SHA" > "$body_file"
      run_gh "commenting on issue $issue_number" issue comment "$issue_number" --repo "$REPOSITORY" --body-file "$body_file"
      run_gh "closing issue $issue_number" issue close "$issue_number" --repo "$REPOSITORY"
      ;;
    *)
      printf '[This green run](%s) on %s did not close the issue: it is not the red commit or a descendant of it, so main may still be red.\n' "$RUN_URL" "$HEAD_SHA" > "$body_file"
      run_gh "commenting on issue $issue_number" issue comment "$issue_number" --repo "$REPOSITORY" --body-file "$body_file"
      ;;
  esac
  exit 0
fi

failing_jobs=$(run_gh "listing failing jobs" api --paginate "repos/$REPOSITORY/actions/runs/$RUN_ID/attempts/$RUN_ATTEMPT/jobs" --jq '.jobs[] | select(.conclusion == "failure") | .name')

if [ -z "$BEFORE_SHA" ] || [ "$BEFORE_SHA" = "$ZERO_SHA" ]; then
  range_line="Commit: $HEAD_SHA"
else
  repository_url="${RUN_URL%/actions/runs/*}"
  range_line="Commits: ${BEFORE_SHA}..${HEAD_SHA} ([compare](${repository_url}/compare/${BEFORE_SHA}...${HEAD_SHA}))"
fi

{
  printf 'Main failed [this run](%s).\n\n' "$RUN_URL"
  printf '%s\n\n' "$range_line"
  printf 'Failing legs:\n'
  if [ -n "$failing_jobs" ]; then
    printf '%s\n' "$failing_jobs" | sed 's/^/- /'
  else
    printf -- '- none reported by the jobs listing\n'
  fi
  printf '\n<!-- red-main-sha: %s -->\n' "$HEAD_SHA"
} > "$body_file"

if [ -n "$issue_number" ]; then
  run_gh "commenting on issue $issue_number" issue comment "$issue_number" --repo "$REPOSITORY" --body-file "$body_file"
else
  run_gh "creating label $LABEL_NAME" label create "$LABEL_NAME" --force --repo "$REPOSITORY" --description "Main failed GAIA: Audit CI Tests"
  run_gh "creating issue" issue create --repo "$REPOSITORY" --title "$ISSUE_TITLE" --label "$LABEL_NAME" --body-file "$body_file"
fi
