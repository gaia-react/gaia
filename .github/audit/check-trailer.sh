#!/usr/bin/env bash
# check-trailer.sh: CI skip-logic for the GAIA-Audit commit trailer.
#
# Purpose
#   Implements the "CI skip logic (frozen)" contract from
#   .gaia/local/plans/code-review-audit-ci/trailer-format.md. Called by the
#   `code-review-audit` GitHub Actions workflow as the gate that decides
#   whether to invoke the audit agent or short-circuit to a clean check
#   because the PR HEAD already carries a matching GAIA-Audit trailer.
#
# Invocation
#   .github/audit/check-trailer.sh
#
#   Argument-less. Reads .gaia/VERSION and the current HEAD's commit
#   message + tree from the working tree.
#
# Output (stdout, GITHUB_OUTPUT-friendly key=value lines)
#   skip=<true|false>
#   matched_version=<string-or-empty>
#   matched_tree=<sha-or-empty>
#   reason=<short-string>
#
# Reasons
#   trailer-matches: skip=true; matched both version and tree
#   status-matches: skip=true; no trailer, but a GAIA-Audit commit
#                             status on HEAD matched both version and tree
#   no-trailer: skip=false; HEAD has no GAIA-Audit trailer AND
#                             no usable GAIA-Audit commit status (status
#                             absent, malformed, or the API was unusable)
#   version-mismatch: skip=false; trailer present but version drift
#   tree-mismatch: skip=false; trailer present but tree drift
#   status-version-mismatch: skip=false; GAIA-Audit status present but
#                             version drift
#   status-tree-mismatch: skip=false; GAIA-Audit status present but tree
#                             drift
#   version-file-missing: skip=false; .gaia/VERSION missing or empty
#                             (defensive: matches the stamp helper's
#                             "no stamp without VERSION" invariant)
#
# Last-trailer-wins
#   When HEAD's commit message carries multiple GAIA-Audit trailers (the
#   parser tolerates them; the local stamp never writes more than one),
#   only the LAST matching parsed line is considered. This mirrors the
#   frozen skip-logic pseudocode in trailer-format.md.
#
# Exit code
#   0 always. The workflow consumes the four output lines.
#
# References
#   Frozen contract:  .gaia/local/plans/code-review-audit-ci/trailer-format.md
#   Stamp helper:     .claude/hooks/audit-stamp-trailer.sh
#   Config reader:    .gaia/scripts/read-audit-ci-config.sh
#
# Notes
#   - Bash 3.2 compatible (macOS-default bash). Avoids associative arrays.
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Resolves repo root via
#     git rev-parse and uses `git -C "$repo_root"` for everything.
#   - Trailer extraction goes through `git interpret-trailers --parse`
#     (handles RFC 822 folding + blank-line separation correctly), then
#     each parsed line is matched against the frozen regex.
#   - When HEAD carries no trailer, a fallback queries the GitHub Commit
#     Status API for a GAIA-Audit status on HEAD (CI-stamped PRs carry the
#     audit signal as a commit status, not a commit-message trailer). The
#     fallback needs `GH_TOKEN` in the environment and the `gh` CLI. A
#     missing token, absent `gh`, API failure, or absent status is
#     inconclusive and never skips the audit; it falls through to
#     `no-trailer`.

set -euo pipefail

# -----------------------------------------------------------------------------
# Output emitters
# -----------------------------------------------------------------------------

# emit <skip> <matched_version> <matched_tree> <reason>
emit() {
  printf 'skip=%s\n' "$1"
  printf 'matched_version=%s\n' "$2"
  printf 'matched_tree=%s\n' "$3"
  printf 'reason=%s\n' "$4"
}

# -----------------------------------------------------------------------------
# Resolve repo root
# -----------------------------------------------------------------------------

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  # Defensive: not in a git repo. Treat as "no trailer" so the workflow
  # proceeds; the audit step will fail loudly on the broken environment.
  emit "false" "" "" "no-trailer"
  exit 0
fi

# -----------------------------------------------------------------------------
# Read .gaia/VERSION
# -----------------------------------------------------------------------------

version_file="${repo_root}/.gaia/VERSION"
cur_version=""
if [ -f "$version_file" ]; then
  # Strip CR, take first non-blank line, trim whitespace.
  cur_version=$(tr -d '\r' < "$version_file" | awk 'NF{print; exit}')
  cur_version="${cur_version#"${cur_version%%[![:space:]]*}"}"
  cur_version="${cur_version%"${cur_version##*[![:space:]]}"}"
fi

if [ -z "$cur_version" ]; then
  emit "false" "" "" "version-file-missing"
  exit 0
fi

# -----------------------------------------------------------------------------
# Compute current tree-sha
# -----------------------------------------------------------------------------

cur_tree=$(git -C "$repo_root" rev-parse "HEAD^{tree}" 2>/dev/null || true)
if [ -z "$cur_tree" ]; then
  # No HEAD (empty repo); nothing to skip on.
  emit "false" "" "" "no-trailer"
  exit 0
fi

# -----------------------------------------------------------------------------
# Extract trailers from HEAD's commit message
# -----------------------------------------------------------------------------

# Frozen regex (POSIX ERE); see trailer-format.md.
trailer_regex='^GAIA-Audit:[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9a-f]{40})[[:space:]]*$'

# Parse trailers; filter to GAIA-Audit lines that match the regex shape.
# Bash 3.2 has no `mapfile`; use a while-read loop into a tracked
# "last seen" pair of variables.
last_version=""
last_tree=""
saw_any_trailer="false"

# Use process substitution? Not Bash 3.2 portable in all macOS quirks; pipe
# instead but capture state via a temp file because the loop runs in a
# subshell when piped.
trailers_tmp=$(mktemp -t gaia-audit-trailers.XXXXXX)
trap 'rm -f "$trailers_tmp"' EXIT

git -C "$repo_root" log -1 --format='%B' \
  | git -C "$repo_root" interpret-trailers --parse \
  > "$trailers_tmp"

while IFS= read -r line; do
  # Quick prefix filter; skip non-GAIA-Audit trailers cheaply.
  case "$line" in
    GAIA-Audit:*) ;;
    *) continue ;;
  esac
  if [[ "$line" =~ $trailer_regex ]]; then
    saw_any_trailer="true"
    last_version="${BASH_REMATCH[1]}"
    last_tree="${BASH_REMATCH[2]}"
  fi
  # Malformed GAIA-Audit lines are silently ignored (per the contract:
  # the helper "matches the regex on each trailer line"; non-matching
  # lines are not trailer entries for our purposes).
done < "$trailers_tmp"

# -----------------------------------------------------------------------------
# GitHub Commit Status fallback
# -----------------------------------------------------------------------------
# CI-stamped PRs carry the audit signal as a GitHub Commit Status with
# context "GAIA-Audit" and state "success" (description "<version> <tree-sha>"),
# NOT as a commit message trailer. (The workflow no longer pushes an empty
# marker commit - pushing it would strand the PR on a check-less HEAD.) When
# HEAD has no matching trailer, query the API for a success status and apply
# the same version + tree match logic. A non-success status (e.g. a local-mode
# stand-down's pending status on this SHA) is filtered out at the source, so a
# pending status carrying HEAD's version+tree never skips the audit.
#
# Requires GH_TOKEN in the environment (the workflow exports it). A failed
# or absent API call MUST NOT skip the audit: callers fall through to
# running it.
#
# Emits the four-line output and exits 0 on a conclusive result.
# Returns non-zero (without emitting) when the status is absent / the API
# is unusable, so the caller falls through to `no-trailer`.
check_status_fallback() {
  # No token → cannot query. Fall through.
  [ -n "${GH_TOKEN:-}" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1

  head_sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
  [ -n "$head_sha" ] || return 1

  # GITHUB_REPOSITORY is set in Actions; derive from origin otherwise.
  repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then
    return 1
  fi

  # Query combined status for HEAD; pull the GAIA-Audit context's description,
  # requiring the status state to be success so a non-success status (e.g. a
  # pending stand-down) is filtered out at the source. `gh api` exits non-zero
  # on HTTP error → handled by `||`.
  status_desc=$(gh api \
    "repos/${repo}/commits/${head_sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit" and .state == "success")) | last | .description' \
    2>/dev/null || true)

  # No status, API failure, or jq produced "null"/empty → fall through.
  if [ -z "$status_desc" ] || [ "$status_desc" = "null" ]; then
    return 1
  fi

  # Description shape: "<version> <40-hex-tree>".
  status_version=$(printf '%s' "$status_desc" | awk '{print $1}')
  status_tree=$(printf '%s' "$status_desc" | awk '{print $2}')

  # Defensive: a malformed description is treated as no status.
  if [ -z "$status_version" ] || [ -z "$status_tree" ]; then
    return 1
  fi
  case "$status_tree" in
    *[!0-9a-f]* | "") return 1 ;;
  esac
  if [ "${#status_tree}" -ne 40 ]; then
    return 1
  fi

  if [ "$status_version" != "$cur_version" ]; then
    emit "false" "$status_version" "$status_tree" "status-version-mismatch"
    exit 0
  fi
  if [ "$status_tree" != "$cur_tree" ]; then
    emit "false" "$status_version" "$status_tree" "status-tree-mismatch"
    exit 0
  fi
  emit "true" "$status_version" "$status_tree" "status-matches"
  exit 0
}

# -----------------------------------------------------------------------------
# Decide
# -----------------------------------------------------------------------------

if [ "$saw_any_trailer" != "true" ]; then
  # No commit-message trailer. Try the GitHub Commit Status fallback
  # (CI-stamped PRs). If it cannot conclude, fall through to no-trailer.
  check_status_fallback || true
  emit "false" "" "" "no-trailer"
  exit 0
fi

if [ "$last_version" != "$cur_version" ]; then
  emit "false" "$last_version" "$last_tree" "version-mismatch"
  exit 0
fi

if [ "$last_tree" != "$cur_tree" ]; then
  emit "false" "$last_version" "$last_tree" "tree-mismatch"
  exit 0
fi

emit "true" "$last_version" "$last_tree" "trailer-matches"
exit 0
