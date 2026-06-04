#!/usr/bin/env bash
# resolve-audit-base.sh: resolve the incremental review base for the
# code-review-audit agent.
#
# Purpose
#   The audit reviews the diff from a "base" commit to HEAD. The base is
#   the most recent ancestor of HEAD that previously passed a CLEAN audit
#   under the CURRENT agent version, proven by either a GAIA-Audit commit
#   trailer (locally-stamped) or a GAIA-Audit commit status (CI-stamped).
#   Everything up to that commit was already cleared, so reviewing only
#   <base>..HEAD is correct and far cheaper than re-reviewing the whole
#   origin/main..HEAD diff on every push to an open PR.
#
#   When no usable ancestor exists, first audit of a PR, every prior run
#   cancelled or failed (those stamp nothing), a .gaia/VERSION bump
#   invalidated older audits, or the version file is missing; the helper
#   emits the main ref so the caller falls back to a full-scope review. It
#   can never skip uncleared code: an uncleared commit carries no signal to
#   anchor on.
#
# Invocation
#   .github/audit/resolve-audit-base.sh
#
#   Argument-less. Reads .gaia/VERSION, HEAD's ancestry, commit trailers,
#   and (when GH_TOKEN + gh are available) the GitHub Commit Status API.
#
# Output (stdout, single line; suitable for `base...HEAD` diffs)
#   <40-hex-sha>: resolved incremental base (an audited PR ancestor)
#   origin/main: fallback: review the full PR diff
#   (or origin/<base-ref> / main when origin/main is unavailable)
#
# Exit code
#   0 always. Callers consume the single stdout line.
#
# Why version-match (not tree-match) gates a base
#   A commit is a usable base when its audit signal's <version> equals the
#   current .gaia/VERSION. The signal's tree-sha always equals the commit's
#   own tree by construction (an amend stamp carries the audited tree; an
#   empty-commit stamp carries the parent's audited tree, which is the empty
#   commit's own tree), so re-checking it adds nothing here. A version
#   mismatch means the ruleset changed since that audit, so code cleared
#   under the old version may now have findings; that commit is NOT a safe
#   base, and the walk continues, ultimately falling back to a full
#   re-audit under the new ruleset.
#
# Why bound the walk to merge-base..HEAD
#   The base must be one of THIS PR's commits (or the divergence point as
#   the floor). Walking into main's own history could pick a deeper main
#   commit and pull already-merged, unrelated changes into this PR's review
#   scope. The merge-base bound prevents that; reaching the floor yields the
#   main ref, i.e. the same scope as origin/main...HEAD.
#
# Conventions
#   - Bash 3.2 compatible (macOS default). No associative arrays / mapfile.
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Uses git -C "$repo_root".
#   - Mirrors the frozen trailer regex + status-parse logic in
#     .github/audit/check-trailer.sh.

set -euo pipefail

# Defensive cap on the ancestry walk (PRs rarely exceed this many commits;
# the merge-base bound usually keeps the list far shorter).
MAX_WALK=50

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
# Resolve a "main ref": used both for the fallback output and to bound the
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
  # Last resort: emit origin/main anyway (matches the existing workflow's
  # assumption; the caller's diff errors loudly if it truly can't resolve).
  printf 'origin/main'
}
main_ref="$(resolve_main_ref)"

# -----------------------------------------------------------------------------
# Read .gaia/VERSION: missing/empty means no base can be validated.
# -----------------------------------------------------------------------------

version_file="${repo_root}/.gaia/VERSION"
cur_version=""
if [ -f "$version_file" ]; then
  cur_version=$(tr -d '\r' < "$version_file" | awk 'NF{print; exit}')
  cur_version="${cur_version#"${cur_version%%[![:space:]]*}"}"
  cur_version="${cur_version%"${cur_version##*[![:space:]]}"}"
fi
if [ -z "$cur_version" ]; then
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
# Signal extractors (frozen regex + status shape mirror check-trailer.sh).
# -----------------------------------------------------------------------------

trailer_regex='^GAIA-Audit:[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9a-f]{40})[[:space:]]*$'

# trailer_version_for <sha> → echoes the (last) GAIA-Audit trailer version on
# that commit's message, or empty. Reads from a temp file (not a pipe) so the
# matched value survives in this shell (Bash 3.2 has no lastpipe).
trailer_version_for() {
  local sha="$1" line ver="" tmp
  tmp=$(mktemp -t gaia-audit-base.XXXXXX) || return 0
  git -C "$repo_root" log -1 --format='%B' "$sha" 2>/dev/null \
    | git -C "$repo_root" interpret-trailers --parse > "$tmp" 2>/dev/null || true
  while IFS= read -r line; do
    case "$line" in
      GAIA-Audit:*) ;;
      *) continue ;;
    esac
    if [[ "$line" =~ $trailer_regex ]]; then
      ver="${BASH_REMATCH[1]}"
    fi
  done < "$tmp"
  rm -f "$tmp"
  printf '%s' "$ver"
}

# status_version_for <sha> → echoes the GAIA-Audit commit status version, or
# empty. Needs gh + GH_TOKEN + repo slug; a missing token / absent gh / API
# failure / no status all yield empty (the walk continues).
status_version_for() {
  local sha="$1" repo desc
  [ -n "${GH_TOKEN:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  repo="${GITHUB_REPOSITORY:-}"
  [ -n "$repo" ] || return 0
  desc=$(gh api "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit")) | last | .description' \
    2>/dev/null || true)
  if [ -z "$desc" ] || [ "$desc" = "null" ]; then
    return 0
  fi
  printf '%s' "$desc" | awk '{print $1}'
}

# -----------------------------------------------------------------------------
# Walk newest → oldest; first version-matching signal wins.
# -----------------------------------------------------------------------------

for sha in $candidates; do
  # HEAD itself can't be the base (an empty diff), and never carries a
  # *matching* signal anyway, a match would have skipped the run upstream.
  [ "$sha" = "$head_sha" ] && continue

  tv="$(trailer_version_for "$sha")"
  if [ -n "$tv" ] && [ "$tv" = "$cur_version" ]; then
    printf '%s\n' "$sha"
    exit 0
  fi

  sv="$(status_version_for "$sha")"
  if [ -n "$sv" ] && [ "$sv" = "$cur_version" ]; then
    printf '%s\n' "$sha"
    exit 0
  fi
done

# No audited ancestor in range → full scope.
printf '%s\n' "$main_ref"
exit 0
