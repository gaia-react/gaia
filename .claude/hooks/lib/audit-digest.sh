#!/usr/bin/env bash
# audit-digest.sh: the single per-member content-digest derive point for the
# Code Audit Team gate. Sourced, never executed; does no work at source time.
#
# A member's clearance is keyed to a content digest over exactly the files that
# member owns plus the shared gate machinery (plus the in-scope-but-ownerless
# paths for the default member), rather than a digest of the whole repository
# tree. An unrelated or out-of-glob change moves no member's digest; an
# owned-file change rotates only that member's digest; a machinery-file change
# rotates every member's digest. Membership is decided ENTIRELY by the existing
# ownership classifier and machinery matcher, never by git pathspec.
#
# Recipe (recipe-version sentinel `gaia-audit-digest-v1`):
#   git -C <root> -c core.quotepath=false ls-tree -z -r <ref> yields NUL-
#   terminated `<mode> SP <type> SP <object> TAB <path>` records for every
#   tracked file. Classify each path once through the classifier; select the
#   member's set; frame each selected record as `<mode> <object> <path>`, emit
#   NUL-delimited, `LC_ALL=C sort -z`, prefix the fixed sentinel, and sha256 the
#   NUL-delimited stream. The 64-hex sha256 is the digest.
#
# NUL-safety is scoped to the hash input: the -z walk, pinned quoting, and
# `LC_ALL=C sort -z` framing make the hash input unambiguous, so no path name
# (including one embedding a space or another shell metacharacter) can shift the
# sha256 input. The membership CLASSIFICATION step reuses the batch classifiers,
# which read newline-delimited stdin; a path whose name embeds a literal newline
# is mis-split there (out-of-fixture / best-effort). The classifier's newline
# semantics are not changed here.
#
# Fail-closed: a missing sha256 tool, an unloadable classifier/machinery lib, or
# a failing `git ls-tree` (invalid ref, git absent, not a repo) emits NOTHING
# and returns non-zero. Never a partial, empty, or weak digest that could key or
# match a marker. The digest needs git + a sha256 tool + the classifier libs; it
# does NOT need jq.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`, no
# `${var^^}`. Never `cd` (outside the source-time lib resolution below).

# Resolve the sibling libs from THIS file's on-disk location, never cwd, never a
# caller $root, so a run from a scratch sandbox finds the real modules. `|| true`
# on the `cd` command substitution: a failing command substitution in a plain
# assignment trips errexit in a caller running under `set -e`.
_audit_digest_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || true
if [ -n "${_audit_digest_lib_dir:-}" ]; then
  if [ -f "$_audit_digest_lib_dir/audit-scope.sh" ]; then
    # shellcheck source=/dev/null
    . "$_audit_digest_lib_dir/audit-scope.sh"
  fi
  if [ -f "$_audit_digest_lib_dir/audit-machinery.sh" ]; then
    # shellcheck source=/dev/null
    . "$_audit_digest_lib_dir/audit-machinery.sh"
  fi
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

# audit_digests_all <root> [<ref>]
#
# The single-walk / single-classify batch form (directive PERF-001). Prints one
# `<member>\t<digest>` line per roster member (the default member and every
# specialist audit_scope_init populated). Fail-closed conditions emit NOTHING
# and return non-zero, atomically (never some members and not others).
audit_digests_all() {
  local root="$1" ref="${2:-HEAD}"

  # Fail closed: the classifier + machinery batch predicates must be loaded.
  command -v audit_scope_init >/dev/null 2>&1 || return 1
  command -v audit_owners_for_paths >/dev/null 2>&1 || return 1
  command -v audit_machinery_flags >/dev/null 2>&1 || return 1
  command -v audit_out_of_scope_allowlisted >/dev/null 2>&1 || return 1

  # Fail closed: a sha256 tool must exist. Checked ONCE up front so the whole
  # call is atomic (never emit some members' digests and then fail on another).
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    return 1
  fi

  audit_scope_init "$root"

  # Single ls-tree walk. A bash variable cannot hold the NUL bytes `-z` emits
  # (command substitution strips them), so the records go to a temp file that
  # preserves them AND lets us fail closed on a non-zero git exit. An empty tree
  # (exit 0, no records) is NOT fail-closed.
  local tmp
  tmp="$(mktemp 2>/dev/null)" || return 1
  if ! git -C "$root" -c core.quotepath=false ls-tree -z -r "$ref" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  # Parallel arrays for the ls-tree fields + a newline path list for the batch
  # classifiers. Split each record at the FIRST tab: `meta` is
  # `<mode> <type> <object>`, `path` is everything after (a path may itself
  # contain a tab, which %%/# split at the first tab handles).
  local record meta path mode rest obj
  local D_PATH=() D_MODE=() D_OBJ=()
  local paths_nl=""
  while IFS= read -r -d '' record; do
    meta="${record%%$'\t'*}"
    path="${record#*$'\t'}"
    mode="${meta%% *}"
    rest="${meta#* }"
    obj="${rest#* }"
    D_PATH[${#D_PATH[@]}]="$path"
    D_MODE[${#D_MODE[@]}]="$mode"
    D_OBJ[${#D_OBJ[@]}]="$obj"
    paths_nl="${paths_nl}${path}"$'\n'
  done <"$tmp"
  rm -f "$tmp"

  local n=${#D_PATH[@]}

  # Batch owner + machinery classification, aligned line-for-line to the arrays.
  # Both classifiers skip empty input lines and preserve order, so the i-th
  # output line describes D_PATH[i]. `printf '%s'` (no trailing newline added)
  # feeds them so the read loop consumes exactly n lines.
  local D_OWNER=() D_MACH=()
  local line
  if [ "$n" -gt 0 ]; then
    while IFS= read -r line; do
      D_OWNER[${#D_OWNER[@]}]="${line##*$'\t'}"
    done < <(printf '%s' "$paths_nl" | audit_owners_for_paths)
    while IFS= read -r line; do
      D_MACH[${#D_MACH[@]}]="${line##*$'\t'}"
    done < <(printf '%s' "$paths_nl" | audit_machinery_flags)
  fi

  # A count mismatch means a classifier saw a different number of lines than the
  # walk produced. The only way that happens is a path whose name embeds a
  # newline (out-of-fixture / best-effort); rather than hash a mis-aligned set,
  # fail closed. Space-containing paths do NOT trip this (no extra newlines).
  if [ "${#D_OWNER[@]}" -ne "$n" ] || [ "${#D_MACH[@]}" -ne "$n" ]; then
    return 1
  fi

  # Unique roster: the default member + each distinct specialist (a specialist
  # appears once per glob in _AUDIT_SCOPE_SPEC_MEMBER, so dedupe).
  local default_member="${_AUDIT_SCOPE_DEFAULT_MEMBER:-}"
  local roster=()
  [ -n "$default_member" ] && roster[${#roster[@]}]="$default_member"
  local si=0 sm seen ri
  while [ "$si" -lt "${_AUDIT_SCOPE_SPEC_COUNT:-0}" ]; do
    sm="${_AUDIT_SCOPE_SPEC_MEMBER[$si]}"
    seen=0
    ri=0
    while [ "$ri" -lt "${#roster[@]}" ]; do
      [ "${roster[$ri]}" = "$sm" ] && { seen=1; break; }
      ri=$((ri + 1))
    done
    [ "$seen" -eq 0 ] && roster[${#roster[@]}]="$sm"
    si=$((si + 1))
  done

  # Per member: select this member's records into a temp file, then frame the
  # digest as `sentinel + LC_ALL=C sort -z of the framed records | sha256`. The
  # selection loop's `$(( ))` increment stays OUTSIDE the digest command
  # substitution: bash 3.2's parser miscounts parens when `$(( ))` sits inside
  # `$( )`, so the substitution that hashes contains no arithmetic and no loop.
  # Accumulate all lines and print only at the end, so any fail-closed return
  # emits nothing.
  local out="" member digest j owner ismach selected mi=0 frametmp
  while [ "$mi" -lt "${#roster[@]}" ]; do
    member="${roster[$mi]}"

    frametmp="$(mktemp 2>/dev/null)" || return 1
    j=0
    while [ "$j" -lt "$n" ]; do
      owner="${D_OWNER[$j]}"
      ismach="${D_MACH[$j]}"
      selected=0
      if [ "$ismach" = "1" ]; then
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
        printf '%s %s %s\0' "${D_MODE[$j]}" "${D_OBJ[$j]}" "${D_PATH[$j]}" >>"$frametmp"
      fi
      j=$((j + 1))
    done

    digest="$( { printf 'gaia-audit-digest-v1\0'; LC_ALL=C sort -z <"$frametmp"; } | _audit_sha256_hex )"
    rm -f "$frametmp"

    # Validate a 64-hex lowercase digest, or fail closed for the whole call
    # (a masked/failing sha256 tool yields an empty or malformed value here).
    case "$digest" in
      *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#digest}" -eq 64 ] || return 1

    out="${out}${member}"$'\t'"${digest}"$'\n'
    mi=$((mi + 1))
  done

  printf '%s' "$out"
  return 0
}

# audit_member_digest <root> <member> [<ref>]
#
# Single-member convenience. Prints the 64-hex digest for <member>, returns 0;
# on any fail-closed condition (or an absent member) emits nothing, returns 1.
# Shares audit_digests_all's single walk and fail-closed posture.
audit_member_digest() {
  local root="$1" member="$2" ref="${3:-HEAD}"
  local all line m d

  all="$(audit_digests_all "$root" "$ref")" || return 1

  while IFS= read -r line; do
    m="${line%%$'\t'*}"
    if [ "$m" = "$member" ]; then
      d="${line#*$'\t'}"
      [ -n "$d" ] || return 1
      printf '%s\n' "$d"
      return 0
    fi
  done <<EOF
$all
EOF

  # Member absent from the roster output: fail closed.
  return 1
}
