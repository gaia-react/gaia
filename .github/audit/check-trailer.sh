#!/usr/bin/env bash
# check-trailer.sh: CI skip-logic for the GAIA-Audit commit trailer.
#
# Purpose
#   Decides whether the code-review-audit CI workflow can skip invoking the
#   audit agent because the PR HEAD already carries a matching GAIA-Audit
#   trailer or commit status. Called by the `code-review-audit` GitHub
#   Actions workflow's "Check audit trailer" step.
#
# Invocation
#   .github/audit/check-trailer.sh
#
#   Argument-less. Reads .gaia/VERSION and the current HEAD's commit
#   message + tree from the working tree, and recomputes the frontend
#   member's content digest (C1) through the classifier libs in the
#   checkout.
#
# Output (stdout, GITHUB_OUTPUT-friendly key=value lines)
#   skip=<true|false>
#   matched_version=<string-or-empty>
#   matched_tree=<sha-or-empty>
#   reason=<short-string>
#
# Reasons
#   trailer-matches: skip=true; matched version and the frontend digest
#   status-matches: skip=true; no trailer, but a GAIA-Audit commit
#                             status on HEAD matched version and digest
#   no-trailer: skip=false; HEAD has no GAIA-Audit trailer AND
#                             no usable GAIA-Audit commit status (status
#                             absent, malformed, or the API was unusable)
#   version-mismatch: skip=false; trailer present but version drift
#   digest-mismatch: skip=false; trailer present but the frontend digest
#                             (owned-plus-machinery content) drifted
#   status-version-mismatch: skip=false; GAIA-Audit status present but
#                             version drift
#   status-digest-mismatch: skip=false; GAIA-Audit status present but the
#                             frontend digest drifted
#   version-file-missing: skip=false; .gaia/VERSION missing or empty
#                             (defensive: matches the stamp helper's
#                             "no stamp without VERSION" invariant)
#   digest-recompute-failed: skip=false; the frontend content digest could
#                             not be recomputed (missing sha256 tool,
#                             unloadable classifier/machinery lib, or a
#                             failing git ls-tree). Fail-open toward
#                             re-audit: CI must never skip on an
#                             unresolvable digest.
#
# Last-trailer-wins
#   When HEAD's commit message carries multiple GAIA-Audit trailers (the
#   parser tolerates them; the local stamp never writes more than one),
#   only the LAST matching parsed line is considered.
#
# Exit code
#   0 always. The workflow consumes the four output lines.
#
# References
#   Digest engine:    .claude/hooks/lib/audit-digest.sh
#   Digest CLI:        .gaia/scripts/audit-member-digest.sh
#   Stamp helper:      .claude/hooks/audit-stamp-trailer.sh
#   Config reader:      .gaia/scripts/read-audit-ci-config.sh
#
# Notes
#   - Bash 3.2 compatible (macOS-default bash). Avoids associative arrays.
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Resolves repo root via
#     git rev-parse and uses `git -C "$repo_root"` for everything.
#   - Trailer extraction goes through `git interpret-trailers --parse`
#     (handles RFC 822 folding + blank-line separation correctly), then
#     each parsed line is matched against the frozen regex.
#   - When HEAD carries no trailer, a fallback queries the GitHub Commit
#     Status API for the NEWEST GAIA-Audit status on HEAD (CI-stamped PRs
#     carry the audit signal as a commit status, not a commit-message
#     trailer). The fallback needs `GH_TOKEN` in the environment and the
#     `gh` CLI. A missing token, absent `gh`, API failure, or absent status
#     is inconclusive and never skips the audit; it falls through to
#     `no-trailer`. A newer non-success status (e.g. a re-run's pending or
#     failed state) shadows an older success: only the newest GAIA-Audit
#     entry is ever considered, and it must itself be `state: success`.
#   - The frontend digest recompute walks the full tracked tree and
#     reclassifies it through the ownership + machinery libs (directive
#     PERF-003): a bounded cost on the skip-check hot path, replacing the
#     old O(1) `rev-parse HEAD^{tree}` comparison. This is accepted, not
#     micro-optimized: the recompute is memoized per run (at most once)
#     and only runs when a trailer or status signal actually needs a
#     digest comparison.

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
# Recompute the frontend content digest (C1), memoized. Fail-closed: any
# caller that needs it and finds it unrecomputable emits skip=false with
# reason=digest-recompute-failed and exits -- CI must never skip the audit
# on an unresolvable digest (RT-007/CPL-004). The classifier libs are
# expected to be present in the checkout (.claude/hooks/lib/** ships and
# the full repo is checked out); an absent/unloadable lib is exactly the
# failure this recompute fails closed on.
# -----------------------------------------------------------------------------

cur_digest=""
_digest_attempted="false"
recompute_frontend_digest() {
  [ "$_digest_attempted" = "true" ] && return 0
  _digest_attempted="true"
  cur_digest="$(bash "${repo_root}/.gaia/scripts/audit-member-digest.sh" \
    --root "$repo_root" --member code-audit-frontend 2>/dev/null)" || cur_digest=""
  if [ -z "$cur_digest" ]; then
    emit "false" "" "" "digest-recompute-failed"
    exit 0
  fi
}

# -----------------------------------------------------------------------------
# Extract trailers from HEAD's commit message
# -----------------------------------------------------------------------------

# Frozen regex (POSIX ERE; C3): version, frontend-digest (64-hex), tree (40-hex).
trailer_regex='^GAIA-Audit:[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9a-f]{64})[[:space:]]+([0-9a-f]{40})[[:space:]]*$'

# Parse trailers; filter to GAIA-Audit lines that match the regex shape.
# Bash 3.2 has no `mapfile`; use a while-read loop into a tracked
# "last seen" set of variables.
last_version=""
last_digest=""
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
    last_digest="${BASH_REMATCH[2]}"
    last_tree="${BASH_REMATCH[3]}"
  fi
  # Malformed GAIA-Audit lines are silently ignored (per the contract:
  # the helper "matches the regex on each trailer line"; non-matching
  # lines are not trailer entries for our purposes).
done < "$trailers_tmp"

# -----------------------------------------------------------------------------
# GitHub Commit Status fallback
# -----------------------------------------------------------------------------
# CI-stamped PRs carry the audit signal as a GitHub Commit Status with
# context "GAIA-Audit" (description "<version> <frontend-digest> <tree>"),
# NOT as a commit message trailer. (The workflow no longer pushes an empty
# marker commit - pushing it would strand the PR on a check-less HEAD.) When
# HEAD has no matching trailer, query the API for the NEWEST GAIA-Audit
# status on HEAD and apply the same version + digest match logic, requiring
# that newest entry to be state:success. A newer non-success status (e.g. a
# re-run's pending state) shadows an older success on the same SHA, so a
# stale success earlier in the history can never paper over a later
# pending/failed re-run.
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

  # Query the chronological (newest-first) statuses list for HEAD; resolve
  # the single NEWEST GAIA-Audit entry of any state, then require that entry
  # to be state:success. A newer non-success entry shadows an older success
  # instead of being filtered out from under it. Mirrors
  # check_github_status() in .claude/hooks/pr-merge-audit-check.sh verbatim.
  # `gh api` exits non-zero on HTTP error → handled by `||`.
  status_desc=$(gh api \
    "repos/${repo}/commits/${head_sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit")) | first | select(.state == "success") | .description' \
    2>/dev/null || true)

  # No status, API failure, or jq produced "null"/empty → fall through.
  if [ -z "$status_desc" ] || [ "$status_desc" = "null" ]; then
    return 1
  fi

  # Description shape: "<version> <64-hex-digest> <40-hex-tree>".
  status_version=$(printf '%s' "$status_desc" | awk '{print $1}')
  status_digest=$(printf '%s' "$status_desc" | awk '{print $2}')
  status_tree=$(printf '%s' "$status_desc" | awk '{print $3}')

  # Defensive: a malformed description is treated as no status.
  if [ -z "$status_version" ] || [ -z "$status_digest" ] || [ -z "$status_tree" ]; then
    return 1
  fi
  case "$status_digest" in
    *[!0-9a-f]* | "") return 1 ;;
  esac
  if [ "${#status_digest}" -ne 64 ]; then
    return 1
  fi

  if [ "$status_version" != "$cur_version" ]; then
    emit "false" "$status_version" "$status_tree" "status-version-mismatch"
    exit 0
  fi
  recompute_frontend_digest
  if [ "$status_digest" != "$cur_digest" ]; then
    emit "false" "$status_version" "$status_tree" "status-digest-mismatch"
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

recompute_frontend_digest

if [ "$last_digest" != "$cur_digest" ]; then
  emit "false" "$last_version" "$last_tree" "digest-mismatch"
  exit 0
fi

emit "true" "$last_version" "$last_tree" "trailer-matches"
exit 0
