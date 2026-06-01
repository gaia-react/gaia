#!/usr/bin/env bash
# resolve-check-base.sh — resolve the incremental "since last green" base for a
# named CI check.
#
# Purpose
#   Expensive required checks (Vitest+Playwright, etc.) re-run on every push to
#   a PR even when the newest commits changed nothing they can act on. This
#   helper resolves the most recent ancestor of HEAD on which the named check
#   already concluded SUCCESS, so the caller can diff only <base>...HEAD and
#   skip the check when that delta touches no relevant files. Everything up to
#   that commit was already green, so re-running it is wasted work.
#
#   When no green ancestor exists — first run of a PR, every prior run
#   failed/cancelled (those do not anchor), or the API is unreachable — the
#   helper emits the main ref so the caller falls back to a full-scope diff. It
#   can never skip un-passed code: a commit with no green signal for this check
#   is never chosen as a base.
#
# Invocation
#   .github/audit/resolve-check-base.sh "<check-context-name>"
#
#   $1 is the check context name, matched against check-run names exactly
#   (e.g. "Vitest and Playwright"). Reads HEAD's ancestry and (when GH_TOKEN +
#   gh + GITHUB_REPOSITORY are available) the GitHub Checks API.
#
# Output (stdout, single line; suitable for `base...HEAD` diffs)
#   <40-hex-sha>   — resolved incremental base (a green ancestor of HEAD)
#   origin/main    — fallback: diff the full PR/branch scope
#   (or origin/<base-ref> / main when origin/main is unavailable)
#
# Exit code
#   0 always. Callers consume the single stdout line.
#
# Why "last GREEN", not "last run"
#   Only a SUCCESS conclusion anchors a base. A failed/cancelled run on a
#   commit leaves no green signal, so the walk continues past it — a later
#   prose-only commit then still diffs back to the last truly-green tree and
#   re-runs the check, catching the broken code in between.
#
# Why bound the walk to merge-base..HEAD
#   The base must be one of THIS PR's commits (or the divergence point as the
#   floor). Walking into main's own history could anchor on a deeper main
#   commit and shrink the diff scope below the PR's own changes. The merge-base
#   bound prevents that; reaching the floor yields the main ref.
#
# Conventions
#   - Bash 3.2 compatible (macOS default). No associative arrays / mapfile.
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Uses git -C "$repo_root".
#   - Sibling of resolve-audit-base.sh; mirrors its structure and fallback
#     contract. Kept separate because the audit's base is version-aware
#     (a .gaia/VERSION bump invalidates it) and a plain last-green check is not.

set -euo pipefail

# Defensive cap on the ancestry walk (PRs rarely exceed this many commits; the
# merge-base bound usually keeps the list far shorter).
MAX_WALK=50

check_name="${1:-}"

# -----------------------------------------------------------------------------
# Resolve repo root
# -----------------------------------------------------------------------------

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  # Defensive: not in a git repo. Full scope; the caller's git will error
  # loudly on the broken environment.
  printf 'origin/main\n'
  exit 0
fi

# -----------------------------------------------------------------------------
# Resolve a "main ref" — used both for the fallback output and to bound the
# ancestry walk via merge-base.
# -----------------------------------------------------------------------------

resolve_main_ref() {
  if git -C "$repo_root" rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
    printf 'origin/main'
    return 0
  fi
  if [ -n "${GITHUB_BASE_REF:-}" ] \
    && git -C "$repo_root" rev-parse --verify --quiet "origin/${GITHUB_BASE_REF}" >/dev/null 2>&1; then
    printf 'origin/%s' "$GITHUB_BASE_REF"
    return 0
  fi
  if git -C "$repo_root" rev-parse --verify --quiet main >/dev/null 2>&1; then
    printf 'main'
    return 0
  fi
  printf 'origin/main'
}
main_ref="$(resolve_main_ref)"

# -----------------------------------------------------------------------------
# A check name is required, and the Checks API is the only signal — without
# gh + GH_TOKEN + repo slug no commit can be confirmed green, so fall back to
# full scope.
# -----------------------------------------------------------------------------

repo="${GITHUB_REPOSITORY:-}"
if [ -z "$check_name" ] \
  || [ -z "${GH_TOKEN:-}" ] \
  || ! command -v gh >/dev/null 2>&1 \
  || [ -z "$repo" ]; then
  printf '%s\n' "$main_ref"
  exit 0
fi

# -----------------------------------------------------------------------------
# Build the candidate list (PR commits, newest first).
# -----------------------------------------------------------------------------

head_sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
if [ -z "$head_sha" ]; then
  printf '%s\n' "$main_ref"
  exit 0
fi

merge_base=$(git -C "$repo_root" merge-base "$main_ref" HEAD 2>/dev/null || true)
if [ -n "$merge_base" ]; then
  candidates=$(git -C "$repo_root" rev-list --max-count="$MAX_WALK" "${merge_base}..HEAD" 2>/dev/null || true)
else
  candidates=$(git -C "$repo_root" rev-list --max-count="$MAX_WALK" HEAD 2>/dev/null || true)
fi

# -----------------------------------------------------------------------------
# green_check_count <sha> → number of check-runs on <sha> named "$check_name"
# whose conclusion is "success". 0 (or empty → treated as 0) means no green
# signal for this check on that commit. per_page=100 avoids pagination for the
# handful of check-runs a commit carries.
# -----------------------------------------------------------------------------

green_check_count() {
  local sha="$1" filter out
  # check_name is controlled by the caller (a workflow's own job name) and
  # carries no quotes; embedding it in the jq string literal is safe.
  filter="[.check_runs[] | select(.name == \"${check_name}\" and .conclusion == \"success\")] | length"
  out=$(gh api "repos/${repo}/commits/${sha}/check-runs?per_page=100" \
    --jq "$filter" 2>/dev/null || true)
  case "$out" in
    '' | *[!0-9]*) printf '0' ;;
    *) printf '%s' "$out" ;;
  esac
}

# -----------------------------------------------------------------------------
# Walk newest → oldest; first commit with a green check for this context wins.
# -----------------------------------------------------------------------------

for sha in $candidates; do
  # HEAD itself can't be the base (an empty diff); a green check on HEAD would
  # have skipped this run upstream anyway.
  [ "$sha" = "$head_sha" ] && continue

  if [ "$(green_check_count "$sha")" -gt 0 ]; then
    printf '%s\n' "$sha"
    exit 0
  fi
done

# No green ancestor in range → full scope.
printf '%s\n' "$main_ref"
exit 0
