# shellcheck shell=bash
# GAIA shared cost-ledger-path lib (single-sourced).
# Sourced by token-tally.sh, token-rollup.sh, and token-rollup-merge.sh. Defines
# the one main-checkout ledger-path derivation so the ledger filename lives in a
# single place: renaming it later changes one definition, not three.
# No side effects at source time; defines one function.

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
