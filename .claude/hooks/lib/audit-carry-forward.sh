#!/usr/bin/env bash
# audit-carry-forward.sh: the carry-forward predicate for the Code Audit Team.
# Sourced, never executed; does no work at source time. PURE: it reads, it
# never writes. The minting authority (.claude/hooks/pr-merge-audit-check.sh)
# and the spawn optimization (.gaia/scripts/resolve-audit-spawn.sh) both consult
# it; neither this file nor its callers-via-this-file ever mint a clearance.
#
# A member's clearance is keyed to the whole root tree, which is far coarser
# than what the member actually read. This predicate lets a member's earned
# clearance carry forward from a tree it audited (the ANCHOR) to a new tree
# (HEAD) whenever the delta between the two touches nothing that member owns and
# nothing about the audit machinery has changed. It is a PRE-clearance: it can
# spare a member from being spawned, and it can NEVER shrink the set of members
# the merge gate demands.
#
#   cf_enabled                                              exit 0 iff jq is on PATH
#   cf_select_anchor <root> <member> <head_tree>            anchor tree sha on stdout, or empty
#   cf_may_carry <root> <member> <anchor_tree> <head_tree>  exit 0 = may carry; 1 = refuse
#
# stdout is a hard contract every caller parses unconditionally, so NO reason is
# ever written to stdout. Every refusal and every candidate drop names its
# reason on stderr.
#
# This raises no security bar. The machinery guard cannot defeat an actor who
# can rewrite the working tree, and neither can any other part of the local
# merge gate; the pool's write-integrity weakness is a separate, still-open
# concern this file does not close.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`,
# no `${var^^}`. Never `cd`.

# Resolve the sibling libs from THIS file's on-disk location, never cwd, never
# $repo_root, so a run from a scratch sandbox finds the real modules. `|| true`
# on the `cd` command substitution: a failing command substitution in a plain
# assignment trips errexit in a caller running under `set -e`.
_cf_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
if [ -n "$_cf_lib_dir" ]; then
  if [ -f "$_cf_lib_dir/audit-scope.sh" ]; then
    # shellcheck source=/dev/null
    . "$_cf_lib_dir/audit-scope.sh"
  fi
  if [ -f "$_cf_lib_dir/audit-machinery.sh" ]; then
    # shellcheck source=/dev/null
    . "$_cf_lib_dir/audit-machinery.sh"
  fi
  if [ -f "$_cf_lib_dir/audit-clearance.sh" ]; then
    # shellcheck source=/dev/null
    . "$_cf_lib_dir/audit-clearance.sh"
  fi
fi

# The default member owns the infix-free clearance filename family.
CF_DEFAULT_MEMBER="code-audit-frontend"

# --- Stderr reason logging ---------------------------------------------------
#
# A member REFUSAL and the exhaustion of every candidate both use `declined`;
# an intermediate candidate drop that is not itself a refusal reason (a tree
# object absent from the DB, a non-ancestor cross-branch anchor) uses `drop`.

_cf_declined() { printf 'carry-forward: declined %s: %s\n' "$1" "$2" >&2; }
_cf_drop() { printf 'carry-forward: drop %s: %s\n' "$1" "$2" >&2; }

# --- cf_enabled --------------------------------------------------------------
#
# Carry-forward reads marker bodies, which needs jq. jq absent disables the
# whole feature and degrades to today's behavior (spawn everyone), which is
# safe. The caller emits the single `carry-forward: disabled: jq not found`
# stderr line; this predicate only answers the question.

cf_enabled() {
  command -v jq >/dev/null 2>&1
}

# --- Internal helpers --------------------------------------------------------

# _cf_version <root>: the .gaia/VERSION literal under root, trimmed.
_cf_version() {
  local vf="$1/.gaia/VERSION" v=""
  if [ -f "$vf" ]; then
    v="$(tr -d '\r' < "$vf" 2>/dev/null | awk 'NF{print; exit}')"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
  fi
  printf '%s' "$v"
}

# _cf_is_hex40 <s>: exit 0 iff s is exactly 40 lowercase-hex characters.
_cf_is_hex40() {
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Init the ownership classifier ONCE per run (never once per path). The guard
# makes repeated cf_may_carry calls across a member set re-parse the roster at
# most once for a given root.
_cf_scope_init_once() {
  local root="$1"
  [ "${_CF_SCOPE_INITED_ROOT:-}" = "$root" ] && return 0
  command -v audit_scope_init >/dev/null 2>&1 || return 0
  audit_scope_init "$root"
  _CF_SCOPE_INITED_ROOT="$root"
}

# --- cf_select_anchor <root> <member> <head_tree> ----------------------------
#
# Prints the chosen anchor tree sha on stdout (empty when none), and logs every
# unusable candidate and the final no-anchor refusal on stderr. Always exit 0.
#
# Total order over a capped candidate set, cheapest filter first (free file
# reads before git forks):
#   1. Candidates: the member's earned clearances in the pool (never a
#      .carried). Default member -> <tree>.ok; specialized -> <tree>.<m>.ok.
#   2. Free filters (jq body read): provenance == earned; version equals the
#      current .gaia/VERSION literal; the filename key equals the body tree; the
#      body member matches. A recorded sidecar:true with no sidecar file on disk
#      drops the candidate (sidecar-missing).
#   3. Rank by audited_at descending; take at most the newest 10, BEFORE any
#      git diff fan-out.
#   4. For each survivor: the recorded tree object must still exist (folded into
#      the git diff, which fails on a bad object); a non-ancestor candidate with
#      a NON-empty sidecar is dropped.
#   5. Among survivors: fewest changed paths in the delta to HEAD's tree; ties
#      by newest audited_at; ties by lexicographically smallest tree sha.
#
# The cap is free by soundness: cf_may_carry re-checks the guard on whatever
# anchor is chosen, so discarding a candidate can only cost a carry, never grant
# a false one.
cf_select_anchor() {
  local root="$1" member="$2" head_tree="$3"
  local audit_dir="$root/.gaia/local/audit"
  local version head_sha survivors="" f base key fields
  local c_prov c_ver c_tree c_member c_sha c_sidecar c_epoch

  if [ ! -d "$audit_dir" ]; then
    _cf_declined "$member" "no-anchor"
    return 0
  fi

  version="$(_cf_version "$root")"
  head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"

  # --- Collect candidates that pass the free (fork-free) filters -------------
  if [ "$member" = "$CF_DEFAULT_MEMBER" ]; then
    for f in "$audit_dir"/*.ok; do
      [ -e "$f" ] || continue
      base="${f##*/}"
      key="${base%.ok}"
      # A member-infixed filename carries a dot in the stripped stem; skip it,
      # the default member owns only the infix-free family.
      case "$key" in *.*) continue ;; esac
      _cf_is_hex40 "$key" || continue
      _cf_collect_candidate "$member" "$f" "$key" "$version" "$audit_dir" || continue
      survivors="${survivors}${_CF_CAND_LINE}
"
    done
  else
    for f in "$audit_dir"/*."$member".ok; do
      [ -e "$f" ] || continue
      base="${f##*/}"
      key="${base%".$member.ok"}"
      _cf_is_hex40 "$key" || continue
      _cf_collect_candidate "$member" "$f" "$key" "$version" "$audit_dir" || continue
      survivors="${survivors}${_CF_CAND_LINE}
"
    done
  fi

  if [ -z "$survivors" ]; then
    _cf_declined "$member" "no-anchor"
    return 0
  fi

  # --- Rank by audited_at desc, cap to the newest 10, THEN pay git forks ------
  # Internal records are `|`-delimited: `|` is non-whitespace, so `read` never
  # collapses an empty field the way a tab (an IFS whitespace char) would.
  local top scored="" s_epoch s_tree s_sha s_sidecar delta count sc nonempty best_tree
  top="$(printf '%s' "$survivors" | LC_ALL=C sort -t'|' -k1,1nr -k2,2 | head -10 || true)"

  while IFS='|' read -r s_epoch s_tree s_sha s_sidecar; do
    [ -n "$s_tree" ] || continue
    # Tree object existence is folded into the diff: git diff fails on a bad
    # object, which drops the candidate.
    if ! delta="$(git -C "$root" diff --name-only "$s_tree" "$head_tree" 2>/dev/null)"; then
      _cf_drop "$member" "tree-object-absent $s_tree"
      continue
    fi
    # A non-ancestor cross-branch anchor whose sidecar carries real findings is
    # dropped: importing its filed-issue records into HEAD's sidecar could deny
    # a merge whose operator cannot clear them.
    if [ "$s_sidecar" = "true" ] && [ -n "$s_sha" ]; then
      sc="$audit_dir/${s_sha}.dispositions.json"
      nonempty="$(jq -r 'if ((.findings // []) | length) > 0 then "y" else "n" end' "$sc" 2>/dev/null || echo n)"
      if [ "$nonempty" = "y" ] && [ -n "$head_sha" ]; then
        if ! git -C "$root" merge-base --is-ancestor "$s_sha" "$head_sha" 2>/dev/null; then
          _cf_drop "$member" "non-ancestor $s_tree"
          continue
        fi
      fi
    fi
    count="$(printf '%s\n' "$delta" | grep -c . 2>/dev/null || true)"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    scored="${scored}${count}|${s_epoch}|${s_tree}
"
  done <<EOF
$top
EOF

  if [ -z "$scored" ]; then
    _cf_declined "$member" "no-anchor"
    return 0
  fi

  # Fewest changed paths, then newest audited_at, then smallest tree sha.
  best_tree="$(printf '%s' "$scored" | LC_ALL=C sort -t'|' -k1,1n -k2,2nr -k3,3 | head -1 | cut -d'|' -f3 || true)"
  if [ -z "$best_tree" ]; then
    _cf_declined "$member" "no-anchor"
    return 0
  fi
  printf '%s\n' "$best_tree"
  return 0
}

# _cf_collect_candidate <member> <file> <key> <version> <audit_dir>
# Applies the free filters + the fork-free sidecar-missing drop. On success sets
# _CF_CAND_LINE to "<epoch>\t<tree>\t<sha>\t<sidecar>" and returns 0; on a drop
# it logs the reason and returns 1.
_cf_collect_candidate() {
  local member="$1" f="$2" key="$3" version="$4" audit_dir="$5"
  local fields c_prov c_ver c_tree c_member c_sha c_sidecar c_epoch sc

  # Fields joined by `|` (not @tsv): `read` collapses empty fields when the
  # delimiter is a tab (an IFS whitespace char), which would shift every field
  # left when a legacy marker's version is empty. `|` is non-whitespace, and no
  # field value here (provenance, semver, hex, member name, true/false, digits)
  # ever contains one.
  fields="$(jq -r '[
      (.provenance // ""),
      (.version // ""),
      (.tree // ""),
      (.member // ""),
      (.sha // ""),
      ((.sidecar // false) | tostring),
      ((.audited_at // "") | if . == "" then "" else (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | tostring) catch "") end)
    ] | join("|")' "$f" 2>/dev/null || true)"
  if [ -z "$fields" ]; then
    _cf_declined "$member" "unparseable-marker $f"
    return 1
  fi
  IFS='|' read -r c_prov c_ver c_tree c_member c_sha c_sidecar c_epoch <<EOF
$fields
EOF
  if [ "$c_prov" != "earned" ]; then
    _cf_declined "$member" "unparseable-marker $f"
    return 1
  fi
  if [ "$c_ver" != "$version" ]; then
    _cf_declined "$member" "version-mismatch ${c_ver:-<none>} want ${version:-<none>}"
    return 1
  fi
  if [ "$c_tree" != "$key" ]; then
    _cf_declined "$member" "tree-mismatch $f"
    return 1
  fi
  if [ "$c_member" != "$member" ]; then
    _cf_declined "$member" "unparseable-marker $f"
    return 1
  fi
  if [ "$c_sidecar" = "true" ] && [ -n "$c_sha" ]; then
    sc="$audit_dir/${c_sha}.dispositions.json"
    if [ ! -f "$sc" ]; then
      _cf_declined "$member" "sidecar-missing $sc"
      return 1
    fi
  fi
  case "$c_epoch" in ''|*[!0-9]*) c_epoch=0 ;; esac
  _CF_CAND_LINE="${c_epoch}|${key}|${c_sha}|${c_sidecar}"
  return 0
}

# --- cf_may_carry <root> <member> <anchor_tree> <head_tree> ------------------
#
# Evaluated on the anchor-to-HEAD delta (tree-to-tree, never a commit range:
# two trees have no merge base, and byte-identical owned paths transfer a
# verdict regardless of lineage). Returns 0 = may carry; 1 = refuse (reason on
# stderr). A refusal spawns that member, does not affect its siblings, and never
# aborts the run.
cf_may_carry() {
  local root="$1" member="$2" anchor_tree="$3" head_tree="$4"
  local delta hit owners path owner

  if ! delta="$(git -C "$root" diff --name-only "$anchor_tree" "$head_tree" 2>/dev/null)"; then
    _cf_declined "$member" "no-anchor"
    return 1
  fi

  _cf_scope_init_once "$root"

  # 1. The machinery guard. Any machinery path in the delta refuses.
  hit="$(printf '%s\n' "$delta" | audit_delta_has_machinery 2>/dev/null || true)"
  if [ -n "$hit" ]; then
    _cf_declined "$member" "machinery $hit"
    return 1
  fi

  # 2. Ownership. Any delta path this member owns refuses, naming the first.
  owners="$(printf '%s\n' "$delta" | audit_owners_for_paths 2>/dev/null || true)"
  while IFS="$(printf '\t')" read -r path owner; do
    [ -n "$path" ] || continue
    if [ "$owner" = "$member" ]; then
      _cf_declined "$member" "owns-changed-path $path"
      return 1
    fi
  done <<EOF
$owners
EOF

  # 3. Ownerless-in-scope, default member only. A path the merge gate treats as
  # in scope (not out-of-scope-allowlisted) but owned by nobody must never be
  # satisfied by a carried default-member clearance.
  if [ "$member" = "$CF_DEFAULT_MEMBER" ]; then
    while IFS="$(printf '\t')" read -r path owner; do
      [ -n "$path" ] || continue
      if [ "$owner" = "-" ] && ! audit_out_of_scope_allowlisted "$path"; then
        _cf_declined "$member" "ownerless-in-scope $path"
        return 1
      fi
    done <<EOF
$owners
EOF
  fi

  # 4. Refuse to carry past a live refusal of the exact tree being merged.
  if command -v clearance_member_refused >/dev/null 2>&1 \
     && clearance_member_refused "$root" "$head_tree" "$member"; then
    _cf_declined "$member" "refused-tree $head_tree"
    return 1
  fi

  return 0
}
