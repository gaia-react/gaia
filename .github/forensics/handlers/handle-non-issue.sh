#!/usr/bin/env bash
# handle-non-issue.sh — UAT-002 action handler.
#
# Closes a forensics-triaged issue, applies the `non-issue` and (last)
# `gaia-triaged` labels, and posts the classifier reasoning as a comment
# with a "verdict: non-issue" header.
#
# Usage:
#   handle-non-issue.sh <issue-num> <reasoning-file>
#
# <reasoning-file> path to a file containing the classifier's reasoning;
# always passed as a path (never inlined) because the body may contain
# arbitrary shell metacharacters even after phase-1 redaction.
#
# Exit code: 0 on success or no-op idempotency. Non-zero only on a real
# script error (bad usage, missing file, gh failure not related to
# already-applied state).
#
# Contract: SPEC-002 UAT-002 / UAT-006 / UAT-015 (passthrough).
# Idempotency: gh issue edit --add-label re-applying an existing label is
# a no-op; gh issue close on an already-closed issue is a no-op for our
# purposes. The final --add-label gaia-triaged is the durable idempotency
# key the workflow's UAT-006 early-exit reads on the next fire.

set -euo pipefail

usage() {
  echo "usage: handle-non-issue.sh <issue-num> <reasoning-file>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
issue_num="$1"
reasoning_file="$2"

[ -f "$reasoning_file" ] || { echo "handle-non-issue.sh: reasoning file not found: $reasoning_file" >&2; exit 2; }

work_dir=$(mktemp -d 2>/dev/null) || { echo "handle-non-issue.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work_dir"' EXIT

# Compose the comment body: header + reasoning passthrough.
comment_file="$work_dir/comment.md"
{
  printf 'verdict: non-issue\n\n'
  cat "$reasoning_file"
} > "$comment_file"

# Order:
#   1. Apply the classification label (`non-issue`).
#   2. Post the verdict comment via --body-file (never --body "$(...)" —
#      reasoning may contain shell metacharacters even after redaction).
#   3. Close the issue.
#   4. Apply `gaia-triaged` LAST so the idempotency key is the final
#      mutation to land. Under UAT-011's concurrency-queued re-fire, any
#      partial completion that lands `gaia-triaged` has, by construction,
#      already done the rest.
gh issue edit "$issue_num" --add-label "non-issue"
gh issue comment "$issue_num" --body-file "$comment_file"
gh issue close "$issue_num"
gh issue edit "$issue_num" --add-label "gaia-triaged"

exit 0
