#!/usr/bin/env bash
# resolve-audit-members.sh: Code Audit Team dispatch resolver.
#
# Turns the current branch's diff into the DISPATCHED MEMBER SET, the deduped,
# lexically-sorted set of auditor member names that own at least one changed
# file. The local merge gate (pr-merge-audit-check.sh) and the member-aware
# GAIA-Audit status POST both consume this to require a per-member clearance
# for every dispatched member; a diff touching two members' surfaces cannot
# merge until BOTH clear.
#
# Usage:
#   resolve-audit-members.sh [--base <ref>]
#     --base <ref>  Diff base override. Without it, the base is resolved the
#                   same way pr-merge-audit-check.sh does: the remote default
#                   branch (origin/HEAD, fallback main), then the merge-base of
#                   HEAD with it (fallback: local <default> merge-base).
#     --help | -h   Print this usage and exit.
#
# Output contract:
#   One dispatched member name per line on stdout, deduped and lexically
#   sorted. EMPTY stdout means zero-match: the entire diff is out of audit
#   scope. Exit code is 0 on EVERY path (empty diff, unresolvable base, not in
#   a git repo, unknown flag) so consumers can parse stdout unconditionally.
#
# Dispatch algorithm, per changed file, in two precedence tiers (owned by
# audit-scope.sh, sourced below):
#   1. Every CLAIMANT (non-default) member whose globs match the path wins,
#      first-match-wins over roster order.
#   2. Else, if the default member's own declared globs match the path, the
#      default member is added.
#   3. Else the file has no owner (out of scope). No routing decision
#      consults a hardcoded auditable-base literal; every member, the default
#      included, declares its domain in the roster.
#
# Roster-source precedence:
#   1. The `auditors:` block in <repo-root>/.gaia/audit-ci.yml, when present
#      and non-empty.
#   2. Otherwise the built-in fallback roster in audit-scope.sh. Its
#      maintainer-only entries sit inside `# gaia:maintainer-only` markers so
#      the release scrub strips them from the shipped script; an adopter's
#      built-in fallback is therefore the default (frontend) member and the
#      workflows member only.
#   The resolver iterates the roster GENERICALLY: it emits whatever member
#   names the roster defines and is not hard-coded to any specific member, so
#   an adopter adds a member with a config entry plus an agent file, no script
#   edit.
#
# Glob semantics (matched against repo-relative POSIX paths), mirroring the
# release scrub's globToRegex:
#   **/ -> (.*/)?  (any depth, INCLUDING zero segments, spanning /)
#   **  -> .*
#   *   -> [^/]*   (any run within one path segment, never crossing /)
# So `.gaia/**/*.sh` matches `.gaia/x.sh` and `.gaia/scripts/y.sh`;
# `.github/**/*.sh` matches a top-level `.github/x.sh` as well as
# `.github/workflows/y.sh` (the `**/` collapses to zero segments);
# `.specify/extensions/gaia/lib/*.sh` matches only direct children;
# `app/**` matches anything under app/.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`,
# no `${var^^}`. No `cd` (per .claude/rules/shell-cwd.md); the repo root is
# resolved via `git rev-parse --show-toplevel` and every git call is scoped
# to it with `git -C`.

set -euo pipefail

# --- Parse arguments ----------------------------------------------------------

BASE_OVERRIDE=""

print_usage() {
  cat <<'USAGE'
Usage: resolve-audit-members.sh [--base <ref>]
  Emits the dispatched auditor member set (one name per line, sorted) for the
  current branch's diff. Empty output = entire diff out of scope. Exit 0 always.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      if [ "$#" -lt 2 ]; then
        echo "resolve-audit-members: --base requires a <ref> argument" >&2
        exit 0
      fi
      BASE_OVERRIDE="$2"
      shift 2
      ;;
    --help|-h)
      print_usage
      exit 0
      ;;
    *)
      echo "resolve-audit-members: unrecognized argument '$1'" >&2
      print_usage >&2
      exit 0
      ;;
  esac
done

# --- Resolve the repo root -----------------------------------------------
#
# Not in a git repo -> nothing to diff; emit nothing and exit 0.

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$repo_root" ] || exit 0

# --- Load the shared ownership classifier ------------------------------------
#
# Resolved from this script's OWN on-disk location, never cwd, never
# $repo_root: the bats suites run this script with cwd inside a sandbox that
# has no .claude/ at all. Absent or unreadable module: this resolver is a
# query, not a gate, so it fails safe to its existing empty-stdout contract
# rather than crash. (The merge gate, not this resolver, is where an absent
# module must deny.)
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -z "$_lib_dir" ] || [ ! -f "$_lib_dir/audit-scope.sh" ]; then
  exit 0
fi
# shellcheck source=/dev/null
. "$_lib_dir/audit-scope.sh"

audit_scope_init "$repo_root"

# --- Resolve the diff base + changed files -----------------------------------

resolve_base() {
  if [ -n "$BASE_OVERRIDE" ]; then
    printf '%s' "$BASE_OVERRIDE"
    return 0
  fi
  local default_branch base
  default_branch="$(git -C "$repo_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')" || true
  [ -n "$default_branch" ] || default_branch="main"
  base="$(git -C "$repo_root" merge-base HEAD "origin/${default_branch}" 2>/dev/null \
    || git -C "$repo_root" merge-base HEAD "${default_branch}" 2>/dev/null \
    || true)"
  printf '%s' "$base"
}

base="$(resolve_base)"
[ -n "$base" ] || exit 0

changed="$(git -C "$repo_root" diff --name-only "${base}...HEAD" 2>/dev/null || true)"
[ -n "$changed" ] || exit 0

# --- Dispatch: batch-classify every changed path, collect unique owners -----
#
# Deduped, lexically-sorted member names. Empty input -> empty output (the
# batch predicate emits nothing for an ownerless path; `awk` here drops the
# "-" placeholder rather than the member name).

printf '%s\n' "$changed" | audit_owners_for_paths \
  | awk -F'\t' '$2 != "-" { print $2 }' \
  | LC_ALL=C sort -u
