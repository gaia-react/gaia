#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check A -- one canonical main-root resolver PER LANGUAGE (state-registry
# conformance model, foundations task 2.3, design analysis/registry-design.md
# §4.1; per-language extension by task 3.11, DECISIONS.md D-M3-2).
#
# Over TRACKED SOURCE: asserts exactly one `gaia_resolve_main_root` shell
# function DEFINITION and exactly one `resolveMainWorktreeRoot` TypeScript
# DEFINITION exist in the whole tree. This is the narrow "one canonical
# definition" guard, not the repo-wide "does every call site use it" scan --
# that broader derivation scan is Phase 3's and stays red until then
# (analysis/registry-design.md §0, PROGRAM.md §2 gate). A second file defining
# either name is exactly the residue this guards against: a second copy of the
# resolver, hand-written instead of imported.
#
# Why two, and why counted separately: GAIA's main-root resolution has two
# implementations, one per language, because making a TypeScript caller reach
# the bash resolver at runtime costs a subprocess on a hot path. That is a
# deliberate, blessed position (D-M3-2) -- but before task 3.11 this check
# counted only shell definitions, so "one resolver, forever" was silently
# shell-only while a second derivation served seven TypeScript call sites.
# Counting per language is what makes the guarantee say what its name promises.
#
# Current-tree resolvers are deliberately NOT counted, in either language:
# `gaia_resolve_tree_root` and TypeScript's `--show-toplevel` helpers answer
# "which tree is this", a different question from "where is main".
#
# Dual-mode, mirroring the repo's other check/lib scripts: source it for
# gaia_check_resolver_singleton, or run it directly as a script (see
# "Executable entry" at the bottom).
#
# gaia_check_resolver_singleton <repo_root>
#   Runs `git -C <repo_root> grep` for each language's resolver definition
#   across every tracked source file (test suites -- *.bats, tests/,
#   __tests__/, *.test.* -- excluded). Prints one line per match
#   (`file:line:text`) followed by a per-language verdict line. Returns 0 when
#   BOTH counts are exactly one, 1 otherwise (zero or more-than-one in either
#   language). Zero fails as loudly as two: zero means the canonical resolver
#   was deleted and the derivations went back to being hand-rolled.
#   <repo_root> is a required parameter -- this check never derives it
#   itself (a caller in CI passes the plain checkout root; a bats fixture
#   passes a temp repo, so the "would a second definition fail this" case
#   can be tested without touching real tracked source).

# The shell pattern: the literal function name immediately followed by "()"
# (optional space before the parens), optionally preceded by the `function`
# keyword, ANCHORED to the start of the line (after optional indentation). A
# real shell function definition begins its line, so anchoring here excludes
# a comment mention (`# gaia_resolve_main_root() ...`, which has a `#` before
# the name) and an inline reference, while still matching the genuine
# `gaia_resolve_main_root() {` definition. It also does NOT match a plain call
# (`gaia_resolve_main_root "$dir"`) or a command substitution
# (`$(gaia_resolve_main_root)`).
GAIA_RESOLVER_DEF_PATTERN='^[[:space:]]*(function[[:space:]]+)?gaia_resolve_main_root[[:space:]]*\(\)'

# The TypeScript pattern: a binding or function declaration introducing the
# name, ANCHORED to the start of the line. `export const resolveMainWorktreeRoot
# =` and `function resolveMainWorktreeRoot(` match; an `import
# {resolveMainWorktreeRoot}` (line starts with `import`), a re-export (`export
# {` -- no declaration keyword), a call, and a comment mention do not, because
# each fails either the anchor or the declaration keyword. The trailing
# character class keeps `resolveMainWorktreeRootSomething` from matching.
GAIA_TS_RESOLVER_DEF_PATTERN='^[[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?(function|const|let|var)[[:space:]]+resolveMainWorktreeRoot[[:space:]]*[(=<:]'

# _gaia_resolver_defs <repo_root> <pattern> <label> [pathspec ...]
# Prints every matching definition line, then one verdict line naming the
# language and its canonical symbol. Returns 0 when exactly one exists.
_gaia_resolver_defs() {
  local repo_root="$1" pattern="$2" label="$3"
  shift 3
  local matches count=0
  # git grep exits 1 when it finds nothing, which is a normal outcome here
  # (zero definitions), not a script error -- so it is not run under -e and
  # its status is captured explicitly. Test suites are excluded: a canonical
  # resolver definition ships in source, never in a *.bats / tests/ /
  # __tests__/ / *.test.* fixture, and a suite that builds a throwaway repo
  # with a second definition (to prove this check fires) must not itself trip
  # the real-source count.
  matches="$(git -C "$repo_root" grep -nIE "$pattern" -- "$@" 2>/dev/null)"
  if [ -n "$matches" ]; then
    count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
    printf '%s\n' "$matches"
  fi
  printf '%s definitions found: %s\n' "$label" "$count"
  [ "$count" -eq 1 ]
}

gaia_check_resolver_singleton() {
  local repo_root="${1:?gaia_check_resolver_singleton requires a repo_root argument}"
  local shell_failed=0 ts_failed=0

  _gaia_resolver_defs "$repo_root" "$GAIA_RESOLVER_DEF_PATTERN" \
    'shell resolver (gaia_resolve_main_root)' \
    . ':!*.bats' ':!*/tests/*' ':!*/__tests__/*' ':!*.test.ts' ':!*.test.tsx' \
    || shell_failed=1

  # Scoped to TypeScript source extensions, never `.` -- the committed CLI
  # bundles (.gaia/cli/gaia, .gaia/cli/gaia-maintainer) are tracked,
  # extensionless, and contain an esbuild-inlined copy of the resolver. They
  # are build output of the one definition, not a second one; widening this
  # pathspec would count them and fail the check on every release.
  _gaia_resolver_defs "$repo_root" "$GAIA_TS_RESOLVER_DEF_PATTERN" \
    'typescript resolver (resolveMainWorktreeRoot)' \
    '*.ts' '*.tsx' '*.mts' '*.cts' \
    ':!*/tests/*' ':!*/__tests__/*' ':!*.test.ts' ':!*.test.tsx' \
    || ts_failed=1

  [ "$shell_failed" -eq 0 ] && [ "$ts_failed" -eq 0 ]
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
