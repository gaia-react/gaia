#!/usr/bin/env bash
# shellcheck shell=bash
#
# Adoption check for the shared base-provenance resolver
# (.claude/hooks/lib/audit-base-provenance.sh).
#
# Nothing keeps the spawn oracle, the pull-request merge gate, and the Code
# Audit Team member resolver from drifting apart except that none of them
# owns a private copy of the base-derivation rule. This check makes that
# property machine-checked: the resolver stays a singleton, the three named
# consumers call it, and no file regrows the origin-then-local fallback
# chain the resolver replaces.
#
# The claim is bounded, not tree-wide. Five shell sites carried the
# origin-then-local chain before the resolver existed. Two are not
# converted: the worthiness presence check, fail-open and deliberately out
# of scope, and the disposition sidecar's changed-set helper, whose body IS
# the resolver -- lifted, not copied, so there is nothing left there to
# exempt.
#
# check-audit-base-derivation.sh is a different check over a different
# concern: it governs the Code Audit Team member agents' REVIEW base, not
# this diff-provenance resolver. It is not extended for this purpose.
#
# One of the three named consumers, .gaia/scripts/resolve-audit-spawn.sh, is
# itself release-excluded, so its adoption assertion is only ever complete
# on a maintainer clone. That is not a gap this check has to close: this
# check is release-excluded too (see .gaia/release-exclude), so it never
# runs against an adopter clone missing that file.
#
# Dual-mode, mirroring check-resolver-singleton.sh: source it for
# gaia_check_base_provenance_adoption, or run it directly as a script.
#
# gaia_check_base_provenance_adoption <repo_root>
#   Three assertions over tracked shell source (test suites excluded):
#     1. Exactly one definition of audit_resolve_base_provenance exists.
#     2. Each of the three named consumers references it.
#     3. No file other than the resolver's own and the one written
#        exemption carries the origin-then-local fallback chain.
#   Prints one line per finding plus a verdict line per assertion. Returns 0
#   when all three hold, 1 when any does not. <repo_root> is a required
#   parameter -- this check never derives it itself, so a bats fixture can
#   drive it against a throwaway repo.

# Same anchoring discipline as check-resolver-singleton.sh's
# GAIA_RESOLVER_DEF_PATTERN: the literal function name immediately followed
# by "()" (optional space before the parens), optionally preceded by
# `function`, anchored to the start of the line after optional indentation.
# That excludes a comment mention, an inline reference, a plain call, and a
# command substitution, while still matching the genuine definition.
GAIA_PROVENANCE_DEF_PATTERN='^[[:space:]]*(function[[:space:]]+)?audit_resolve_base_provenance[[:space:]]*\(\)'

# Pathspec exclusions matching check-resolver-singleton.sh: a canonical
# definition ships in source, never in a *.bats / tests/ / __tests__/ /
# *.test.* fixture built to prove this check fires.
GAIA_PROVENANCE_TEST_EXCLUDES=(':!*.bats' ':!*/tests/*' ':!*/__tests__/*' ':!*.test.ts' ':!*.test.tsx')

# The three consumers UAT-007 names, in the order the spec lists them.
GAIA_PROVENANCE_CONSUMERS=(
  '.gaia/scripts/resolve-audit-spawn.sh'
  '.claude/hooks/pr-merge-audit-check.sh'
  '.gaia/scripts/resolve-audit-members.sh'
)

# The chain's one written exemption plus the resolver's own file. No entry
# for .claude/hooks/lib/audit-dispositions.sh: after adoption its
# changed-set helper carries no origin-then-local chain at all, because that
# helper's body became this resolver's definition rather than staying a
# copy of it, so there is nothing to exempt.
GAIA_PROVENANCE_ALLOWED_CHAIN_FILES=(
  '.claude/hooks/lib/audit-base-provenance.sh'
  '.claude/hooks/worthiness-presence-check.sh'
)

# _gaia_provenance_singleton <repo_root>: assertion 1. Prints every matching
# definition line, then a verdict line. Returns 0 iff exactly one exists.
_gaia_provenance_singleton() {
  local repo_root="$1" matches count=0
  # git grep exits 1 on zero matches, a normal outcome here (not an error),
  # so it is not run under -e and its status is discarded.
  matches="$(git -C "$repo_root" grep -nIE "$GAIA_PROVENANCE_DEF_PATTERN" -- . "${GAIA_PROVENANCE_TEST_EXCLUDES[@]}" 2>/dev/null)"
  if [ -n "$matches" ]; then
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    printf '%s\n' "$matches"
  fi
  printf 'audit_resolve_base_provenance definitions found: %s\n' "$count"
  [ "$count" -eq 1 ]
}

# _gaia_provenance_adoption <repo_root>: assertion 2. Prints one verdict
# line per named consumer. Returns 0 iff every consumer both exists and
# references the resolver at least once.
_gaia_provenance_adoption() {
  local repo_root="$1" file failed=0
  for file in "${GAIA_PROVENANCE_CONSUMERS[@]}"; do
    if [ ! -f "$repo_root/$file" ]; then
      printf '%s: MISSING (named consumer file not found)\n' "$file"
      failed=1
      continue
    fi
    if git -C "$repo_root" grep -qF 'audit_resolve_base_provenance' -- "$file" 2>/dev/null; then
      printf '%s: adopted\n' "$file"
    else
      printf '%s: NOT adopted (no audit_resolve_base_provenance reference)\n' "$file"
      failed=1
    fi
  done
  return "$failed"
}

# _gaia_provenance_chain_hits <path>: prints "<line>:<text>" for each line in
# <path> that starts the origin-then-local fallback pair -- two
# merge-base-against-HEAD invocations joined by a `||` continuation, either
# on one line or via a trailing `\` or trailing `||` into the next
# non-comment line. Comment-only lines are never a hit and never break a
# continuation search. Matches the chain with or without a `-C <root>`
# argument, since the detection never looks for that token.
_gaia_provenance_chain_hits() {
  local path="$1"
  [ -f "$path" ] || return 0
  awk '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function is_comment(s,   t) { t = trim(s); return substr(t, 1, 1) == "#" }
    function ends_continuation(s,   t) { t = trim(s); return (t ~ /\\$/) || (t ~ /\|\|$/) }
    function count_merge_base(s,   n, tmp) { tmp = s; n = gsub(/merge-base/, "&", tmp); return n }
    { lines[NR] = $0 }
    END {
      n = NR
      for (i = 1; i <= n; i++) {
        line = lines[i]
        if (is_comment(line)) continue
        if (index(line, "merge-base") == 0 || index(line, "HEAD") == 0) continue
        if (count_merge_base(line) >= 2) {
          print i ":" line
          continue
        }
        if (ends_continuation(line)) {
          j = i + 1
          while (j <= n && (trim(lines[j]) == "" || is_comment(lines[j]))) j++
          if (j <= n && index(lines[j], "merge-base") > 0) {
            print i ":" line
          }
        }
      }
    }
  ' "$path"
}

# _gaia_provenance_chain_scan <repo_root>: assertion 3. Prints one line per
# file carrying the chain, naming whether it is an allowed carrier. Returns
# 0 iff every carrier is on the allowed list.
_gaia_provenance_chain_scan() {
  local repo_root="$1" failed=0 file hits allowed a
  # -z, and a NUL-delimited read: under git's default core.quotePath a path
  # carrying a non-ASCII byte is C-quoted, and the quoted form stops matching
  # the allowed-carrier comparison below, which would silently reclassify an
  # allowed carrier as a private chain.
  while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    hits="$(_gaia_provenance_chain_hits "$repo_root/$file")"
    [ -n "$hits" ] || continue
    allowed=0
    for a in "${GAIA_PROVENANCE_ALLOWED_CHAIN_FILES[@]}"; do
      if [ "$file" = "$a" ]; then
        allowed=1
        break
      fi
    done
    if [ "$allowed" -eq 1 ]; then
      printf '%s:%s (allowed carrier)\n' "$file" "$hits"
    else
      printf '%s:%s (private chain, not allowed)\n' "$file" "$hits"
      failed=1
    fi
  done < <(git -C "$repo_root" ls-files -z -- '*.sh' "${GAIA_PROVENANCE_TEST_EXCLUDES[@]}" 2>/dev/null)
  return "$failed"
}

# gaia_check_base_provenance_adoption <repo_root>
gaia_check_base_provenance_adoption() {
  local repo_root="${1:?gaia_check_base_provenance_adoption requires a repo_root argument}"
  local singleton_failed=0 adoption_failed=0 chain_failed=0

  printf -- '-- resolver singleton --\n'
  _gaia_provenance_singleton "$repo_root" || singleton_failed=1

  printf -- '-- consumer adoption --\n'
  _gaia_provenance_adoption "$repo_root" || adoption_failed=1

  printf -- '-- private fallback chain --\n'
  _gaia_provenance_chain_scan "$repo_root" || chain_failed=1

  [ "$singleton_failed" -eq 0 ] && [ "$adoption_failed" -eq 0 ] && [ "$chain_failed" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-base-provenance-adoption: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_base_provenance_adoption "$repo_root"
  exit $?
fi
