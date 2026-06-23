#!/usr/bin/env bash
# post-audit-status.sh, post the GAIA-Audit success commit status on HEAD.
#
# Purpose
#   Called by the code-review-audit agent (.claude/agents/code-review-audit.md)
#   on the local (Claude-driven merge) path, AFTER the audit marker has been
#   written. Posts a GAIA-Audit commit status of state=success on HEAD so the
#   same server-side gate the CI path satisfies is satisfied here too, letting
#   the github.com button and the per-author resolver's required-check
#   verification clear. The marker file is the literal precondition: the status
#   POST never runs inline with the clean judgment ahead of the marker write.
#
# Invocation
#   .claude/hooks/post-audit-status.sh <marker-path>
#
#   <marker-path>  The marker file the audit just wrote
#                  (.gaia/local/audit/<HEAD-sha>.ok). Its existence gates the
#                  POST; the agent passes the path it wrote in the marker step.
#
# Behavior
#   Best-effort and fail-safe-asymmetric: when gh is absent or unauthenticated
#   the POST is skipped (the button stays blocked) but the marker the caller
#   already wrote is untouched (the Claude merge path clears via the marker).
#   The status is never posted without the marker, and an absent status never
#   inverts into a cleared gate.
#
# Exit codes
#   0 , Posted successfully OR declined (precondition failed). One stdout
#        marker line is always emitted; the audit caller surfaces it. Lines:
#          status: posted GAIA-Audit success <short-sha>
#        Decline lines (prefix "status: declined: "):
#          marker absent
#          gh absent
#          gh unauthenticated
#          version file missing
#          version file empty
#          repo slug unresolved
#          post failed
#   2 , Usage error (no marker path argument). Stderr.
#
# References
#   Audit-marker handshake: .claude/agents/code-review-audit.md "Audit marker (gate handshake)"
#   Per-author resolver:    .gaia/scripts/read-audit-ci-config.sh
#   State-aware readers:    .claude/hooks/pr-merge-audit-check.sh
#
# Notes
#   - Bash 3.2 compatible (macOS-default bash).
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Resolves the repo root via
#     git rev-parse and uses repo-relative paths from there.
#   - The success description "<version> <tree-sha>" matches what every
#     state-aware GAIA-Audit reader accepts as cleared, and state=success
#     distinguishes it from the CI local-mode stand-down's pending sentinel.

set -euo pipefail

emit_posted() {
  printf 'status: posted GAIA-Audit success %s\n' "$1"
}

emit_decline() {
  printf 'status: declined: %s\n' "$1"
}

emit_error() {
  printf 'post-audit-status: %s\n' "$1" >&2
}

marker="${1:-}"
if [ -z "$marker" ]; then
  emit_error "usage: post-audit-status.sh <marker-path>"
  exit 2
fi

# Marker-first: the marker the caller wrote is the literal precondition.
if [ ! -f "$marker" ]; then
  emit_decline "marker absent"
  exit 0
fi

# gh must be present and authenticated; otherwise skip the POST (fail-safe
# asymmetry: the marker stays, the button stays blocked, never inverts).
if ! command -v gh >/dev/null 2>&1; then
  emit_decline "gh absent"
  exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  emit_decline "gh unauthenticated"
  exit 0
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

version_file="${repo_root}/.gaia/VERSION"
if [ ! -f "$version_file" ]; then
  emit_decline "version file missing"
  exit 0
fi

version=$(tr -d '\r' < "$version_file" | awk 'NF{print; exit}')
version="${version#"${version%%[![:space:]]*}"}"
version="${version%"${version##*[![:space:]]}"}"
if [ -z "$version" ]; then
  emit_decline "version file empty"
  exit 0
fi

head_sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
tree_sha=$(git -C "$repo_root" rev-parse "HEAD^{tree}" 2>/dev/null || true)
if [ -z "$head_sha" ] || [ -z "$tree_sha" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
if [ -z "$repo" ]; then
  emit_decline "repo slug unresolved"
  exit 0
fi

if gh api "repos/${repo}/statuses/${head_sha}" \
  --method POST \
  --field state=success \
  --field context=GAIA-Audit \
  --field description="${version} ${tree_sha}" >/dev/null 2>&1; then
  emit_posted "$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "$head_sha")"
  exit 0
fi

emit_decline "post failed"
exit 0
