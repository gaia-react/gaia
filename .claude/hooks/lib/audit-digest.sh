#!/usr/bin/env bash
# audit-digest.sh: the single per-member digest derive point for the Code Audit
# Team gate. Sourced, never executed; does no work at source time.
#
# Branch-own digest (recipe-version sentinel `gaia-audit-digest-v2`), the marker
# key. The marker's meaning, in one sentence: "It attests that you reviewed this
# branch's own change to the paths your digest covers, measured against the PR's
# base branch as GitHub reports it, so content the base brought in is trusted as
# already audited, and any change to the branch's own patch on those paths,
# including one made inside a merge commit or a line moved without change,
# rotates your digest and you must re-audit."
#
# The member's selection is shared gate machinery, the member's owned paths, and
# for the default member the
# in-scope-but-ownerless paths outside the out-of-scope allowlist, each decided
# ENTIRELY by the ownership classifier and the machinery matcher, never by git
# pathspec. It is applied to the paths of the branch's own patch
# `merge-base..target` instead of every tracked file. Each selected path
# contributes its branch-own identity (the recipe is stated in
# audit-branch-patch.sh's header); the framed `<identity> <path>` records are
# `LC_ALL=C sort -z`ed, prefixed with the sentinel and the branch key, and the
# sha256 of that stream is the digest. The branch key (the branch half of the
# artifact key) is in the frame so a marker earned on one branch never validates
# another, even when two branches carry byte-identical or empty patches. A
# catch-up merge of the base leaves the branch's own patch unchanged and so
# rotates nothing, bar a base edit within three lines of a branch hunk; a base-side roster, classifier or machinery change rotates
# exactly the members whose selection of the branch's paths it moved.
#
# NUL-safety is scoped to the hash input: the -z walk, pinned quoting, and
# `LC_ALL=C sort -z` framing make the hash input unambiguous, so no path name
# (including one embedding a space or another shell metacharacter) can shift the
# sha256 input. The membership CLASSIFICATION step reuses the batch classifiers,
# which read newline-delimited stdin; a path whose name embeds a literal newline
# is mis-split there (out-of-fixture / best-effort). The classifier's newline
# semantics are not changed here.
#
# Fail-closed: a missing sha256 tool, an unloadable library, an undeterminable
# branch key, a failing identity or git listing, a roster with no auditors, and
# a classifier that returns a different number of lines than paths each emit
# NOTHING and return non-zero. Never a partial, empty, or weak digest that could
# key or match a marker. The digest needs git + a sha256 tool + the libraries it
# loads; it does NOT need jq.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`, no
# `${var^^}`. Never `cd` (outside the source-time lib resolution below).

# Resolve the sibling libs from THIS file's on-disk location, never cwd, never a
# caller $root, so a run from a scratch sandbox finds the real modules. `|| true`
# on the `cd` command substitution: a failing command substitution in a plain
# assignment trips errexit in a caller running under `set -e`.
_audit_digest_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
if [ -n "${_audit_digest_library_directory:-}" ]; then
  # Suspend errexit across the loads, then RESTORE WHAT WAS THERE. A sibling
  # module that is present but unparseable abandons the shell AT the source, so
  # an `-f` test ahead of it proves nothing and no caller can guard it from
  # outside -- `bash -n` does not recurse into what a file sources. The restore
  # is conditional rather than a bare `set -e` because this library is sourced
  # by callers that deliberately run without errexit, and arming it in them
  # kills them at their next non-zero command.
  _audit_digest_errexit_was=0
  case $- in *e*) _audit_digest_errexit_was=1 ;; esac
  set +e
  # shellcheck source=/dev/null
  [ -f "$_audit_digest_library_directory/audit-scope.sh" ] && . "$_audit_digest_library_directory/audit-scope.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_audit_digest_library_directory/audit-machinery.sh" ] && . "$_audit_digest_library_directory/audit-machinery.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_audit_digest_library_directory/audit-branch-patch.sh" ] && . "$_audit_digest_library_directory/audit-branch-patch.sh" 2>/dev/null
  # shellcheck source=/dev/null
  [ -f "$_audit_digest_library_directory/audit-base-provenance.sh" ] && . "$_audit_digest_library_directory/audit-base-provenance.sh" 2>/dev/null
  # The key library is located from this file, never cwd, like its siblings.
  # shellcheck source=/dev/null
  [ -f "$_audit_digest_library_directory/../../../.gaia/scripts/audit-key-lib.sh" ] && . "$_audit_digest_library_directory/../../../.gaia/scripts/audit-key-lib.sh" 2>/dev/null
  if [ "$_audit_digest_errexit_was" = 1 ]; then set -e; fi
  unset _audit_digest_errexit_was
fi

# _audit_sha256_hex: reads stdin, prints the 64-hex sha256 on stdout; returns
# non-zero if no sha256 tool is available.
_audit_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1; exit}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1; exit}'
  else
    return 1
  fi
}

# _audit_digest_load_roster: sets _AUDIT_DIGEST_ROSTER to the unique roster
# members, the default member first, from the state audit_scope_init populated.
# Non-zero when the roster is empty. A specialist appears once per glob in
# _AUDIT_SCOPE_SPEC_MEMBER, so it is deduplicated here.
_audit_digest_load_roster() {
  local default_member="${_AUDIT_SCOPE_DEFAULT_MEMBER:-}" spec_index=0 spec_member seen roster_index
  _AUDIT_DIGEST_ROSTER=()
  [ -n "$default_member" ] && _AUDIT_DIGEST_ROSTER[${#_AUDIT_DIGEST_ROSTER[@]}]="$default_member"
  while [ "$spec_index" -lt "${_AUDIT_SCOPE_SPEC_COUNT:-0}" ]; do
    spec_member="${_AUDIT_SCOPE_SPEC_MEMBER[$spec_index]}"
    seen=0
    roster_index=0
    while [ "$roster_index" -lt "${#_AUDIT_DIGEST_ROSTER[@]}" ]; do
      [ "${_AUDIT_DIGEST_ROSTER[$roster_index]}" = "$spec_member" ] && { seen=1; break; }
      roster_index=$((roster_index + 1))
    done
    [ "$seen" -eq 0 ] && _AUDIT_DIGEST_ROSTER[${#_AUDIT_DIGEST_ROSTER[@]}]="$spec_member"
    spec_index=$((spec_index + 1))
  done
  [ "${#_AUDIT_DIGEST_ROSTER[@]}" -gt 0 ]
}

# _audit_branch_digests_compute <root> <merge-base> <target> <work directory>:
# writes every member's `<member>\t<digest>` line to <work>/lines and prints
# nothing, so a failure at any point leaves the caller with no output.
_audit_branch_digests_compute() {
  local root="$1" merge_base="$2" target="$3" work="$4"

  # Fail closed: the classifier, the machinery matcher, the identity library
  # and the branch key must all be loaded.
  command -v audit_scope_init >/dev/null 2>&1 || return 1
  command -v audit_owners_for_paths >/dev/null 2>&1 || return 1
  command -v audit_machinery_flags >/dev/null 2>&1 || return 1
  command -v audit_out_of_scope_allowlisted >/dev/null 2>&1 || return 1
  command -v audit_branch_patch_identities >/dev/null 2>&1 || return 1
  command -v gaia_branch_slug >/dev/null 2>&1 || return 1

  # Checked once up front so the whole call is atomic.
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    return 1
  fi

  audit_scope_init "$root" || return 1
  _audit_digest_load_roster || return 1

  local branch_key
  branch_key="$(gaia_branch_slug "$root" 2>/dev/null)" || return 1
  [ -n "$branch_key" ] || return 1

  # One identity listing for the whole call. The records go to a file because a
  # bash variable cannot hold NUL bytes, which also lets a failing listing be
  # caught by its exit status; an empty patch (exit 0, no records) is not one.
  audit_branch_patch_identities "$root" "$merge_base" "$target" >"$work/identities" 2>/dev/null || return 1

  local record identity path
  local D_PATH=() D_IDENTITY=()
  local paths_newline_separated=""
  while IFS= read -r -d '' record; do
    identity="${record%%$'\t'*}"
    path="${record#*$'\t'}"
    [ "$path" != "$record" ] || return 1
    case "$identity" in
      *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#identity}" -eq 64 ] || return 1
    D_PATH[${#D_PATH[@]}]="$path"
    D_IDENTITY[${#D_IDENTITY[@]}]="$identity"
    paths_newline_separated="${paths_newline_separated}${path}"$'\n'
  done <"$work/identities"

  local path_count=${#D_PATH[@]}

  # Batch owner + machinery classification, aligned line-for-line to the arrays.
  # A count mismatch means a path whose name embeds a newline (out-of-fixture /
  # best-effort); rather than hash a mis-aligned set, fail closed.
  local D_OWNER=() D_MACHINERY=()
  local line
  if [ "$path_count" -gt 0 ]; then
    while IFS= read -r line; do
      D_OWNER[${#D_OWNER[@]}]="${line##*$'\t'}"
    done < <(printf '%s' "$paths_newline_separated" | audit_owners_for_paths)
    while IFS= read -r line; do
      D_MACHINERY[${#D_MACHINERY[@]}]="${line##*$'\t'}"
    done < <(printf '%s' "$paths_newline_separated" | audit_machinery_flags)
  fi
  if [ "${#D_OWNER[@]}" -ne "$path_count" ] || [ "${#D_MACHINERY[@]}" -ne "$path_count" ]; then
    return 1
  fi

  # Per member: select its records into a frame file, then hash the sentinel,
  # the branch key and the sorted frame. The `$(( ))` increments stay OUTSIDE the
  # hashing command substitution: bash 3.2's parser miscounts parens when
  # `$(( ))` sits inside `$( )`.
  local default_member="${_AUDIT_SCOPE_DEFAULT_MEMBER:-}"
  local member digest j owner is_machinery selected member_index=0
  : >"$work/lines" || return 1
  while [ "$member_index" -lt "${#_AUDIT_DIGEST_ROSTER[@]}" ]; do
    member="${_AUDIT_DIGEST_ROSTER[$member_index]}"
    : >"$work/frame" || return 1
    j=0
    while [ "$j" -lt "$path_count" ]; do
      owner="${D_OWNER[$j]}"
      is_machinery="${D_MACHINERY[$j]}"
      selected=0
      if [ "$is_machinery" = "1" ]; then
        selected=1
      elif [ "$owner" = "$member" ]; then
        selected=1
      elif [ "$member" = "$default_member" ] && [ "$owner" = "-" ]; then
        # In-scope-but-ownerless folds into the default member's set.
        if ! audit_out_of_scope_allowlisted "${D_PATH[$j]}"; then
          selected=1
        fi
      fi
      if [ "$selected" = "1" ]; then
        printf '%s %s\0' "${D_IDENTITY[$j]}" "${D_PATH[$j]}" >>"$work/frame" || return 1
      fi
      j=$((j + 1))
    done

    digest="$( { printf 'gaia-audit-digest-v2\0%s\0' "$branch_key"; LC_ALL=C sort -z <"$work/frame"; } | _audit_sha256_hex )"
    case "$digest" in
      *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#digest}" -eq 64 ] || return 1

    printf '%s\t%s\n' "$member" "$digest" >>"$work/lines" || return 1
    member_index=$((member_index + 1))
  done
}

# audit_branch_digests_all <root> <merge-base> [<target-tree-ish>=HEAD]: prints
# one `<member>\t<digest>` branch-own digest line per roster member. Atomic:
# every fail-closed condition prints nothing and returns non-zero.
audit_branch_digests_all() {
  local root="${1:-}" merge_base="${2:-}" target="${3:-HEAD}" work status=0
  [ -n "$root" ] && [ -n "$merge_base" ] || return 1
  work="$(mktemp -d 2>/dev/null)" || return 1
  _audit_branch_digests_compute "$root" "$merge_base" "$target" "$work" || status=1
  if [ "$status" -eq 0 ]; then
    cat "$work/lines" || status=1
  fi
  rm -rf "$work"
  return "$status"
}

# audit_branch_member_digest <root> <member> <merge-base> [<target-tree-ish>]:
# one member's branch-own digest, or nothing and non-zero.
audit_branch_member_digest() {
  local root="${1:-}" member="${2:-}" merge_base="${3:-}" target="${4:-HEAD}"
  local all line line_member line_digest

  all="$(audit_branch_digests_all "$root" "$merge_base" "$target")" || return 1

  while IFS= read -r line; do
    line_member="${line%%$'\t'*}"
    if [ "$line_member" = "$member" ]; then
      line_digest="${line#*$'\t'}"
      [ -n "$line_digest" ] || return 1
      printf '%s\n' "$line_digest"
      return 0
    fi
  done <<EOF
$all
EOF

  return 1
}

# audit_branch_digests_local <root> [<target-tree-ish>=HEAD]: the branch-own
# digests against the local base reference. The merge base comes from HEAD,
# never from the target, so a bare tree id still measures against the branch's
# own base. Returns 3 (more than one merge base) and 4 (base tip not a commit
# present locally) from the merge-base derivation, and 1 when no local base
# reference resolves.
audit_branch_digests_local() {
  local root="${1:-}" target="${2:-HEAD}" reference merge_base status=0
  [ -n "$root" ] || return 1
  command -v audit_local_base_reference >/dev/null 2>&1 || return 1
  command -v audit_branch_patch_merge_base >/dev/null 2>&1 || return 1

  reference="$(audit_local_base_reference "$root")" || return 1
  [ -n "$reference" ] || return 1
  merge_base="$(audit_branch_patch_merge_base "$root" "$reference" HEAD)" || status=$?
  [ "$status" -eq 0 ] || return "$status"
  [ -n "$merge_base" ] || return 1

  audit_branch_digests_all "$root" "$merge_base" "$target"
}
