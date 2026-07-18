#!/usr/bin/env bash
# audit-success-present.sh, is a GAIA-Audit success already LIVE for this
# frontend digest?
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
#   Every step in .github/workflows/code-review-audit.yml that POSTs `pending`
#   calls this first -- the three stamp steps AND the local-mode stand-down --
#   and each posts `pending` ONLY on a definitive 1, standing down on every other
#   exit. See "Exit codes" below for why the test is `-ne 1` and not `-eq 2`.
#
# Usage
#   .github/audit/audit-success-present.sh <sha> <frontend-digest>
#
#     <sha>              The commit the status would be posted to.
#     <frontend-digest>  The frontend member's content digest (C1) whose
#                 clearance we are asking about. The local producer's success
#                 description is "<version> <frontend-digest> <tree>", so the
#                 digest is the marker's identity: a success naming a
#                 DIFFERENT digest vouches for content the frontend member
#                 owns that is no longer what would merge and must NOT stand
#                 the gate down. An out-of-glob change (a CHANGELOG line, a
#                 wiki edit) leaves the digest unchanged, so a live success
#                 still stands the gate down across it.
#
# Exit codes
#   0  A GAIA-Audit `success` IS the live status on <sha>, and its description
#      carries <frontend-digest>. Every dispatched member has cleared this
#      exact content; the caller must not overwrite it.
#   1  Definitively NOT live (no GAIA-Audit success for this digest). The
#      caller proceeds to post `pending` as normal.
#   2  Could NOT ask. Callers must NEVER collapse 2 into 1. Posting `pending`
#      over a status we failed to read is precisely the clobber this guard exists
#      to prevent, and it would reintroduce the bug on exactly the flaky runs
#      where it is hardest to diagnose. Standing down instead still fails CLOSED:
#      an absent required check blocks the merge just as a `pending` one does.
#
#      There are exactly FOUR ways to be unable to ask, and all four exit 2. This
#      list is exhaustive by design: a door that is not named here is a door the
#      next reader does not know to keep shut, and each has a regression lock
#      pinning it to 2.
#
#        - A usage error (either argument missing). An empty digest would make
#          the match below succeed against anything, standing the gate down on
#          a status that vouches for nothing.
#        - `gh` is not installed, so the status cannot be read at all.
#        - The repo slug does not resolve: $GITHUB_REPOSITORY is unset (i.e. we
#          are outside Actions) AND the `gh repo view` fallback yields nothing, so
#          there is no repo to query.
#        - The status read itself failed (auth blip, rate limit, network).
#
#   Test for a definitive 1, never for "not 0 and not 2". The exit space is open:
#   the INVOCATION can fail outside this contract -- most importantly 127 when
#   this file is absent or unreadable, which is even more "could not ask" than a
#   2 -- and a caller that enumerates the stand-down codes lets every unenumerated
#   one fall through and POST `pending` over a live success. That is the same
#   collapse the 2 contract forbids, arriving by a different door, and it is
#   loudest exactly when this guard is broken or missing. Inverting the test makes
#   standing down the default and the POST the exception.
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
digest="${2:-}"

# Fail-closed on a malformed query. An empty digest would make the fixed-string
# match below succeed against anything, standing the gate down on a status that
# vouches for nothing.
if [ -z "$sha" ] || [ -z "$digest" ]; then
  echo "audit-success-present: usage: audit-success-present.sh <sha> <frontend-digest>" >&2
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

if grep -qF -- "$digest" <<<"$descriptions"; then
  exit 0
fi

exit 1
