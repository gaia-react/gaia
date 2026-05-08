#!/usr/bin/env bash
# check-trailer.sh — CI skip-logic for the GAIA-Audit commit trailer.
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
#   trailer-matches        — skip=true; matched both version and tree
#   no-trailer             — skip=false; HEAD has no GAIA-Audit trailer
#                             (or only malformed lines, which are ignored)
#   version-mismatch       — skip=false; trailer present but version drift
#   tree-mismatch          — skip=false; trailer present but tree drift
#   version-file-missing   — skip=false; .gaia/VERSION missing or empty
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
  # No HEAD (empty repo) — nothing to skip on.
  emit "false" "" "" "no-trailer"
  exit 0
fi

# -----------------------------------------------------------------------------
# Extract trailers from HEAD's commit message
# -----------------------------------------------------------------------------

# Frozen regex (POSIX ERE) — see trailer-format.md.
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
  # Quick prefix filter — skip non-GAIA-Audit trailers cheaply.
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
  # the helper "matches the regex on each trailer line" — non-matching
  # lines are not trailer entries for our purposes).
done < "$trailers_tmp"

# -----------------------------------------------------------------------------
# Decide
# -----------------------------------------------------------------------------

if [ "$saw_any_trailer" != "true" ]; then
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
