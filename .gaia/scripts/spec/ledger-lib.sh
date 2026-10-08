# shellcheck shell=bash
# Shared ledger helpers for the specs and plans ledgers. Sourced, never run:
# it defines functions and nothing else, and sources nothing itself. The caller
# loads .gaia/scripts/ledger-path-lib.sh before calling gaia_ledger_directory,
# which returns non-zero when the resolver functions are absent.
#
# Public functions:
#   gaia_ledger_kind_for_id <id>                  spec | plan, else nothing + 2
#   gaia_ledger_directory <kind> <repo_root>      main-checkout ledger directory
#   gaia_ledger_array_key <kind>                  specs | plans
#   gaia_ledger_status_allowed <kind> <status>    0 when canonical for the kind
#   gaia_ledger_age_past_window <iso> <now_epoch> <retention_days>
#                                                 0 only for a parseable timestamp
#                                                 at least retention_days old

gaia_ledger_kind_for_id() {
  case "${1:-}" in
    SPEC-*[!0-9]* | PLAN-*[!0-9]* | SPEC- | PLAN-) return 2 ;;
    SPEC-*) printf 'spec' ;;
    PLAN-*) printf 'plan' ;;
    *) return 2 ;;
  esac
}

gaia_ledger_directory() {
  local kind="${1:-}" repo_root="${2:-}" directory
  case "$kind" in
    spec)
      type gaia_resolve_specs_directory >/dev/null 2>&1 || return 1
      directory="$(gaia_resolve_specs_directory "$repo_root" 2>/dev/null)" || return 1
      ;;
    plan)
      type gaia_resolve_plans_directory >/dev/null 2>&1 || return 1
      directory="$(gaia_resolve_plans_directory "$repo_root" 2>/dev/null)" || return 1
      ;;
    *) return 1 ;;
  esac
  [ -n "$directory" ] || return 1
  printf '%s' "$directory"
}

gaia_ledger_array_key() {
  case "${1:-}" in
    spec) printf 'specs' ;;
    plan) printf 'plans' ;;
    *) return 1 ;;
  esac
}

gaia_ledger_status_allowed() {
  case "${1:-}:${2:-}" in
    spec:draft | spec:ready | spec:merged | spec:abandoned) return 0 ;;
    plan:ready | plan:merged | plan:abandoned) return 0 ;;
    *) return 1 ;;
  esac
}

# A missing or unparseable timestamp never reads as infinitely old, so bad
# input keeps the folder rather than authorizing a delete.
gaia_ledger_age_past_window() {
  local iso="${1:-}" now_epoch="${2:-}" retention_days="${3:-}" stamped_epoch age_days
  [ -n "$iso" ] || return 1
  case "$now_epoch" in '' | *[!0-9]*) return 1 ;; esac
  case "$retention_days" in '' | *[!0-9]*) return 1 ;; esac
  [ "$now_epoch" -gt 0 ] || return 1
  stamped_epoch="$(jq -rn --arg iso_timestamp "$iso" '($iso_timestamp | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)' 2>/dev/null || true)"
  case "$stamped_epoch" in '' | *[!0-9]*) return 1 ;; esac
  age_days=$(( (now_epoch - stamped_epoch) / 86400 ))
  [ "$age_days" -ge "$retention_days" ]
}
