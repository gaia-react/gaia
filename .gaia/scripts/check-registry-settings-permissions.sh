#!/usr/bin/env bash
# shellcheck shell=bash
#
# settings.json <-> registry permission conformance check (task 3.4, the
# third of D-009's enumerating copies -- after the janitor allowlists
# (task 3.1/2.3) and block-rm-rf's whitelist (task 3.3), now converted).
#
# .claude/settings.json is static JSON the Claude Code harness reads at
# startup; nothing at runtime can read the registry and inject permission
# rules, so this is a CHECK (fails on drift), not a generator and not a
# runtime read like the other converted consumers. The permission rules
# encode operational policy (which command, which glob shape) the registry
# does not hold, so the rules stay hand-authored literals -- what this check
# removes is the unverified drift: a `.gaia/local` subtree named in
# settings.json that the registry no longer recognizes (renamed, removed, or
# never existed).
#
# One direction only: settings.json rule -> registry. There is no registry
# -> rule direction; most registry entries deliberately carry no permission
# rule.
#
# Altitude: BASE SUBTREE, not full glob. The enumeration hazard is
# subtree-level (settings.json independently listing .gaia/local areas), so
# recognizing the base (e.g. "cache" for "cache/*") is the check that
# matters. Finer glob-vs-entry conformance is Check B's job over runtime
# writers (check-registry-source-literals.sh); duplicating it here is scope
# this task does not own.
#
# Dual-mode: source it for the function below, or run it directly (see
# "Executable entry" at the bottom).
#
# gaia_check_registry_settings_permissions <repo_root>
#   Reads .permissions.allow[] and .permissions.deny[] from
#   <repo_root>/.claude/settings.json. For each rule string, extracts every
#   `.gaia/local/<subpath>` occurrence, reduces it to its base subtree
#   (segments up to the first glob-metacharacter segment; a rule whose
#   subpath is empty or begins with a glob is a generic grant and is
#   skipped), and asserts gaia_registry_recognizes <base> d. Prints one
#   `UNRECOGNIZED: <rule> (base <base>)` line per violation. Returns
#   non-zero iff any base was unrecognized; prints an all-clear summary line
#   and returns 0 otherwise. Requires jq (via state-registry-lib.sh).

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/state-registry-lib.sh"

# _gaia_checkperm_base_subtree <subpath>
#   Prints the base subtree of <subpath> (the "/"-joined segments up to, not
#   including, the first segment that contains a glob metacharacter: *, ?,
#   or [). Returns 1 (nothing printed) when <subpath> is empty or its FIRST
#   segment is itself a glob -- both are generic grants with no census
#   member to drift against, so the caller skips them.
_gaia_checkperm_base_subtree() {
  local subpath="$1"
  [ -n "$subpath" ] || return 1
  local saved_ifs="$IFS"
  IFS='/'
  local -a segs
  read -ra segs <<<"$subpath"
  IFS="$saved_ifs"
  local seg base=""
  for seg in "${segs[@]}"; do
    case "$seg" in
      *'*'*) break ;;
      *'?'*) break ;;
      *'['*) break ;;
    esac
    if [ -z "$base" ]; then
      base="$seg"
    else
      base="$base/$seg"
    fi
  done
  [ -n "$base" ] || return 1
  printf '%s\n' "$base"
}

# gaia_check_registry_settings_permissions <repo_root>: see the header
# contract above.
gaia_check_registry_settings_permissions() {
  local repo_root="${1:?gaia_check_registry_settings_permissions requires a repo_root argument}"
  local settings="$repo_root/.claude/settings.json"

  if ! command -v jq >/dev/null 2>&1; then
    printf 'gaia_check_registry_settings_permissions: jq not found on PATH\n' >&2
    return 1
  fi
  if [ ! -f "$settings" ]; then
    printf 'gaia_check_registry_settings_permissions: no settings file at %s\n' "$settings" >&2
    return 1
  fi

  # Fail CLOSED on an unresolvable registry. gaia_registry_recognizes is
  # fail-OPEN by contract (returns "recognized" when the registry cannot be
  # resolved), which is the wrong direction for a gate: without this guard a
  # phantom subtree would green vacuously whenever the registry is missing.
  # Resolve it once up front and refuse, mirroring the fail-closed posture of
  # gaia_check_registry_no_phantom_entries (Check B, direction 2).
  if ! gaia_registry_path >/dev/null 2>&1; then
    printf 'gaia_check_registry_settings_permissions: state registry unresolvable\n' >&2
    return 1
  fi

  local rules
  rules="$(jq -r '(.permissions.allow // [])[], (.permissions.deny // [])[]' "$settings")" || return 1

  # `.gaia/local/<subpath>` occurrence pattern: runs from the literal
  # ".gaia/local/" to the first ")", quote, or whitespace -- the shapes the
  # harness's own rule strings use (e.g. "Bash(rm -rf .gaia/local/cache/*)",
  # "Edit(.gaia/local/audit/*.ok)").
  local pattern="\.gaia/local/[^)\"'[:space:]]*"

  local rc=0 rule occ subpath base
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    while IFS= read -r occ; do
      [ -n "$occ" ] || continue
      subpath="${occ#.gaia/local/}"
      base="$(_gaia_checkperm_base_subtree "$subpath")" || continue
      if ! gaia_registry_recognizes "$base" d; then
        printf 'UNRECOGNIZED: %s (base %s)\n' "$rule" "$base"
        rc=1
      fi
    done < <(grep -oE -- "$pattern" <<<"$rule")
  done <<<"$rules"

  if [ "$rc" -eq 0 ]; then
    printf 'settings.json permissions: every .gaia/local base subtree is registry-recognized\n'
  fi
  return $rc
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-registry-settings-permissions: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_registry_settings_permissions "$repo_root"
  exit $?
fi
