# shellcheck shell=bash
# GAIA shared main-checkout ledger-path lib (single-sourced).
# Sourced by token-tally.sh, token-rollup.sh, token-rollup-merge.sh, and the
# SPEC/plan ledger libraries under .specify/extensions/gaia/lib/. Defines the
# main-checkout ledger-path derivations so each path lives in a single place:
# renaming one later changes one definition, not a dozen.
# No side effects at source time; defines functions only.
#
# Argument shapes differ between gaia_resolve_ledger_path and the two
# gaia_resolve_*_dir functions, deliberately: the first takes an override path
# (a test seam it has carried from the start), the latter two take the tree
# directory to resolve from. Named here so the asymmetry is documented rather
# than discovered at a call site.

# Echoes the main-checkout cost ledger path; honors an override (test seam).
# main_root comes from the shared main-root resolver
# (.gaia/scripts/main-root-lib.sh), so a run inside a linked worktree records
# to the surviving main ledger, not the worktree's discarded copy. Returns 1
# when the resolver cannot resolve a main checkout.
gaia_resolve_ledger_path() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then printf '%s' "$override"; return 0; fi
  local script_dir main_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$script_dir/main-root-lib.sh"
  main_root="$(gaia_resolve_main_root)" || return 1
  printf '%s' "$main_root/.gaia/local/telemetry/cost.jsonl"
}

# The one path construction behind gaia_resolve_specs_dir/gaia_resolve_plans_dir,
# so the two differ by a single word rather than by a duplicated expression.
# <subdir> is the .gaia/local child; <tree_dir> is any directory inside the
# repository (default: the process working directory).
_gaia_resolve_main_local_dir() {
  local subdir="$1" tree_dir="${2:-}"
  local script_dir main_root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$script_dir/main-root-lib.sh"
  main_root="$(gaia_resolve_main_root "$tree_dir")" || return 1
  printf '%s' "$main_root/.gaia/local/$subdir"
}

# Echo the main-checkout SPEC directory (.gaia/local/specs) for <tree_dir>.
# The state registry declares specs/ main-only, so "which tree am I in" is never
# the right question for it: callers hand in the tree they are running in and
# this answers with main's. Prints nothing and returns 1 when the resolver
# cannot resolve a main checkout -- callers must refuse rather than fall back to
# the unresolved directory, which is the forked-ledger defect itself.
gaia_resolve_specs_dir() {
  _gaia_resolve_main_local_dir specs "${1:-}"
}

# Echo the main-checkout plan directory (.gaia/local/plans) for <tree_dir>.
# Same contract as gaia_resolve_specs_dir; plans/ is likewise main-only.
gaia_resolve_plans_dir() {
  _gaia_resolve_main_local_dir plans "${1:-}"
}
