#!/usr/bin/env bash
# audit-success-present.sh, is a GAIA-Audit success already LIVE for this tree?
#
# Purpose
#   The read side of the merge gate's non-clobber guard. A GitHub commit status
#   has no compare-and-set: for a given context the newest write wins outright.
#   CI runs the default member alone, so it cannot clear a co-dispatched
#   specialized member and correctly declines to post success, posting `pending`
#   instead. Meanwhile the LOCAL member-aware producer
#   (.claude/hooks/post-audit-status.sh) posts `success` once EVERY dispatched
#   member has cleared. Nothing sequences the two writers, so an unconditional
#   `pending` from CI overwrites a legitimate `success`: the required check
#   reverts to pending, `gh pr merge` is rejected by branch protection, nothing
#   re-posts, and the gate stays shut until a human re-runs the producer by hand.
#
#   Every GAIA-Audit stamp step in .github/workflows/code-review-audit.yml calls
#   this before posting `pending`, and stands down when it answers 0 or 2.
#
# Usage
#   .github/audit/audit-success-present.sh <sha> <tree-sha>
#
#     <sha>       The commit the status would be posted to.
#     <tree-sha>  The tree whose clearance we are asking about. The local
#                 producer's success description is "<version> <tree-sha>", so
#                 the tree is the marker's identity: a success naming an OLDER
#                 tree vouches for content that is no longer what would merge and
#                 must NOT stand the gate down.
#
# Exit codes
#   0  A GAIA-Audit `success` IS the live status on <sha>, and its description
#      carries <tree-sha>. Every dispatched member has cleared this exact
#      content; the caller must not overwrite it.
#   1  Definitively NOT live (no GAIA-Audit success for this tree). The caller
#      proceeds to post `pending` as normal.
#   2  Could NOT ask: the status read failed (auth blip, rate limit, network).
#      Callers must NEVER collapse 2 into 1. Posting `pending` over a status we
#      failed to read is precisely the clobber this guard exists to prevent, and
#      it would reintroduce the bug on exactly the flaky runs where it is hardest
#      to diagnose. Standing down instead still fails CLOSED: an absent required
#      check blocks the merge just as a `pending` one does.
#   2  Also returned on a usage error (missing argument), for the same
#      fail-closed reason: an unanswerable question is never "no success live".
#
# Notes
#   - The COMBINED-status endpoint (/commits/<sha>/status) is deliberate: it
#     returns the latest status per context, which is exactly "what the merge
#     gate currently reads". The /statuses endpoint returns every status
#     chronologically and would report a success that a later `pending` has
#     already superseded.
#   - $GITHUB_REPOSITORY is used when set (it always is inside Actions); outside
#     Actions the slug is resolved via `gh repo view`, so the script is runnable
#     by hand for debugging.
#   - Bash 3.2 compatible. Never `cd`s (per .claude/rules/shell-cwd.md).

set -euo pipefail

sha="${1:-}"
tree="${2:-}"

# Fail-closed on a malformed query. An empty tree would make the fixed-string
# match below succeed against anything, standing the gate down on a status that
# vouches for nothing.
if [ -z "$sha" ] || [ -z "$tree" ]; then
  echo "audit-success-present: usage: audit-success-present.sh <sha> <tree-sha>" >&2
  exit 2
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "audit-success-present: gh absent; cannot read the current GAIA-Audit status." >&2
  exit 2
fi

repo="${GITHUB_REPOSITORY:-}"
if [ -z "$repo" ]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
fi
if [ -z "$repo" ]; then
  echo "audit-success-present: repo slug unresolved; cannot read the current GAIA-Audit status." >&2
  exit 2
fi

# A failed read is exit 2, NOT "no success live". This is the whole point of the
# three-state contract.
if ! descriptions="$(gh api "repos/${repo}/commits/${sha}/status" \
  --jq '.statuses[] | select(.context == "GAIA-Audit" and .state == "success") | .description' \
  2>/dev/null)"; then
  echo "audit-success-present: could not read the GAIA-Audit status on ${sha}." >&2
  exit 2
fi

if printf '%s\n' "$descriptions" | grep -qF -- "$tree"; then
  exit 0
fi

exit 1
