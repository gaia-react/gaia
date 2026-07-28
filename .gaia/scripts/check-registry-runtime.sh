#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check C -- registry <-> runtime directory (state-registry conformance
# model, foundations task 2.3, design analysis/registry-design.md §4.4).
#
# LOCAL ONLY. `.gaia/local/` is gitignored and empty (or absent) on a CI
# checkout, so this check is meaningless there (D-024) -- it runs against
# real, on-disk state, as a session-start or on-demand hook, never as a CI
# gate.
#
# Contract (SPEC-061 UAT-006, the report-not-delete rule; D-019's adopter
# valve): ALWAYS report, NEVER delete or block. A real child matching a live
# registry entry (via gaia_registry_classify) is conformant. A child
# matching the registry's `residue` block is known dead-feature residue --
# reported, "the residue phase owns removal", never treated as drift. A
# child matching nothing is unknown -- reported, never reaped, never
# blocking. This holds identically whether the checkout is this repo (where
# the registry is complete by construction, so an unknown child is real
# drift worth fixing) or an adopter clone (where it is likely the adopter's
# own state) -- the check cannot tell those apart, so its behavior is the
# same in both (design §4.4).
#
# Recursion rule: a filesystem node classifies via gaia_registry_classify.
# When a DIRECTORY classifies as anything other than "unknown", the whole
# subtree under it is one recognized unit (a `match: prefix` entry, e.g.
# red-ledger/, forensics/, cache/shared/) and recursion stops there -- its
# individual files are not walked or reported. When a directory classifies
# "unknown", it is a plain container (e.g. the bare top-level audit/, cache/,
# debt/, telemetry/ dirs, whose registry entries describe specific children,
# not the bare directory) and the walk recurses into it. A FILE that
# classifies "unknown" is a genuine leaf with no registry match and is
# reported as such. This means only leaves and prefix-matched subtree roots
# ever appear in the report; a plain container directory never does.
#
# Ephemeral entries (S2-F20): this check only ever reports what EXISTS on
# disk, never what is missing, so an ephemeral pattern's absence is never
# treated as drift -- that guarantee falls out of the walk-what-exists
# design rather than needing a special case.
#
# Dual-mode: source it for gaia_check_registry_runtime, or run it directly
# (see "Executable entry" at the bottom).
#
# gaia_check_registry_runtime [local_dir]
#   Walks <local_dir> (default: the MAIN checkout's .gaia/local/, located via
#   gaia_resolve_main_root -- never re-derived by this script) and prints one
#   line per reported node (CONFORMANT: / RESIDUE: / UNKNOWN:, see above),
#   then a one-line summary. ALWAYS returns 0 -- report-not-delete is a
#   status contract, not just a behavioral one; a caller that wants to key
#   off "were there unknowns" greps the summary line, it never gets a
#   nonzero exit to branch on. Prints one line and returns 0 (nothing to
#   report) when <local_dir> does not exist.

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/state-registry-lib.sh"
# shellcheck disable=SC1091
source "$SELF_DIR/main-root-lib.sh"

# _gaia_checkc_walk <dir> <relprefix>: recursive worker, see the recursion
# rule in the header comment. Prints report lines to stdout.
_gaia_checkc_walk() {
  local dir="$1" relprefix="$2"
  local child name relpath kind scope
  while IFS= read -r child; do
    [ -n "$child" ] || continue
    name="$(basename "$child")"
    if [ -n "$relprefix" ]; then
      relpath="$relprefix/$name"
    else
      relpath="$name"
    fi
    if [ -d "$child" ]; then kind=d; else kind=f; fi
    scope="$(gaia_registry_classify "$relpath" 2>/dev/null)"
    case "$scope" in
      unknown)
        if [ "$kind" = d ]; then
          _gaia_checkc_walk "$child" "$relpath"
        else
          printf 'UNKNOWN: %s (file, not reaped, reported only)\n' "$relpath"
        fi
        ;;
      residue)
        printf 'RESIDUE: %s (known dead-feature residue; the residue phase owns removal)\n' "$relpath"
        ;;
      *)
        printf 'CONFORMANT: %s (%s)\n' "$relpath" "$scope"
        ;;
    esac
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sort)
}

gaia_check_registry_runtime() {
  local local_dir="${1:-}"
  if [ -z "$local_dir" ]; then
    local main_root
    main_root="$(gaia_resolve_main_root)" || return 1
    local_dir="$main_root/.gaia/local"
  fi
  if [ ! -d "$local_dir" ]; then
    printf 'gaia_check_registry_runtime: %s does not exist -- nothing to report\n' "$local_dir"
    return 0
  fi

  local report
  report="$(_gaia_checkc_walk "$local_dir" "")"
  [ -n "$report" ] && printf '%s\n' "$report"

  local conformant_count residue_count unknown_count
  conformant_count="$(grep -c '^CONFORMANT: ' <<<"$report" || true)"
  residue_count="$(grep -c '^RESIDUE: ' <<<"$report" || true)"
  unknown_count="$(grep -c '^UNKNOWN: ' <<<"$report" || true)"
  printf 'summary: %d conformant, %d known-residue, %d unknown (report-only; never deleted or blocked)\n' \
    "$conformant_count" "$residue_count" "$unknown_count"
  return 0
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  gaia_check_registry_runtime "${1:-}"
  exit 0
fi
