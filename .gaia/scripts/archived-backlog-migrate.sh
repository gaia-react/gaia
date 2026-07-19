#!/usr/bin/env bash
# archived-backlog-migrate.sh: one-time, human-gated, fail-closed removal of the
# pre-existing archived spec/plan backlog under .gaia/local/specs/archived and
# .gaia/local/plans/archived.
#
# The durable record for a merged spec or plan lives in the append-only cost
# ledger (cost.jsonl) plus the two id-ledgers (specs/ledger.json,
# plans/ledger.json). The archived folders duplicate it. This migration removes a
# folder only when BOTH gates pass:
#
#   Identity gate       - the folder has a durable id-ledger record at its
#                         terminal status: a specs/ledger.json row at status
#                         merged for a SPEC-<n> folder, or a plans/ledger.json row
#                         at status merged for a PLAN-<n> folder. A legacy
#                         free-form plan slug, or a spec that predates the ledger,
#                         has no durable identity: it classifies NEEDS-DECISION and
#                         is never auto-deleted; a human resolves it (synthesize an
#                         identity row, then re-run; or discard).
#   Representation gate - every cost.md phase section under the folder is
#                         value-represented in cost.jsonl (via
#                         cost_folder_represented). A folder holding an unparseable
#                         or unrepresented phase classifies BLOCKED and is never
#                         deleted.
#
# The migration is verify-only. It reads cost.jsonl but never writes it and never
# runs a backfill. A folder whose vintage cost.md phase has no matching ledger row
# classifies BLOCKED with reason needs-backfill; recovering it is a separate human
# step (run cost-backfill.sh whole-tree once, then re-run this migration).
#
# Usage: archived-backlog-migrate.sh [<repo_root>] [--confirm] [--ledger <path>]
#
#   Default (no --confirm) is a dry run: it prints a per-folder manifest and
#   deletes nothing. Only --confirm deletes, and only folders that pass both gates
#   (classified DELETE). BLOCKED and NEEDS-DECISION folders are never deleted, in
#   either mode.
#
# Guarantees:
#   - Exit code is ALWAYS 0 (advisory / fail-open); never blocks a caller.
#   - stdout carries the per-folder manifest and the summary; diagnostics go to
#     stderr only.
#   - The only mutation is rm -rf of a DELETE folder under --confirm. cost.jsonl is
#     byte-unchanged in both modes.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$here/ledger-path-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/cost-represented.sh
. "$here/cost-represented.sh" 2>/dev/null || true

log() {
  printf '%s\n' "$*" >&2
}

# ---------- args ----------
repo_root=""
ledger_override=""
confirm=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --confirm)
      confirm=1
      shift
      ;;
    --ledger)
      ledger_override="${2:-}"
      shift 2
      ;;
    *)
      if [ -z "$repo_root" ]; then
        repo_root="$1"
      else
        log "archived-backlog-migrate: ignoring unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$repo_root" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$repo_root" ] || repo_root="$PWD"
fi
repo_root="${repo_root%/}"

ledger="$(gaia_resolve_ledger_path "$ledger_override" 2>/dev/null)"
if [ -z "$ledger" ]; then
  log "archived-backlog-migrate: could not resolve cost ledger path; nothing to do"
  exit 0
fi

if ! declare -f cost_folder_represented >/dev/null 2>&1; then
  log "archived-backlog-migrate: cost-represented.sh unavailable; cannot verify representation"
  exit 0
fi

specs_ledger="$repo_root/.gaia/local/specs/ledger.json"
plans_ledger="$repo_root/.gaia/local/plans/ledger.json"

# ledger_status <ledger_json> <id>: prints the row's status for <id>, or nothing
# when the file, the array, or the row is absent. (.specs // .plans) selects
# whichever id-array the ledger carries.
ledger_status() {
  local ledger_json="$1" id="$2"
  [ -f "$ledger_json" ] || return 0
  jq -r --arg id "$id" '((.specs // .plans) // [])[]? | select(.id == $id) | .status' \
    "$ledger_json" 2>/dev/null | head -n1
}

# ---------- classification ----------
count_delete=0
count_blocked=0
count_needs=0
delete_folders=()

REPRESENTED_TAB="$(printf '\tREPRESENTED\t')"
BLOCKING_TAB="$(printf '\tBLOCKING\t')"

if [ "$confirm" -eq 1 ]; then
  log "archived-backlog-migrate: --confirm supplied; DELETE folders will be removed."
else
  log "archived-backlog-migrate: dry run (no --confirm); nothing will be deleted."
fi

# Column header for the per-folder manifest.
printf 'folder\tstatus\tverified\tblocking\treason\n'

# classify_and_print <folder_abs> <tree>: runs the identity gate then, if it
# passes, the representation gate; prints one manifest line; updates the counts
# and the delete list. Runs in the current shell (never a pipe subshell) so its
# global mutations persist.
classify_and_print() {
  local folder_abs="$1" tree="$2"
  local base rel
  base="$(basename "$folder_abs")"
  rel="${folder_abs#"$repo_root"/}"

  local attr_field="" attr_val="" status="" reason="" verified=0 blocking=0

  # ---- identity gate (FC-4) ----
  case "$tree" in
    specs)
      case "$base" in
        SPEC-[0-9]*)
          if [ "$(ledger_status "$specs_ledger" "$base")" = "merged" ]; then
            attr_field="spec_id"
            attr_val="$base"
          else
            status="NEEDS-DECISION"
            reason="no-merged-specs-ledger-row"
          fi
          ;;
        *)
          status="NEEDS-DECISION"
          reason="unrecognized-specs-folder"
          ;;
      esac
      ;;
    plans)
      case "$base" in
        PLAN-[0-9]*)
          if [ "$(ledger_status "$plans_ledger" "$base")" = "merged" ]; then
            attr_field="plan_id"
            attr_val="$base"
          else
            status="NEEDS-DECISION"
            reason="no-merged-plans-ledger-row"
          fi
          ;;
        *)
          status="NEEDS-DECISION"
          reason="legacy-slug-no-durable-identity"
          ;;
      esac
      ;;
  esac

  # ---- representation gate (FC-3), verify-only ----
  if [ -z "$status" ]; then
    local repr_out repr_rc
    repr_out="$(cost_folder_represented "$folder_abs" "$attr_field" "$attr_val" "$ledger" 2>/dev/null)"
    repr_rc=$?
    if [ -n "$repr_out" ]; then
      verified="$(printf '%s\n' "$repr_out" | grep -cF -- "$REPRESENTED_TAB")"
      blocking="$(printf '%s\n' "$repr_out" | grep -cF -- "$BLOCKING_TAB")"
    fi
    if [ "$repr_rc" -eq 0 ]; then
      status="DELETE"
      if [ "$verified" -eq 0 ]; then
        reason="no-cost-to-recover"
      else
        reason="represented"
      fi
    else
      status="BLOCKED"
      if printf '%s\n' "$repr_out" | grep -qF -- "incomplete or non-numeric"; then
        reason="unparseable"
      else
        reason="needs-backfill"
      fi
      # Surface the blocking per-section detail on stderr for a human reviewing.
      printf '%s\n' "$repr_out" | grep -F -- "$BLOCKING_TAB" | while IFS= read -r line; do
        [ -n "$line" ] && log "  [$rel] $line"
      done
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$status" "$verified" "$blocking" "$reason"

  case "$status" in
    DELETE)
      count_delete=$((count_delete + 1))
      delete_folders+=("$folder_abs")
      ;;
    BLOCKED)
      count_blocked=$((count_blocked + 1))
      ;;
    NEEDS-DECISION)
      count_needs=$((count_needs + 1))
      ;;
  esac
}

# Enumerate every folder directly under specs/archived and plans/archived (one
# level; the archived dir itself is ignored). Process substitution keeps the loop
# in the current shell so classify_and_print's global mutations persist.
for tree in specs plans; do
  archived_dir="$repo_root/.gaia/local/$tree/archived"
  [ -d "$archived_dir" ] || continue
  while IFS= read -r -d '' folder; do
    classify_and_print "$folder" "$tree"
  done < <(find "$archived_dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
done

# ---------- delete pass (only under --confirm) ----------
if [ "$confirm" -eq 1 ]; then
  if [ "${#delete_folders[@]}" -gt 0 ]; then
    for folder in ${delete_folders[@]+"${delete_folders[@]}"}; do
      if rm -rf "$folder" 2>/dev/null; then
        printf 'deleted\t%s\n' "${folder#"$repo_root"/}"
      else
        log "archived-backlog-migrate: failed to remove $folder"
      fi
    done
  fi
  printf 'summary: deleted=%d blocked=%d needs-decision=%d\n' \
    "$count_delete" "$count_blocked" "$count_needs"
else
  printf 'summary (dry-run): delete=%d blocked=%d needs-decision=%d (re-run with --confirm to delete)\n' \
    "$count_delete" "$count_blocked" "$count_needs"
fi

exit 0
