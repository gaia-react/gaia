#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check D -- hooks reach .gaia/local only through a resolved root (INV-5).
#
# A hook that builds a .gaia/local path from a bare literal resolves it
# against whatever tree the hook happens to run in, so from inside a linked
# worktree a write meant for one tree lands in another with no error. Scans
# every .sh under .claude/hooks/** directly. Two assertions, both in
# gaia_check_hook_scope_manifest:
#
#   1. No bare literal   no hook holds a live `.gaia/local` reference that is
#                        not immediately preceded by a path-join character,
#                        i.e. one reached without a resolved-root variable. A
#                        comment mention is allowed.
#   2. Resolver-backed   every hook outside .claude/hooks/lib/ that holds any
#                        live `.gaia/local` reference names a resolver-backed
#                        lib (main-root-lib.sh, state-registry-lib.sh,
#                        gaia-active-plan.sh, red-ledger.sh, ledger-path-lib.sh,
#                        or gh-artifact-lib.sh), so the joined root traces back
#                        to one. A sourced lib under .claude/hooks/lib/ may
#                        instead take its root from its caller, as
#                        lib/audit-clearance.sh's `${root}/.gaia/local/audit`
#                        does, so it is held to assertion 1 only.
#
# Dual-mode, mirroring the repo's other check/lib scripts: source it for
# gaia_check_hook_scope_manifest, or run it directly.

# Libs whose presence, alongside a resolved (non-bare) .gaia/local reference,
# counts as "this hook derives its root from a resolver" for assertion 2 --
# the hook may source main-root-lib.sh directly, or inherit an already-
# resolver-backed helper (state-registry-lib.sh, gaia-active-plan.sh,
# red-ledger.sh, ledger-path-lib.sh, gh-artifact-lib.sh) rather than
# re-sourcing the resolver itself.
GAIA_HOOKCHECK_RESOLVER_LIBS=(
  "main-root-lib.sh"
  "state-registry-lib.sh"
  "gaia-active-plan.sh"
  "red-ledger.sh"
  "ledger-path-lib.sh"
  "gh-artifact-lib.sh"
)

# _gaia_hookcheck_is_comment_line <line>: true when <line>, trimmed of
# leading whitespace, is a bash comment line. Every hook here is shell, so
# this is a shell-only classifier rather than the per-tier one the registry
# checks need, and it is defined here rather than sourced so this check
# stands alone.
_gaia_hookcheck_is_comment_line() {
  local line="$1" trimmed
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [[ "$trimmed" == \#* ]]
}

# _gaia_hookcheck_live_local_refs <repo_root> <hook_relpath>: prints one
# "file:line" per NON-COMMENT line in <hook_relpath> that mentions the
# literal ".gaia/local" (bare or resolved). Empty output means the file
# holds no live reference at all.
_gaia_hookcheck_live_local_refs() {
  local repo_root="$1" rel="$2" file ln text
  file="$repo_root/$rel"
  [ -f "$file" ] || return 0
  while IFS=: read -r ln text; do
    [ -n "$ln" ] || continue
    _gaia_hookcheck_is_comment_line "$text" && continue
    printf '%s:%s\n' "$rel" "$ln"
  done < <(grep -n -F '.gaia/local' "$file" 2>/dev/null)
}

# _gaia_hookcheck_bare_local_refs <repo_root> <hook_relpath>: prints one
# "file:line" per NON-COMMENT live reference that is BARE -- the literal
# ".gaia/local" not immediately preceded by "/" or "\" (a resolved-root join,
# e.g. "$main_root/.gaia/local/...", always has "/" directly before it; a
# sed/grep regex pattern matching path SHAPE, e.g. 's#.*/\.gaia/local/...#',
# always has the escaped "\." there, and is parsing an already-resolved
# string rather than constructing one; a bare literal like
# ".gaia/local/audit/x.jsonl" has neither). Empty output means every live
# reference in the file is resolved-root-joined or a structural regex match.
_gaia_hookcheck_bare_local_refs() {
  local repo_root="$1" rel="$2" file ln text
  file="$repo_root/$rel"
  [ -f "$file" ] || return 0
  while IFS=: read -r ln text; do
    [ -n "$ln" ] || continue
    _gaia_hookcheck_is_comment_line "$text" && continue
    grep -qE '(^|[^/\\])\.gaia/local' <<<"$text" && printf '%s:%s\n' "$rel" "$ln"
  done < <(grep -n -F '.gaia/local' "$file" 2>/dev/null)
}

# _gaia_hookcheck_names_resolver_lib <repo_root> <hook_relpath>: exit 0 iff
# the file mentions at least one of GAIA_HOOKCHECK_RESOLVER_LIBS by name.
_gaia_hookcheck_names_resolver_lib() {
  local repo_root="$1" rel="$2" file lib
  file="$repo_root/$rel"
  [ -f "$file" ] || return 1
  for lib in "${GAIA_HOOKCHECK_RESOLVER_LIBS[@]}"; do
    grep -qF -- "$lib" "$file" 2>/dev/null && return 0
  done
  return 1
}

# gaia_check_hook_scope_manifest <repo_root>
#   Runs both assertions over every .sh under <repo_root>/.claude/hooks/**;
#   returns 0 iff both pass for every hook.
gaia_check_hook_scope_manifest() {
  local repo_root="${1:?gaia_check_hook_scope_manifest requires a repo_root argument}"
  [ -d "$repo_root/.claude/hooks" ] || {
    printf 'hook scope: no .claude/hooks directory under %s\n' "$repo_root"
    return 1
  }

  local rc=0 total=0 hook_path bare live
  while IFS= read -r hook_path; do
    [ -n "$hook_path" ] || continue
    total=$((total + 1))

    bare="$(_gaia_hookcheck_bare_local_refs "$repo_root" "$hook_path")"
    if [ -n "$bare" ]; then
      printf 'BARE LITERAL: %s builds a .gaia/local path without a resolved root; join it to a root from main-root-lib.sh (or a caller-supplied root in a lib):\n%s\n' "$hook_path" "$bare"
      rc=1
      continue
    fi

    case "$hook_path" in
      .claude/hooks/lib/*) continue ;;
    esac
    live="$(_gaia_hookcheck_live_local_refs "$repo_root" "$hook_path")"
    if [ -n "$live" ] && ! _gaia_hookcheck_names_resolver_lib "$repo_root" "$hook_path"; then
      printf 'NO RESOLVER: %s holds a resolved .gaia/local reference but names no resolver-backed lib; source main-root-lib.sh and derive the root with gaia_resolve_main_root\n' "$hook_path"
      rc=1
    fi
  done < <(cd "$repo_root" && find .claude/hooks -name '*.sh' | sort)

  if [ "$total" -eq 0 ]; then
    printf 'hook scope: no hooks found under %s/.claude/hooks\n' "$repo_root"
    return 1
  fi
  [ "$rc" -eq 0 ] && printf 'hook scope: all %s hooks reach .gaia/local only through a resolved root\n' "$total"
  return $rc
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_root="${1:-}"
  if [ -z "$repo_root" ]; then
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
      printf 'check-hook-scope-manifest: not a git repository and no repo_root argument given\n' >&2
      exit 2
    }
  fi
  gaia_check_hook_scope_manifest "$repo_root"
  exit $?
fi
