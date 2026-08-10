#!/usr/bin/env bash
# Upsert the single code-review-audit status comment on a PR.
# Usage: cra-status-upsert.sh <pr-number> <body>
#
# The terminal status steps in .github/workflows/code-review-audit.yml each
# invoke this once, so the workflow keeps ONE code-review-audit status comment
# per PR (located by the stable marker) instead of appending a fresh comment on
# every push/synchronize.
#
# Every error path here is deliberately non-fatal: the comment is advisory, and
# the merge gate is the `GAIA-Audit` commit status, not this comment. Failing the
# job over a comment would turn an advisory surface into a merge blocker. The
# cost of that choice is that a regression degrades silently to "the status
# comment stops updating" while CI stays green, which is why this lives in a
# committed file covered by .gaia/tests/shell-lint.sh and
# .github/audit/tests/cra-status-upsert.bats rather than inside the workflow YAML
# where neither guard can see it.
#
# Reads GITHUB_REPOSITORY from the environment, as the workflow runner sets it.
set -eu

MARKER='<!-- gaia:cra-status -->'
pr="$1"
body="$2"
full_body="$(printf '%s\n%s' "$MARKER" "$body")"

if ! comments="$(MARKER="$MARKER" gh api --paginate \
    "repos/${GITHUB_REPOSITORY}/issues/${pr}/comments" \
    --jq '.[] | select(.body | contains(env.MARKER)) | .id')"; then
  echo "cra-status-upsert: comment lookup failed (non-fatal); skipping upsert to avoid posting a duplicate comment." >&2
  exit 0
fi

existing_id="$(printf '%s\n' "$comments" | head -n1)"
if [ -n "$existing_id" ]; then
  if ! gh api --method PATCH \
      "repos/${GITHUB_REPOSITORY}/issues/comments/${existing_id}" \
      -f body="$full_body" >/dev/null; then
    echo "cra-status-upsert: PATCH of comment ${existing_id} failed (non-fatal); this comment is advisory only." >&2
  fi
else
  if ! gh pr comment "$pr" --body "$full_body"; then
    echo "cra-status-upsert: posting the status comment failed (non-fatal); this comment is advisory only." >&2
  fi
fi
