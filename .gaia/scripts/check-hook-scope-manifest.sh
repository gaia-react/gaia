#!/usr/bin/env bash
# shellcheck shell=bash
#
# Check D -- the hook tree-scope manifest's own conformance (INV-5, task 3.6
# design analysis/task-3.6-hook-scope-design.md §7).
#
# Over TRACKED SOURCE: the manifest (.gaia/hook-scopes.json) declares, for
# every GAIA hook under .claude/hooks/**, which tree its state belongs to
# (main-only / per-tree / any). Four assertions:
#
#   1. Coverage    every .sh under .claude/hooks/** has exactly one manifest
#                  entry with a valid scope; no orphan entries (a `hook` path
#                  that does not exist on disk); no duplicates.
#   2. Schema      the manifest and its schema are valid JSON; every `state`
#                  token is either a real .gaia/state-registry.json entry id
#                  or a well-formed `path:<repo-relative-path>` token.
#   3. Derive arm  for every entry whose `state` includes a REGISTRY id
#                  (never a bare `path:` token) classified main-only, shared,
#                  or per-tree in the registry, the hook contains no BARE
#                  `.gaia/local` literal (one not immediately preceded by a
#                  path-join character, i.e. reached without a resolved-root
#                  variable) -- and, when it holds any live `.gaia/local`
#                  reference at all, it names a resolver-backed lib
#                  (main-root-lib.sh, state-registry-lib.sh,
#                  gaia-active-plan.sh, red-ledger.sh, ledger-path-lib.sh, or
#                  gh-artifact-lib.sh) so the joined root traces back to one.
#                  An entry whose `state` holds only `path:` tokens (Pattern
#                  D, a tracked per-checkout working file with no registry
#                  entry) is exempt -- there is no `.gaia/local` root to
#                  derive.
#   4. Any honesty every scope: any entry's hook contains no live
#                  `.gaia/local` reference at all (a comment mention is
#                  allowed; a bare or resolved literal is not), so an `any`
#                  declaration cannot silently go stale when a hook later
#                  grows a state access.
#
# Reuses check-registry-source-literals.sh's comment-line classifier rather
# than writing a second one (assertion 3/4's "skip comment lines" logic).
#
# Dual-mode, mirroring the repo's other check/lib scripts: source it for the
# four functions below, or run it directly (see "Executable entry" at the
# bottom).

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SELF_DIR/check-registry-source-literals.sh"

GAIA_HOOKCHECK_MANIFEST_REL=".gaia/hook-scopes.json"
GAIA_HOOKCHECK_SCHEMA_REL=".gaia/hook-scopes.schema.json"
GAIA_HOOKCHECK_REGISTRY_REL=".gaia/state-registry.json"

# Libs whose presence, alongside a resolved (non-bare) .gaia/local reference,
# counts as "this hook derives its root from a resolver" for assertion 3 --
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
# this is the "sh" arm of check-registry-source-literals.sh's own
# per-tier classifier, factored out rather than re-sourcing that function
# under a new name.
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

# gaia_check_hook_manifest_coverage <repo_root>
#   Assertion 1. Every .sh under .claude/hooks/** has exactly one manifest
#   entry with a valid scope; every manifest `hook` path exists on disk; no
#   duplicate entries.
gaia_check_hook_manifest_coverage() {
  local repo_root="${1:?gaia_check_hook_manifest_coverage requires a repo_root argument}"
  local manifest="$repo_root/$GAIA_HOOKCHECK_MANIFEST_REL"
  command -v jq >/dev/null 2>&1 || { printf 'coverage: jq not found\n'; return 1; }
  [ -f "$manifest" ] || { printf 'coverage: manifest not found at %s\n' "$manifest"; return 1; }

  local rc=0 fs_list manifest_list total

  fs_list="$(cd "$repo_root" && find .claude/hooks -name '*.sh' | sort)"
  manifest_list="$(jq -r '.hooks[].hook' "$manifest" | sort)"
  total="$(printf '%s\n' "$fs_list" | grep -c .)"

  local missing
  missing="$(comm -23 <(printf '%s\n' "$fs_list") <(printf '%s\n' "$manifest_list"))"
  if [ -n "$missing" ]; then
    printf 'COVERAGE: missing manifest entry for:\n%s\n' "$missing"
    rc=1
  fi

  local h
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ -f "$repo_root/$h" ] || {
      printf 'COVERAGE: orphan manifest entry (no such file): %s\n' "$h"
      rc=1
    }
  done < <(jq -r '.hooks[].hook' "$manifest")

  local dupes
  dupes="$(printf '%s\n' "$manifest_list" | uniq -d)"
  if [ -n "$dupes" ]; then
    printf 'COVERAGE: duplicate manifest entries for:\n%s\n' "$dupes"
    rc=1
  fi

  local bad_scope
  bad_scope="$(jq -r '.hooks[] | select(.scope != "main-only" and .scope != "per-tree" and .scope != "any") | .hook' "$manifest")"
  if [ -n "$bad_scope" ]; then
    printf 'COVERAGE: invalid scope for:\n%s\n' "$bad_scope"
    rc=1
  fi

  [ "$rc" -eq 0 ] && printf 'coverage: all %s hooks present, no orphans, no duplicates\n' "$total"
  return $rc
}

# gaia_check_hook_manifest_schema <repo_root>
#   Assertion 2. The manifest and schema are valid JSON; every `state` token
#   is a known registry id or a well-formed `path:<repo-relative-path>`
#   token (no validator dependency; direct jq, matching this repo's own
#   state-registry-lib.bats convention).
gaia_check_hook_manifest_schema() {
  local repo_root="${1:?gaia_check_hook_manifest_schema requires a repo_root argument}"
  local manifest="$repo_root/$GAIA_HOOKCHECK_MANIFEST_REL"
  local schema="$repo_root/$GAIA_HOOKCHECK_SCHEMA_REL"
  local registry="$repo_root/$GAIA_HOOKCHECK_REGISTRY_REL"
  command -v jq >/dev/null 2>&1 || { printf 'schema: jq not found\n'; return 1; }

  jq empty "$manifest" 2>/dev/null || { printf 'schema: %s is not valid JSON\n' "$manifest"; return 1; }
  jq empty "$schema" 2>/dev/null || { printf 'schema: %s is not valid JSON\n' "$schema"; return 1; }
  jq empty "$registry" 2>/dev/null || { printf 'schema: %s is not valid JSON\n' "$registry"; return 1; }

  local rc=0

  local bad_path
  bad_path="$(jq -r '.hooks[] | select(.hook | test("^\\.claude/hooks/.+\\.sh$") | not) | .hook' "$manifest")"
  if [ -n "$bad_path" ]; then
    printf 'schema: malformed hook path(s):\n%s\n' "$bad_path"
    rc=1
  fi

  local missing_fields
  missing_fields="$(jq -r '.hooks[] | select((has("hook") and has("scope") and has("state") and has("why")) | not) | (.hook // "?")' "$manifest")"
  if [ -n "$missing_fields" ]; then
    printf 'schema: entry missing a required field:\n%s\n' "$missing_fields"
    rc=1
  fi

  local known_ids
  known_ids="$(jq -r '.entries[].id' "$registry")"

  local bad_state=""
  local hook_path token
  while IFS=$'\t' read -r hook_path token; do
    [ -n "$token" ] || continue
    case "$token" in
      path:?*) continue ;;
    esac
    if ! grep -qxF -- "$token" <<<"$known_ids"; then
      bad_state="${bad_state}${hook_path}: ${token}
"
    fi
  done < <(jq -r '.hooks[] | .hook as $h | (.state // [])[] | "\($h)\t\(.)"' "$manifest")
  if [ -n "$bad_state" ]; then
    printf 'schema: unrecognized state token(s):\n%s' "$bad_state"
    rc=1
  fi

  [ "$rc" -eq 0 ] && printf 'schema: manifest + schema valid JSON; every state token is a known registry id or a well-formed path: token\n'
  return $rc
}

# gaia_check_hook_manifest_derive_arm <repo_root>
#   Assertion 3. For every entry whose `state` includes a registry id
#   classified main-only, shared, or per-tree (a bare `path:` token never
#   counts), the hook has no bare `.gaia/local` literal, and, when it holds
#   any live reference at all, names a resolver-backed lib.
gaia_check_hook_manifest_derive_arm() {
  local repo_root="${1:?gaia_check_hook_manifest_derive_arm requires a repo_root argument}"
  local manifest="$repo_root/$GAIA_HOOKCHECK_MANIFEST_REL"
  local registry="$repo_root/$GAIA_HOOKCHECK_REGISTRY_REL"
  command -v jq >/dev/null 2>&1 || { printf 'derive arm: jq not found\n'; return 1; }

  # <id>\t<scope> for every registry entry classified main-only/shared/per-tree.
  local qualifying_ids
  qualifying_ids="$(jq -r '.entries[] | select(.scope == "main-only" or .scope == "shared" or .scope == "per-tree") | .id' "$registry")"

  local rc=0 hook_path state_json has_qualifying tok
  while IFS=$'\t' read -r hook_path state_json; do
    [ -n "$hook_path" ] || continue
    has_qualifying=0
    while IFS= read -r tok; do
      [ -n "$tok" ] || continue
      case "$tok" in
        path:?*) continue ;;
      esac
      grep -qxF -- "$tok" <<<"$qualifying_ids" && has_qualifying=1
    done < <(jq -r '.[]' <<<"$state_json")
    [ "$has_qualifying" -eq 1 ] || continue

    local bare
    bare="$(_gaia_hookcheck_bare_local_refs "$repo_root" "$hook_path")"
    if [ -n "$bare" ]; then
      printf 'DERIVE ARM: bare .gaia/local literal in %s:\n%s\n' "$hook_path" "$bare"
      rc=1
      continue
    fi

    local live
    live="$(_gaia_hookcheck_live_local_refs "$repo_root" "$hook_path")"
    if [ -n "$live" ] && ! _gaia_hookcheck_names_resolver_lib "$repo_root" "$hook_path"; then
      printf 'DERIVE ARM: %s holds a resolved .gaia/local reference but names no resolver-backed lib\n' "$hook_path"
      rc=1
    fi
  done < <(jq -r '.hooks[] | [.hook, (.state // [] | tostring)] | @tsv' "$manifest")

  [ "$rc" -eq 0 ] && printf 'derive arm: every main-only/shared/per-tree-backed entry is bare-literal-free and resolver-backed\n'
  return $rc
}

# gaia_check_hook_manifest_any_honesty <repo_root>
#   Assertion 4. Every scope: any entry's hook holds no BARE .gaia/local
#   literal (a comment mention is allowed, and so is a reference reached
#   through a caller-supplied root parameter -- e.g. lib/audit-clearance.sh's
#   `${root}/.gaia/local/audit/...`, where <root> is always the CALLER's
#   resolved root, never derived here; this file has no resolver call to
#   make, which is exactly what scope: any records). A hook that grows a
#   genuinely bare, self-derived literal trips this the same way the derive
#   arm catches one in a main-only/per-tree entry.
gaia_check_hook_manifest_any_honesty() {
  local repo_root="${1:?gaia_check_hook_manifest_any_honesty requires a repo_root argument}"
  local manifest="$repo_root/$GAIA_HOOKCHECK_MANIFEST_REL"
  command -v jq >/dev/null 2>&1 || { printf 'any honesty: jq not found\n'; return 1; }

  local rc=0 hook_path bare
  while IFS= read -r hook_path; do
    [ -n "$hook_path" ] || continue
    bare="$(_gaia_hookcheck_bare_local_refs "$repo_root" "$hook_path")"
    if [ -n "$bare" ]; then
      printf 'ANY HONESTY: %s is declared scope=any but holds a bare .gaia/local literal:\n%s\n' "$hook_path" "$bare"
      rc=1
    fi
  done < <(jq -r '.hooks[] | select(.scope == "any") | .hook' "$manifest")

  [ "$rc" -eq 0 ] && printf 'any honesty: every scope=any entry holds no bare .gaia/local literal\n'
  return $rc
}

# gaia_check_hook_scope_manifest <repo_root>
#   Runs all four assertions; returns 0 iff all pass.
gaia_check_hook_scope_manifest() {
  local repo_root="${1:?gaia_check_hook_scope_manifest requires a repo_root argument}"
  local rc=0
  gaia_check_hook_manifest_coverage "$repo_root" || rc=1
  gaia_check_hook_manifest_schema "$repo_root" || rc=1
  gaia_check_hook_manifest_derive_arm "$repo_root" || rc=1
  gaia_check_hook_manifest_any_honesty "$repo_root" || rc=1
  return $rc
}

# Executable entry.
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
