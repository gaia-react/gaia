#!/usr/bin/env bash
# spec-reconcile.sh: Reconcile finalized-but-open SPEC ledger rows against git
# ground truth. For every .gaia/specs.json row whose status is "specified" (the
# finalize state) or the legacy "in-progress", check whether a merged PR exists
# whose head branch matches spec-NNN-* ; if so, flip the row to status "merged"
# and stamp merged_at with that PR's mergedAt.
#
# Why this exists: the allocator's in_progress signal is draft-only and is set
# at both ends by the authoring session, so it never goes stale. But the merged
# transition happens later, in a different session, often via the github.com
# merge button, so nothing in the authoring flow can set it. This pass derives
# it from git on demand and is the housekeeping counterpart to the allocator.
#
# Best-effort and fail-open by contract: a missing gh / jq / ledger / network,
# an unmatched SPEC, or a ledger-update failure never blocks a caller. The only
# observable effect is the ledger rows it can confidently advance. It prints one
# line per reconciled SPEC to stdout.
#
# Usage:
#   spec-reconcile.sh <repo_root>
#
# Exit: always 0 (advisory). The PR scan is capped at the 200 most recent merged
# PRs; a SPEC whose PR is older than that is left as-is (logged to stderr), it is
# already shipped and the stale ledger label is cosmetic, not a correctness gate.
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: spec-reconcile.sh <repo_root>" >&2
  exit 0
fi

repo_root="$1"
ledger_path="${repo_root%/}/.gaia/specs.json"
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# No ledger, no jq, or not a git tree → nothing to do.
[ -f "$ledger_path" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Candidate rows (local, cheap): finalized but not yet recorded as merged.
candidates="$(jq -r '
  .specs[] | select(.status == "specified" or .status == "in-progress") | .id
' "$ledger_path" 2>/dev/null || true)"
[ -n "$candidates" ] || exit 0

# Only now reach for the network. No gh, no remote, or a failed list → bail.
command -v gh >/dev/null 2>&1 || exit 0
prs_json="$(gh pr list --state merged --limit 200 \
  --json number,headRefName,mergedAt 2>/dev/null || true)"
[ -n "$prs_json" ] || exit 0

while IFS= read -r spec_id; do
  [ -n "$spec_id" ] || continue
  n="$(printf '%s' "$spec_id" | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p')"
  [ -n "$n" ] || continue

  # Match a merged PR whose head branch is spec-<n>-... (any leading path, zero
  # padding tolerated), mirroring the allocator's branch-marker regex. Latest
  # merge wins, so merged_at reflects when the work fully landed.
  match="$(printf '%s' "$prs_json" | jq -r --arg n "$n" '
    [ .[] | select(.headRefName | test("(^|/)spec-0*" + $n + "(-|$)")) ]
    | sort_by(.mergedAt) | last
    | if . == null then empty else "\(.number)\t\(.mergedAt)" end
  ' 2>/dev/null || true)"
  [ -n "$match" ] || continue

  pr_num="${match%%	*}"
  merged_at="${match##*	}"
  patch="$(jq -nc --arg ts "$merged_at" '{status: "merged", merged_at: $ts}')"
  if bash "${_lib_dir}/ledger-update.sh" "$repo_root" "$spec_id" "$patch" >/dev/null 2>&1; then
    printf 'reconciled %s -> merged (PR #%s, %s)\n' "$spec_id" "$pr_num" "$merged_at"
  fi
done <<EOF
$candidates
EOF

exit 0
