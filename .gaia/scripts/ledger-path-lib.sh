# shellcheck shell=bash
# GAIA shared cost-ledger-path lib (single-sourced).
# Sourced by token-tally.sh, token-rollup.sh, and token-rollup-merge.sh. Defines
# the one main-checkout ledger-path derivation so the ledger filename lives in a
# single place: renaming it later changes one definition, not three.
# No side effects at source time; defines one function.

# Echoes the main-checkout cost ledger path; honors an override (test seam).
# main_root = dirname(absolute(git rev-parse --git-common-dir)), so a run inside
# a linked worktree records to the surviving main ledger, not the worktree's
# discarded copy. Returns 1 when git cannot resolve the common dir.
gaia_resolve_ledger_path() {
  local override="${1:-}"
  if [[ -n "$override" ]]; then printf '%s' "$override"; return 0; fi
  local common_dir abs main_root
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
  [[ -z "$common_dir" ]] && return 1
  case "$common_dir" in
    /*) abs="$common_dir" ;;
    *)  abs="$PWD/$common_dir" ;;
  esac
  main_root="$(cd "$(dirname "$abs")" 2>/dev/null && pwd)"
  [[ -z "$main_root" ]] && return 1
  printf '%s' "$main_root/.gaia/local/telemetry/cost.jsonl"
}
