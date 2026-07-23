#!/usr/bin/env bash
# shellcheck shell=bash
#
# GAIA state-registry reader (single-sourced).
#
# Reads .gaia/state-registry.json, the one classification of every
# .gaia/local entry (SPEC-061), transcribed by hand into the tracked
# .gaia/state-registry.json + .gaia/state-registry.schema.json pair. This
# library is the ONLY place that parses the registry; every consumer (link
# twins, the janitor, conformance checks) calls these functions instead of
# re-reading or hand-restating the registry's shape. Dual-mode, mirroring
# .gaia/scripts/main-root-lib.sh: source it for the reader functions below, or
# run it directly as a script (see "Executable entry" at the bottom).
#
# Location: the registry lives at the MAIN checkout's .gaia/, never a linked
# worktree's (it describes .gaia/local, which cannot live inside what it
# describes). Every function here locates it by sourcing the sibling
# .gaia/scripts/main-root-lib.sh and calling gaia_resolve_main_root -- it
# never re-derives the root itself. Root resolution failure and jq
# unavailability are both surfaced through gaia_registry_path (see below);
# nothing in this file strips git env or re-implements that resolution.
#
# Requires jq (the repo-wide convention for JSON reads in shell). Every
# function guards jq's absence with `command -v jq` before using it.
#
# `path` matching convention (see the registry's own top-level
# "description" and .gaia/state-registry.schema.json for the authoritative
# statement): a `path` may join multiple concrete on-disk shapes with '|'
# (each alternative matched independently under the entry's own `match`);
# and may carry a '<placeholder>' token for a variable path segment. For
# `match: glob` a placeholder is a stand-in for a shell '*' wildcard
# ('audit/<digest>.ok' names the same shape as 'audit/*.ok' -- most entries
# just write the resolved glob directly). For `match: prefix` only the
# literal text before the first '<' matters (or the whole path, trimmed of
# a trailing '/', when it carries no placeholder).
#
# gaia_registry_path
#   Prints the absolute path to <main-root>/.gaia/state-registry.json.
#   FAILURE (registry not locatable, main root unresolvable, or jq missing):
#   prints nothing to stdout, writes ONE diagnostic line to stderr, returns
#   1. This is the STRICT function: callers that need a hard failure (a
#   conformance check, a diagnostic) call it directly. gaia_registry_recognizes
#   below deliberately does NOT propagate this failure -- see its own
#   contract.
#
# gaia_registry_linkable_paths
#   Prints, one per line in a STABLE order, the .gaia/local-relative
#   top-level paths the link twins must symlink into main: every
#   scope=="shared" registry entry's own top-level linkable unit (its own
#   `path`, trimmed, for a match=="prefix" entry; otherwise its `path`'s
#   first "/"-segment), de-duplicated in first-occurrence order. Derived
#   from the registry, never hardcoded; today this is exactly the five
#   link-worktree.sh already symlinks: setup-state.json, cache/shared,
#   audit, telemetry, debt. Prints nothing and returns 1 when the registry
#   cannot be read (see gaia_registry_path).
#
# gaia_registry_main_only_dirs
#   Prints, one per line in a STABLE order, the .gaia/local-relative top-level
#   directory of every scope=="main-only" entry with kind=="dir": the
#   directories wholly anchored to the main checkout. A linked worktree has no
#   own copy of these, so a write to one from a worktree resolves to main by
#   construction and is legitimate, not a wrong-checkout write. The checkout-
#   boundary write-guard reads this (alongside gaia_registry_linkable_paths)
#   to know which main-checkout writes to exempt, instead of hand-listing
#   plans/ and specs/. Kind=="dir" is load-bearing: it keeps a main-only FILE
#   entry (e.g. cache/gh-artifact-pr.json) from exempting its whole first
#   segment (cache/), which also holds per-tree and ephemeral state. Derived
#   from the registry, never hardcoded; today this is specs, plans,
#   worktree-locks. Prints nothing and returns 1 when the registry cannot be
#   read (see gaia_registry_path).
#
# gaia_registry_drop_zones
#   Prints, one per line in registry order, the .gaia/local-relative
#   structural directories the janitor's empty-dir sweep must preserve even
#   when momentarily empty (the drop_zones the registry declares). Derived
#   from the registry, never hardcoded in the janitor. Prints nothing and
#   returns 1 when the registry cannot be read (see gaia_registry_path), so a
#   caller failing to read the list keeps every empty dir rather than rmdir a
#   structural directory it could not classify.
#
# gaia_registry_rm_whitelist
#   Prints, one per line as `path<TAB>children_only` (children_only "true"/"false"),
#   the repo-root-relative safe-scratch directories block-rm-rf.sh carves out of its
#   absolute-path deny. Derived from the registry, never hand-listed in the hook.
#   Prints nothing and returns 1 when the registry cannot be read (see
#   gaia_registry_path), so a caller that cannot read the list treats every path as
#   non-whitelisted -- the safe direction for a deny guard.
#
# gaia_registry_recognizes <relpath> <type: f|d>
#   The janitor's "may I reap this?" predicate. Exit 0 ("recognized",
#   never reap) when <relpath> (a .gaia/local-relative child path) matches
#   a live entry OR a residue-block entry, by that entry's own `match` rule.
#   Exit 1 ("unknown") only when the registry was read successfully and
#   nothing matched.
#   FAILURE CONTRACT (fail-SAFE): when jq is unavailable or the registry
#   cannot be located/read, this returns 0 (recognized), never 1. A caller
#   that cannot classify a child must never reap it -- an unreadable
#   registry is exactly the case SPEC-061's report-not-delete rule exists
#   to protect, and failing shut here would turn a broken registry into an
#   outlier-reap trigger, the opposite of the intended safety property.
#   Residue entries are checked before live entries, so a residue leaf
#   nested under a live subtree (cache/shared/coaching-active.txt under the
#   live cache/shared/ prefix) is reported as residue, not as a live match.
#   Residue entries carry no `kind`, so <type> is not checked against them;
#   it IS checked against live entries (mapping f->file, d->dir).
#   ANCESTOR recognition: a DIRECTORY that is not itself a row is still
#   recognized when it is an ancestor of a registered entry (the bare
#   audit/, cache/, debt/, telemetry/, harden/, audit/security/ containers
#   hold classified children even though the bare directory has no row of its
#   own). Without this the janitor and the runtime check would report every
#   legitimate container as unknown on every session. A file is never a
#   container, so this applies to <type> d (and the untyped case) only.
#
# gaia_registry_classify <relpath>
#   Prints the scope of the matching entry ("shared" / "per-tree" /
#   "main-only" / "ephemeral"), or "residue" for a residue-block match, or
#   "unknown" when nothing matches -- always with exit 0 in those three
#   cases. For diagnostics and conformance checks, not a reap gate: unlike
#   gaia_registry_recognizes, this does NOT fail open. When jq is
#   unavailable or the registry cannot be read, it prints nothing and
#   returns 1.
#
# Usage (sourced):
#   . .gaia/scripts/state-registry-lib.sh
#   registry="$(gaia_registry_path)" || { echo "no registry: $?" >&2; }
#   gaia_registry_linkable_paths
#   if gaia_registry_recognizes "some/child" f; then ...; fi
#   scope="$(gaia_registry_classify "some/child")"
#
# Usage (executable):
#   bash .gaia/scripts/state-registry-lib.sh path                       # gaia_registry_path
#   bash .gaia/scripts/state-registry-lib.sh linkable-paths             # gaia_registry_linkable_paths
#   bash .gaia/scripts/state-registry-lib.sh main-only-dirs             # gaia_registry_main_only_dirs
#   bash .gaia/scripts/state-registry-lib.sh drop-zones                 # gaia_registry_drop_zones
#   bash .gaia/scripts/state-registry-lib.sh rm-whitelist               # gaia_registry_rm_whitelist
#   bash .gaia/scripts/state-registry-lib.sh recognizes <relpath> <f|d> # gaia_registry_recognizes
#   bash .gaia/scripts/state-registry-lib.sh classify <relpath>         # gaia_registry_classify

# gaia_registry_path: see the header contract above.
gaia_registry_path() {
  if ! command -v jq >/dev/null 2>&1; then
    printf 'gaia_registry_path: jq not found on PATH\n' >&2
    return 1
  fi
  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$self_dir/main-root-lib.sh"
  local main_root
  main_root="$(gaia_resolve_main_root)" || {
    printf 'gaia_registry_path: cannot resolve the main checkout root\n' >&2
    return 1
  }
  local registry="$main_root/.gaia/state-registry.json"
  if [ ! -f "$registry" ]; then
    printf 'gaia_registry_path: no registry found at %s\n' "$registry" >&2
    return 1
  fi
  printf '%s\n' "$registry"
  return 0
}

# _gaia_registry_pattern_matches <relpath> <pattern> <matchtype>
# Core matcher shared by gaia_registry_recognizes / gaia_registry_classify.
# <pattern> may be a "|"-joined set of alternatives; each is tested
# independently under <matchtype> ("exact" | "glob" | "prefix"), per the
# convention documented at the top of this file. Returns 0 on the first
# alternative that matches, 1 otherwise.
_gaia_registry_pattern_matches() {
  local relpath="$1" pattern="$2" matchtype="$3"
  local saved_ifs="$IFS"
  IFS='|'
  local -a alts
  read -ra alts <<<"$pattern"
  IFS="$saved_ifs"
  local alt lit lit_trimmed
  for alt in "${alts[@]}"; do
    case "$matchtype" in
      exact)
        [ "$relpath" = "$alt" ] && return 0
        ;;
      glob)
        # Deliberately unquoted: $alt is a shell-glob pattern by contract
        # (registry-authored, not attacker input), and case needs it bare
        # to expand as a glob rather than a literal string.
        # shellcheck disable=SC2254
        case "$relpath" in
          $alt) return 0 ;;
        esac
        ;;
      prefix)
        # Literal text before the first '<' (or the whole alt, unchanged,
        # when it has none). Matches the directory itself with no trailing
        # slash (a caller may hand either form) as well as any child under
        # it.
        lit="${alt%%<*}"
        lit_trimmed="${lit%/}"
        case "$relpath" in
          "$lit_trimmed") return 0 ;;
          "$lit"*) return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

# gaia_registry_linkable_paths: see the header contract above.
gaia_registry_linkable_paths() {
  local registry
  registry="$(gaia_registry_path)" || return 1
  jq -r '
    [
      .entries[]
      | select(.scope == "shared")
      | (if .match == "prefix" then (.path | rtrimstr("/")) else (.path | split("/")[0]) end)
    ]
    | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
    | .[]
  ' "$registry"
}

# gaia_registry_main_only_dirs: see the header contract above.
gaia_registry_main_only_dirs() {
  local registry
  registry="$(gaia_registry_path)" || return 1
  jq -r '
    [
      .entries[]
      | select(.scope == "main-only" and .kind == "dir")
      | (.path | rtrimstr("/") | split("/")[0])
    ]
    | reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)
    | .[]
  ' "$registry"
}

# gaia_registry_drop_zones: see the header contract above.
gaia_registry_drop_zones() {
  local registry
  registry="$(gaia_registry_path)" || return 1
  jq -r '.drop_zones[]?.path' "$registry"
}

# gaia_registry_rm_whitelist: see the header contract above.
gaia_registry_rm_whitelist() {
  local registry
  registry="$(gaia_registry_path)" || return 1
  jq -r '.rm_whitelist[]? | [.path, (.children_only | tostring)] | @tsv' "$registry"
}

# gaia_registry_recognizes <relpath> <type: f|d>: see the header contract above.
gaia_registry_recognizes() {
  local relpath="${1:-}" reqtype="${2:-}"
  [ -n "$relpath" ] || return 0
  local registry
  registry="$(gaia_registry_path 2>/dev/null)" || return 0

  local residue_lines
  residue_lines="$(jq -r '.residue[] | [.match, .path] | @tsv' "$registry" 2>/dev/null)" || return 0
  local m p
  while IFS=$'\t' read -r m p; do
    [ -n "$m" ] || continue
    _gaia_registry_pattern_matches "$relpath" "$p" "$m" && return 0
  done <<<"$residue_lines"

  local want_kind=""
  case "$reqtype" in
    f) want_kind="file" ;;
    d) want_kind="dir" ;;
  esac

  local entry_lines
  entry_lines="$(jq -r --arg k "$want_kind" '
    .entries[] | select($k == "" or .kind == $k) | [.match, .path] | @tsv
  ' "$registry" 2>/dev/null)" || return 0
  while IFS=$'\t' read -r m p; do
    [ -n "$m" ] || continue
    _gaia_registry_pattern_matches "$relpath" "$p" "$m" && return 0
  done <<<"$entry_lines"

  # Ancestor recognition. A directory that is not itself an entry is still
  # recognized when it is an ANCESTOR of a registered entry: .gaia/local/audit
  # holds classified children (audit/*.ok, ...) even though the bare directory
  # is not its own row. Without this, the janitor's outlier sweep and the
  # runtime conformance check would report every legitimate container
  # (audit/, cache/, debt/, telemetry/, harden/, audit/security/) as
  # unrecognized on every session. A file is never a container, so this
  # applies to a directory (and the untyped case) only.
  if [ "$reqtype" != f ]; then
    if jq -e --arg pre "$relpath/" '
      [ (.entries[], .residue[]).path | split("|")[] ] | any(.[]; startswith($pre))
    ' "$registry" >/dev/null 2>&1; then
      return 0
    fi
  fi

  return 1
}

# gaia_registry_classify <relpath>: see the header contract above.
gaia_registry_classify() {
  local relpath="${1:-}"
  [ -n "$relpath" ] || {
    printf 'unknown\n'
    return 0
  }
  local registry
  registry="$(gaia_registry_path 2>/dev/null)" || return 1

  local residue_lines
  residue_lines="$(jq -r '.residue[] | [.match, .path] | @tsv' "$registry" 2>/dev/null)" || return 1
  local m p
  while IFS=$'\t' read -r m p; do
    [ -n "$m" ] || continue
    if _gaia_registry_pattern_matches "$relpath" "$p" "$m"; then
      printf 'residue\n'
      return 0
    fi
  done <<<"$residue_lines"

  local entry_lines scope
  entry_lines="$(jq -r '.entries[] | [.match, .path, .scope] | @tsv' "$registry" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r m p scope; do
    [ -n "$m" ] || continue
    if _gaia_registry_pattern_matches "$relpath" "$p" "$m"; then
      printf '%s\n' "$scope"
      return 0
    fi
  done <<<"$entry_lines"

  printf 'unknown\n'
  return 0
}

# Executable entry.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    path)
      shift
      gaia_registry_path
      exit $?
      ;;
    linkable-paths)
      shift
      gaia_registry_linkable_paths
      exit $?
      ;;
    main-only-dirs)
      shift
      gaia_registry_main_only_dirs
      exit $?
      ;;
    drop-zones)
      shift
      gaia_registry_drop_zones
      exit $?
      ;;
    rm-whitelist)
      shift
      gaia_registry_rm_whitelist
      exit $?
      ;;
    recognizes)
      shift
      gaia_registry_recognizes "${1:-}" "${2:-}"
      exit $?
      ;;
    classify)
      shift
      gaia_registry_classify "${1:-}"
      exit $?
      ;;
    *)
      printf 'usage: %s {path|linkable-paths|main-only-dirs|drop-zones|rm-whitelist|recognizes <relpath> <f|d>|classify <relpath>}\n' "$0" >&2
      exit 2
      ;;
  esac
fi
