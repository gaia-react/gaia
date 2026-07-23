#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check A -- one canonical main-root resolver (state-registry conformance
# model, foundations task 2.3, design analysis/registry-design.md §4.1).
#
# Over TRACKED SOURCE: asserts exactly one `gaia_resolve_main_root` function
# DEFINITION exists in the whole tree. This is the narrow "one canonical
# definition" guard, not the repo-wide "does every call site use it" scan --
# that broader derivation scan is Phase 3's and stays red until then
# (analysis/registry-design.md §0, PROGRAM.md §2 gate). A second file
# defining the same function name is exactly the residue this guards
# against: a second copy of the resolver, hand-written instead of sourced.
#
# Dual-mode, mirroring the repo's other check/lib scripts: source it for
# gaia_check_resolver_singleton, or run it directly as a script (see
# "Executable entry" at the bottom).
#
# gaia_check_resolver_singleton <repo_root>
#   Runs `git -C <repo_root> grep` for a `gaia_resolve_main_root` function
#   definition (`name()` or `name ()`, optionally preceded by the `function`
#   keyword), line-start anchored, across every tracked source file (test
#   suites -- *.bats, tests/, *.test.* -- excluded). Prints one line per match
#   (`file:line:text`) to stdout, then a one-line verdict. Returns 0 when
#   exactly one definition exists, 1 otherwise (zero or more-than-one).
#   <repo_root> is a required parameter -- this check never derives it
#   itself (a caller in CI passes the plain checkout root; a bats fixture
#   passes a temp repo, so the "would a second definition fail this" case
#   can be tested without touching real tracked source).

# The pattern: the literal function name immediately followed by "()"
# (optional space before the parens), optionally preceded by the `function`
# keyword, ANCHORED to the start of the line (after optional indentation). A
# real shell function definition begins its line, so anchoring here excludes
# a comment mention (`# gaia_resolve_main_root() ...`, which has a `#` before
# the name) and an inline reference, while still matching the genuine
# `gaia_resolve_main_root() {` definition. It also does NOT match a plain call
# (`gaia_resolve_main_root "$dir"`) or a command substitution
# (`$(gaia_resolve_main_root)`).
GAIA_RESOLVER_DEF_PATTERN='^[[:space:]]*(function[[:space:]]+)?gaia_resolve_main_root[[:space:]]*\(\)'

gaia_check_resolver_singleton() {
  local repo_root="${1:?gaia_check_resolver_singleton requires a repo_root argument}"
  local matches
  # git grep exits 1 when it finds nothing, which is a normal outcome here
  # (zero definitions), not a script error -- so it is not run under -e and
  # its status is captured explicitly. Test suites are excluded: a canonical
  # resolver definition ships in source, never in a *.bats / tests/ / *.test.*
  # fixture, and a suite that builds a throwaway repo with a second definition
  # (to prove this check fires) must not itself trip the real-source count.
  matches="$(git -C "$repo_root" grep -nIE "$GAIA_RESOLVER_DEF_PATTERN" -- . \
    ':!*.bats' ':!*/tests/*' ':!*/__tests__/*' ':!*.test.ts' ':!*.test.tsx' 2>/dev/null)"
  local count=0
  if [ -n "$matches" ]; then
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    printf '%s\n' "$matches"
  fi
  printf 'gaia_resolve_main_root definitions found: %s\n' "$count"
  [ "$count" -eq 1 ]
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-resolver-singleton: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_resolver_singleton "$repo_root"
  exit $?
fi
