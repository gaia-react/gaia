#!/usr/bin/env bash
# gate-pending-members.sh: which dispatched Code Audit Team members can CI not clear?
#
# Purpose
#   The single gate every GAIA-Audit success-status POST in code-review-audit.yml
#   consults before stamping `state=success`. CI runs exactly ONE auditor: the
#   workflow's audit step dispatches code-audit-frontend by name. Every OTHER
#   member the roster resolver dispatches for the PR's diff is local-only in CI
#   -- CI cannot run it, and its marker lives under gitignored .gaia/local/, so
#   CI never sees a clearance for it. Stamping success on the frontend's
#   clearance alone defeats the Code Audit Team AND-aggregator and unblocks the
#   github.com merge button for a diff a required auditor never read.
#
#   This script names those members so the workflow can post `pending` instead
#   and let the local, member-aware producer (.claude/hooks/post-audit-status.sh)
#   post success once every dispatched member's marker exists.
#
# Usage
#   gate-pending-members.sh --base <ref>
#     --base <ref>  The PR's BASE sha. Pass the full-PR base
#                   (github.event.pull_request.base.sha), NEVER the incremental
#                   audit base -- see "Full-PR scope" below.
#     --help | -h   Print this usage and exit.
#
# Output contract
#   A single line on stdout: the dispatched members CI cannot clear, space-
#   separated, in the resolver's sorted order. EMPTY stdout means CI's own
#   frontend clearance is sufficient for this diff. Exit code is 0 on EVERY path
#   so callers can consume stdout unconditionally.
#
# Full-PR scope (load-bearing)
#   Membership is a function of the WHOLE PR diff, never the review increment.
#   The incremental audit base (.github/audit/resolve-audit-base.sh) advances to
#   the newest ancestor carrying a clean GAIA-Audit trailer/status, and that
#   trailer is stamped by the FRONTEND agent alone -- it is not member-aware. So
#   an increment measured from it can exclude a maintainer-owned file that a
#   co-dispatched member never cleared, shrinking the member set to {frontend}
#   and re-opening the very bypass this gate closes. The incremental base is
#   correct for SCOPING THE REVIEW; it is wrong for DECIDING WHO MUST CLEAR.
#   Both local consumers already resolve over full PR scope
#   (post-audit-status.sh, pr-merge-audit-check.sh); this keeps CI in agreement.
#
# Fail-open
#   An absent or unusable resolver yields EMPTY stdout (no members pending) and a
#   stderr note, matching the local producer's documented fallback: a broken
#   resolver must not brick the merge path. The note is what tells an operator a
#   disarmed gate apart from a genuinely clean one -- never fail open silently.
#
# Bash 3.2 compatible (macOS default). No `cd` (per .claude/rules/shell-cwd.md);
# the repo root is resolved via git rev-parse.
#
# References
#   Dispatch resolver: .gaia/scripts/resolve-audit-members.sh
#   Local producer:    .claude/hooks/post-audit-status.sh
#   Local merge gate:  .claude/hooks/pr-merge-audit-check.sh

set -euo pipefail

# The one auditor CI runs. Coupled by construction to the audit step's prompt in
# code-review-audit.yml, which dispatches this agent by name; CI has no path to
# run any other member, so this is a statement of CI's actual capability, not a
# roster assumption. A member added to the roster is correctly reported pending.
CI_MEMBER="code-audit-frontend"

BASE=""

print_usage() {
  cat <<'USAGE'
Usage: gate-pending-members.sh --base <ref>
  Emits the dispatched Code Audit Team members CI cannot clear (space-separated,
  one line). Empty output = CI's frontend clearance suffices. Exit 0 always.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      if [ "$#" -lt 2 ]; then
        echo "gate-pending-members: --base requires a <ref> argument" >&2
        exit 0
      fi
      BASE="$2"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "gate-pending-members: unrecognized argument '$1'" >&2
      shift
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$repo_root" ]; then
  echo "gate-pending-members: not in a git repo; failing open (no members pending)" >&2
  exit 0
fi

resolver="${repo_root}/.gaia/scripts/resolve-audit-members.sh"
# Test readability, not the exec bit: the call below is `bash <path>`, which needs
# only read. An `[ -x ]` guard would fail open silently on a checkout that lost
# the mode bit.
if [ ! -r "$resolver" ]; then
  echo "gate-pending-members: resolver not readable at ${resolver}; failing open (no members pending)" >&2
  exit 0
fi

members=""
if [ -n "$BASE" ]; then
  members="$(bash "$resolver" --base "$BASE" 2>/dev/null)" || {
    echo "gate-pending-members: resolver failed; failing open (no members pending)" >&2
    exit 0
  }
else
  members="$(bash "$resolver" 2>/dev/null)" || {
    echo "gate-pending-members: resolver failed; failing open (no members pending)" >&2
    exit 0
  }
fi

# Drop blanks and the one member CI runs itself; space-join the rest. awk always
# exits 0, so a fully-filtered list is an empty line, never a non-zero status.
printf '%s\n' "$members" \
  | awk -v ci="$CI_MEMBER" 'NF && $0 != ci { printf "%s%s", sep, $0; sep=" " } END { printf "\n" }'
