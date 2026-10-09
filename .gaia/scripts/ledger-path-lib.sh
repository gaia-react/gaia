# shellcheck shell=bash
# GAIA shared main-checkout ledger-path lib (single-sourced).
# Sourced by the SPEC and plan ledger libraries and scripts under
# .gaia/scripts/spec/ (ledger-lib.sh, ledger-update.sh, plan-allocator.sh,
# plan-reconcile.sh, the archive sweeps). Defines the main-checkout directory
# derivations so each path lives in a single place: renaming one later changes
# one definition, not a dozen.
# No side effects at source time; defines functions only.
#
# gaia_resolve_specs_directory and gaia_resolve_plans_directory take the tree
# directory to resolve from (default: the process working directory) and
# answer with main's .gaia/local/specs or .gaia/local/plans.

# The one path construction behind gaia_resolve_specs_directory/gaia_resolve_plans_directory,
# so the two differ by a single word rather than by a duplicated expression.
# <subdirectory> is the .gaia/local child; <tree_directory> is any directory inside the
# repository (default: the process working directory).
_gaia_resolve_main_local_directory() {
  local subdirectory="$1" tree_directory="${2:-}"
  local script_directory main_root errexit_was
  script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # Suspend errexit across the load, then RESTORE WHAT WAS THERE. A copy that is
  # present but unparseable abandons the shell AT the source, before the resolver
  # check below can degrade, and no caller can guard it from outside because
  # `bash -n` does not recurse into what a file sources. The restore is
  # conditional rather than a bare `set -e` because this library is sourced by
  # callers that deliberately run without errexit, and arming it in them kills
  # them at their next non-zero command.
  errexit_was=0
  case $- in *e*) errexit_was=1 ;; esac
  set +e
  # shellcheck disable=SC1091
  source "$script_directory/main-root-lib.sh" 2>/dev/null
  if [ "$errexit_was" = 1 ]; then set -e; fi
  main_root="$(gaia_resolve_main_root "$tree_directory")" || return 1
  printf '%s' "$main_root/.gaia/local/$subdirectory"
}

# Echo the main-checkout SPEC directory (.gaia/local/specs) for <tree_directory>.
# The state registry declares specs/ main-only, so "which tree am I in" is never
# the right question for it: callers hand in the tree they are running in and
# this answers with main's. Prints nothing and returns 1 when the resolver
# cannot resolve a main checkout -- callers must refuse rather than fall back to
# the unresolved directory, which is the forked-ledger defect itself.
gaia_resolve_specs_directory() {
  _gaia_resolve_main_local_directory specs "${1:-}"
}

# Echo the main-checkout plan directory (.gaia/local/plans) for <tree_directory>.
# Same contract as gaia_resolve_specs_directory; plans/ is likewise main-only.
gaia_resolve_plans_directory() {
  _gaia_resolve_main_local_directory plans "${1:-}"
}
