#!/usr/bin/env bash
# plan-reconcile.sh: flip PLAN-NNN plans-ledger rows to "merged". The plan-side
# counterpart to spec-reconcile.sh, in two modes. Best-effort, fail-open,
# ALWAYS exit 0. Idempotent.
#
# Single-id form: plan-reconcile.sh <repo_root> <plan_id> [<pr_number>]
#   Called by the orchestrator's post-merge close once it has confirmed the
#   pull request MERGED, so there is NO gh/PR scan: the merge is already
#   confirmed and the plan_id is known. It decouples the status advance from
#   the folder delete, so a PLAN-NNN row reaches "merged" even when
#   plan-archive.sh gates the delete off. The optional <pr_number>, a positive
#   integer, is stamped on the row as a JSON number; any other third argument
#   is reported on stderr and the row is stamped without it. With exactly two
#   arguments the behavior is the long-standing one (status + merged_at).
#
# Scan form: plan-reconcile.sh <repo_root>
#   The backstop for merges that bypassed the orchestrator (the github.com
#   button, another session), run by the pre-flight sweep in
#   .claude/skills/gaia/references/spec/lifecycle.md. Candidates are rows with
#   status "ready", or "merged" with no pr_number. Each is matched to the
#   newest merged PR (the 200 most recent, one gh call) whose head branch
#   names that plan (.gaia/scripts/branch-name-lib.sh) and patched with
#   status, the PR's mergedAt and its pr_number. A missing gh, jq, network or
#   unmatched row leaves the ledger as it was. The 200-PR window is a backstop
#   only: the warm path stamps pr_number at close.
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: plan-reconcile.sh <repo_root> [<plan_id> [<pr_number>]]" >&2
  exit 0
fi
repo_root="${1%/}"
_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$#" -eq 1 ]; then
  # --- Scan mode: reconcile candidate rows against merged pull requests ----
  # shellcheck source=../ledger-path-lib.sh
  . "${_library_directory}/../ledger-path-lib.sh" 2>/dev/null || true
  # shellcheck source=../branch-name-lib.sh
  . "${_library_directory}/../branch-name-lib.sh" 2>/dev/null || true
  # Without the branch-naming library no merged PR can be matched to a plan.
  type gaia_branch_plan_number >/dev/null 2>&1 || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  type gaia_resolve_plans_directory >/dev/null 2>&1 || exit 0
  plans_directory="$(gaia_resolve_plans_directory "$repo_root" 2>/dev/null)" || exit 0
  [ -n "$plans_directory" ] || exit 0
  ledger_path="${plans_directory}/ledger.json"
  [ -f "$ledger_path" ] || exit 0

  # Candidate rows (local, cheap): not yet merged, or merged without the PR number.
  candidates="$(jq -r '
    .plans[] | select(.status == "ready" or (.status == "merged" and ((.pr_number // "") == ""))) | .id
  ' "$ledger_path" 2>/dev/null || true)"
  [ -n "$candidates" ] || exit 0

  # Only now reach for the network. No gh, no remote, or a failed list: bail.
  command -v gh >/dev/null 2>&1 || exit 0
  prs_json="$(cd "$repo_root" 2>/dev/null && gh pr list --state merged --limit 200 \
    --json number,headRefName,mergedAt 2>/dev/null || true)"
  [ -n "$prs_json" ] || exit 0

  # Projected once, outside the candidate loop: the list is the same for
  # every candidate.
  prs_rows="$(printf '%s' "$prs_json" \
    | jq -r '.[] | "\(.mergedAt)\t\(.number)\t\(.headRefName)"' 2>/dev/null || true)"

  while IFS= read -r candidate_id; do
    [ -n "$candidate_id" ] || continue
    candidate_number="$(printf '%s' "$candidate_id" | sed -nE 's|^PLAN-0*([0-9]+)$|\1|p')"
    [ -n "$candidate_number" ] || continue

    # Latest merge wins, so merged_at reflects when the work fully landed;
    # ISO-8601 timestamps sort chronologically as strings. The test is a
    # builtin prefilter so a head branch that cannot name a plan skips the
    # subshells of the library. `%s\n`, not `%s`: the command substitution
    # above stripped jq's trailing newline, and `read` drops a final line
    # that has none, which would silently lose the newest merge.
    match="$(printf '%s\n' "$prs_rows" \
      | while IFS='	' read -r listed_merged_at listed_pr_number head; do
        if [[ "$head" == *plan-* ]]; then
          [ "$(gaia_branch_plan_number "$head")" = "$candidate_number" ] && printf '%s\t%s\n' "$listed_merged_at" "$listed_pr_number"
        fi
      done | LC_ALL=C sort | tail -n 1 || true)"
    [ -n "$match" ] || continue

    merged_at="${match%%	*}"
    matched_pr_number="${match##*	}"
    patch="$(jq -nc --arg timestamp "$merged_at" --argjson number "$matched_pr_number" \
      '{status: "merged", merged_at: $timestamp, pr_number: $number}' 2>/dev/null || true)"
    [ -n "$patch" ] || continue
    if bash "${_library_directory}/plan-ledger-update.sh" "$repo_root" "$candidate_id" "$patch" >/dev/null 2>&1; then
      printf 'reconciled %s -> merged (PR #%s, %s)\n' "$candidate_id" "$matched_pr_number" "$merged_at"
    fi
  done <<SCAN_CANDIDATES
$candidates
SCAN_CANDIDATES
  exit 0
fi

plan_id="$2"

# Only reconcile a real PLAN-NNN id (a free-form slug has no plans-ledger row).
case "$plan_id" in
  PLAN-*)
    plan_number="${plan_id#PLAN-}"
    case "$plan_number" in ''|*[!0-9]*) echo "plan-reconcile: $plan_id not PLAN-NNN; nothing to do" >&2; exit 0 ;; esac
    ;;
  *) echo "plan-reconcile: $plan_id not PLAN-NNN; nothing to do" >&2; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
confirmed_pr_number=""
if [ "$#" -ge 3 ]; then
  # Positive integers only: a leading 1-9, then digits.
  case "$3" in
    '' | [!1-9]* | *[!0-9]*)
      echo "plan-reconcile: $3 is not a PR number; stamped without pr_number" >&2
      ;;
    *) confirmed_pr_number="$3" ;;
  esac
fi
if [ -n "$confirmed_pr_number" ]; then
  patch="$(jq -nc --arg timestamp "$now" --argjson number "$confirmed_pr_number" \
    '{status: "merged", merged_at: $timestamp, pr_number: $number}')"
else
  patch="$(jq -nc --arg timestamp "$now" '{status: "merged", merged_at: $timestamp}')"
fi
if bash "${_library_directory}/plan-ledger-update.sh" "$repo_root" "$plan_id" "$patch" >/dev/null 2>&1; then
  printf 'reconciled %s -> merged\n' "$plan_id"
else
  echo "plan-reconcile: could not advance $plan_id (missing ledger/row or lock timeout); left as-is" >&2
fi
exit 0
