#!/usr/bin/env bash
# verify-required-checks.sh: detect drift between the checks this repo
# deliberately requires to merge and the live GitHub ruleset's
# required_status_checks list (#807). The ruleset lives GitHub-side and can
# drift silently: a check can report red without blocking a merge if it was
# never added to the ruleset, or can quietly stop blocking if removed from
# it. This script makes that drift visible; it never writes to the live
# ruleset -- registering a required check stays a deliberate, maintainer-run
# step, the same ask-first cutover read-audit-ci-config.sh documents for
# GAIA-Audit.
#
# Usage:
#   verify-required-checks.sh [--repo <owner/name>] [--branch <branch>]
#                              [--ruleset-contexts <file-or-->]
#                              [--workflows-dir <dir>]
#
#   --repo               defaults to `gh repo view --json nameWithOwner`.
#   --branch             defaults to the remote HEAD branch, else `main`.
#   --ruleset-contexts   test injection: read live-required contexts from
#                        this file (one context per line) instead of
#                        calling `gh api`. `-` reads stdin.
#   --workflows-dir      defaults to `.github/workflows`; test injection
#                        point for a fixture directory.
#
# Exit codes:
#   0  every declared-required context is confirmed in the live ruleset.
#   1  at least one declared-required context is missing from the live
#      ruleset, the exact drift class #807 exists to catch.
#   2  usage error, or the live ruleset could not be read (gh api failed).
#
# DO NOT add `set -e` (matches audit-noop-detect.sh): the missing/advisory
# loops below rely on grep/comparison exit status without aborting the script.
set -uo pipefail

# The checks this repo has deliberately decided must block a merge. Keep
# this list and its rationale comments in sync with any future decision to
# promote or demote a check; that decision is what this script exists to
# guard, not to make on its own.
REQUIRED_CONTEXTS=(
  "GAIA-Audit"                        # custom status posted by the code-audit gate itself
  "bats (.github/audit)"              # .github/workflows/audit-ci-tests.yml
  "Run Chromatic"                     # .github/workflows/chromatic.yml
  "Unanswered newly-shipping files"   # .github/workflows/distribution-audit-pr.yml (SPEC-044)
  "Vitest and Playwright"             # .github/workflows/tests.yml
)

repo=""
branch=""
ruleset_contexts_src=""
workflows_dir=".github/workflows"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--branch|--ruleset-contexts|--workflows-dir)
      if [ $# -lt 2 ]; then
        echo "verify-required-checks: $1 needs a value" >&2
        exit 2
      fi
      case "$1" in
        --repo)             repo="$2" ;;
        --branch)           branch="$2" ;;
        --ruleset-contexts) ruleset_contexts_src="$2" ;;
        --workflows-dir)    workflows_dir="$2" ;;
      esac
      shift 2
      ;;
    *)
      echo "verify-required-checks: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$repo" ]; then
  repo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
fi
if [ -z "$repo" ]; then
  echo "verify-required-checks: could not resolve repo (pass --repo)" >&2
  exit 2
fi

if [ -z "$branch" ]; then
  branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##')
  [ -n "$branch" ] || branch="main"
fi

if [ -n "$ruleset_contexts_src" ]; then
  if [ "$ruleset_contexts_src" = "-" ]; then
    ruleset_contexts=$(cat)
  else
    ruleset_contexts=$(cat "$ruleset_contexts_src")
  fi
else
  if ! ruleset_contexts=$(gh api "repos/${repo}/rules/branches/${branch}" \
    --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]?.context' \
    2>/dev/null); then
    echo "verify-required-checks: could not read the live ruleset for ${repo} branch ${branch} (gh api failed: auth, token, rate limit, network, or outage). Refusing to report drift from data gh could not supply." >&2
    exit 2
  fi
fi

missing=()
for ctx in ${REQUIRED_CONTEXTS[@]+"${REQUIRED_CONTEXTS[@]}"}; do
  if ! printf '%s\n' "$ruleset_contexts" | grep -qxF -- "$ctx"; then
    missing+=("$ctx")
  fi
done

# Advisory scan: every job's display name across the workflows directory, a
# job-id line (2-space indent) immediately followed by its `name:` line, the
# convention every job in this repo already follows. This is intentionally
# broad (it does not attempt to distinguish pull_request-triggered jobs from
# tag-push or workflow_dispatch-only ones): the point is a short, reviewable
# list a human scans, not an automated required/advisory verdict.
advisory=()
if [ -d "$workflows_dir" ]; then
  while IFS= read -r job_name; do
    [ -n "$job_name" ] || continue
    is_required=0
    for ctx in ${REQUIRED_CONTEXTS[@]+"${REQUIRED_CONTEXTS[@]}"}; do
      if [ "$job_name" = "$ctx" ]; then
        is_required=1
        break
      fi
    done
    [ "$is_required" -eq 0 ] && advisory+=("$job_name")
  done < <(
    for f in "$workflows_dir"/*.yml "$workflows_dir"/*.yaml; do
      [ -f "$f" ] || continue
      awk '
        /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job=1; next }
        in_job && /^    name:/ { sub(/^    name:[[:space:]]*/, ""); print; in_job=0; next }
        { in_job=0 }
      ' "$f"
    done | sort -u
  )
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "MISSING from the live ruleset's required_status_checks (declared required in-repo, not enforced live):"
  printf '  - %s\n' ${missing[@]+"${missing[@]}"}
fi

if [ "${#advisory[@]}" -gt 0 ]; then
  echo "Advisory (check-producing job names found in $workflows_dir, not in the declared-required list; review before promoting):"
  printf '  - %s\n' ${advisory[@]+"${advisory[@]}"}
fi

if [ "${#missing[@]}" -gt 0 ]; then
  exit 1
fi

echo "verify-required-checks: all declared-required contexts confirmed in the live ruleset."
exit 0
