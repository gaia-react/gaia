#!/usr/bin/env bash
# spec-reconcile.sh: Reconcile finalized-but-open SPEC ledger rows against git
# ground truth. For every .gaia/local/specs/ledger.json row whose status is
# "ready" (the finalize state), check whether a merged PR exists whose head
# branch is a plan branch naming that SPEC (.gaia/scripts/branch-name-lib.sh);
# if so, flip the row to status "merged" and stamp
# merged_at with that PR's mergedAt.
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
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../ledger-path-lib.sh
. "${_library_directory}/../ledger-path-lib.sh" 2>/dev/null || true
# shellcheck source=../branch-name-lib.sh
. "${_library_directory}/../branch-name-lib.sh" 2>/dev/null || true
# Without the branch-naming library no merged PR can be matched to a SPEC.
type gaia_branch_spec_number >/dev/null 2>&1 || exit 0

# No jq, or not a git tree → nothing to do (checked before resolving main,
# since resolving main needs a git tree too).
command -v jq >/dev/null 2>&1 || exit 0
git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# repo_root names the tree this reconcile runs in; the ledger it reconciles
# is main's, because the state registry declares specs/ main-only. Best-
# effort by contract: an unresolvable main takes the same silent-exit-0 shape
# as the git-tree check above, nothing touched.
specs_directory="$(gaia_resolve_specs_directory "$repo_root" 2>/dev/null)" || exit 0
[ -n "$specs_directory" ] || exit 0
ledger_path="${specs_directory}/ledger.json"

# No ledger → nothing to do.
[ -f "$ledger_path" ] || exit 0

# --- Normalize known-misnamed statuses to canonical (local, no network) ------
# Pre-guard ledgers can carry an off-vocabulary status (a hand-edited or
# backfilled "shipped", say). Rename known aliases to their canonical value
# through the guarded ledger-update.sh chokepoint, so a stray label self-heals
# on the next housekeeping pass. Runs before the network reconcile and is
# independent of it. An unrecognized off-vocabulary status is logged, never
# guessed (its lifecycle position is not safely inferable).
canonicalize_status() {
  case "$1" in
    shipped) printf 'merged' ;;
    *) printf '' ;;
  esac
}

off_vocabulary_ids="$(jq -r '
  .specs[]
  | select((.status // "") as $row_status
      | ["draft","ready","merged","abandoned"] | index($row_status) | not)
  | .id
' "$ledger_path" 2>/dev/null || true)"

if [ -n "$off_vocabulary_ids" ]; then
  while IFS= read -r off_vocabulary_id; do
    [ -n "$off_vocabulary_id" ] || continue
    off_vocabulary_status="$(jq -r --arg id "$off_vocabulary_id" \
      '.specs[] | select(.id == $id) | .status // "null"' "$ledger_path" 2>/dev/null || true)"
    canonical_status="$(canonicalize_status "$off_vocabulary_status")"
    if [ -n "$canonical_status" ]; then
      patch="$(jq -nc --arg canonical_status "$canonical_status" '{status: $canonical_status}')"
      if bash "${_library_directory}/ledger-update.sh" "$repo_root" "$off_vocabulary_id" "$patch" >/dev/null 2>&1; then
        printf 'normalized %s: %s -> %s\n' "$off_vocabulary_id" "$off_vocabulary_status" "$canonical_status"
      fi
    else
      printf 'spec-reconcile: %s has unrecognized status %s; left as-is\n' "$off_vocabulary_id" "$off_vocabulary_status" >&2
    fi
  done <<EOF
$off_vocabulary_ids
EOF
fi

# Candidate rows (local, cheap): finalized but not yet recorded as merged.
candidates="$(jq -r '
  .specs[] | select(.status == "ready") | .id
' "$ledger_path" 2>/dev/null || true)"
[ -n "$candidates" ] || exit 0

# Only now reach for the network. No gh, no remote, or a failed list → bail.
command -v gh >/dev/null 2>&1 || exit 0
prs_json="$(gh pr list --state merged --limit 200 \
  --json number,headRefName,mergedAt 2>/dev/null || true)"
[ -n "$prs_json" ] || exit 0

# Projected once, outside the candidate loop: the list is the same for every
# candidate, and re-parsing 200 pull requests per `ready` row is the whole of
# what made this scan cost seconds.
prs_rows="$(printf '%s' "$prs_json" \
  | jq -r '.[] | "\(.mergedAt)\t\(.number)\t\(.headRefName)"' 2>/dev/null || true)"

while IFS= read -r spec_id; do
  [ -n "$spec_id" ] || continue
  spec_number="$(printf '%s' "$spec_id" | sed -nE 's|^SPEC-0*([0-9]+)$|\1|p')"
  [ -n "$spec_number" ] || continue

  # Match a merged PR whose head branch names SPEC <spec_number>, read through the same
  # library the allocator uses, so every spelling GAIA mints (the worktree one
  # included) matches. Latest merge wins, so merged_at reflects when the work
  # fully landed; ISO-8601 timestamps sort chronologically as strings.
  # The test is a builtin prefilter so a head branch that cannot name a SPEC
  # skips the subshells of the library; almost none of a repository's merged
  # pull requests are plan branches. The sibling call sites in spec-allocator.sh
  # and spec-renumber.sh guard the same loop the same way.
  # `%s\n`, not `%s`: the command substitution above stripped jq's trailing
  # newline, and `read` drops a final line that has none, which would silently
  # lose the newest merge.
  match="$(printf '%s\n' "$prs_rows" \
    | while IFS='	' read -r listed_merged_at listed_pr_number head; do
      if [[ "$head" == *spec-* ]]; then
        [ "$(gaia_branch_spec_number "$head")" = "$spec_number" ] && printf '%s\t%s\n' "$listed_merged_at" "$listed_pr_number"
      fi
    done | LC_ALL=C sort | tail -n 1 || true)"
  [ -n "$match" ] || continue

  merged_at="${match%%	*}"
  pr_number="${match##*	}"
  patch="$(jq -nc --arg timestamp "$merged_at" '{status: "merged", merged_at: $timestamp}')"
  if bash "${_library_directory}/ledger-update.sh" "$repo_root" "$spec_id" "$patch" >/dev/null 2>&1; then
    printf 'reconciled %s -> merged (PR #%s, %s)\n' "$spec_id" "$pr_number" "$merged_at"
  fi
done <<EOF
$candidates
EOF

exit 0
