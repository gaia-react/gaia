#!/usr/bin/env bash
# handle-auto-fixable.sh: UAT-004 action handler.
#
# Pre-conditions: the workflow has already created `<fix-branch>` from
# `main`, applied the candidate fix, run the Quality Gate green, and
# pushed. This handler ONLY opens the draft PR and applies labels.
#
# Usage:
#   handle-auto-fixable.sh <issue-num> <class-slug> <fix-branch> <pr-body-file>
#
# <pr-body-file> path to a file holding the PR body. Per UAT-015 the
# body cites `## Capture` from the issue verbatim, the workflow that
# composes this file is responsible for the passthrough; this handler
# never re-redacts.
#
# Exit code: 0 on success. 1 if `<fix-branch>` is missing on origin
# (sanity check). gh-level failures propagate.
#
# Contract: UAT-004 / UAT-008 (PR is draft) / UAT-015 (passthrough). The
# contract requires the `--draft` flag on `gh pr create`.

set -euo pipefail

usage() {
  echo "usage: handle-auto-fixable.sh <issue-num> <class-slug> <fix-branch> <pr-body-file>" >&2
  exit 2
}

[ "$#" -eq 4 ] || usage
issue_num="$1"
class_slug="$2"
fix_branch="$3"
pr_body_file="$4"

[ -f "$pr_body_file" ] || { echo "handle-auto-fixable.sh: pr body file not found: $pr_body_file" >&2; exit 2; }

# 1. Sanity check: branch must exist on origin. Without this, gh pr create
#    would happily try to push the local branch, but the workflow's
#    contract says the gate-passing push has already happened. A missing
#    remote ref means an upstream invariant is broken; fail loudly.
if ! git ls-remote --exit-code --heads origin "$fix_branch" >/dev/null 2>&1; then
  echo "handle-auto-fixable.sh: fix branch missing on origin: $fix_branch" >&2
  exit 1
fi

# 2. Resolve the issue title for the PR title. We use --json to avoid
#    fragile parsing of `gh issue view` text output.
issue_title="$(gh issue view "$issue_num" --json title --jq '.title')"
if [ -z "$issue_title" ]; then
  echo "handle-auto-fixable.sh: could not resolve title for issue #$issue_num" >&2
  exit 1
fi

pr_title="[gaia-forensics] ${issue_title} (#${issue_num})"

# 3. Open the draft PR. --draft is the UAT-008 hard requirement; the
#    handler MUST NEVER mark it ready-for-review. --body-file (never
#    --body "$(...)") is the same shell-metacharacter discipline the
#    issue-comment paths use; PR body content is phase-1-redacted but
#    may still contain backticks, dollars, etc.
pr_url="$(gh pr create \
  --draft \
  --base main \
  --head "$fix_branch" \
  --title "$pr_title" \
  --body-file "$pr_body_file")"

# 4. Apply the fix-related labels. Order: classification labels first,
#    then `gaia-triaged` LAST so the idempotency key is the final
#    mutation. `class_slug` is reserved for callers and used in the
#    branch name; kept in the surface for forward-compat with any
#    future per-class labelling without renegotiating the contract.
gh issue edit "$issue_num" --add-label "auto-fixable"
gh issue edit "$issue_num" --add-label "gaia-bug-confirmed"

# 5. Link the PR back from the issue. Comment last (before triaged) so
#    a re-fire under UAT-011 sees the triaged label and exits before
#    duplicating the link.
work_dir=$(mktemp -d 2>/dev/null) || { echo "handle-auto-fixable.sh: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work_dir"' EXIT

link_file="$work_dir/link.md"
{
  printf 'verdict: auto-fixable (class: `%s`)\n\n' "$class_slug"
  printf 'Draft PR opened: %s\n\n' "$pr_url"
  printf 'Quality Gate passed on `%s`. Branch + PR are draft pending human review per branch protection on `main`.\n' "$fix_branch"
} > "$link_file"

gh issue comment "$issue_num" --body-file "$link_file"

# 6. `gaia-triaged` LAST.
gh issue edit "$issue_num" --add-label "gaia-triaged"

exit 0
