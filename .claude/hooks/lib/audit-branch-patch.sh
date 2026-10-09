#!/usr/bin/env bash
# audit-branch-patch.sh: answers "what is the branch's own change on each path?"
# for the Code Audit Team gate. Sourced, never executed; defines functions only
# and does no work at source time. Bash 3.2 compatible (macOS default), BWK-awk
# safe. Never `cd`.
#
# Trust rule it serves: content reachable from the PR's base branch tip was
# already audited when it merged there, so the gate keys and reviews only the
# branch's own patch, `merge_base(target, base tip)..target`. A catch-up merge
# of the base moves the merge base with it and leaves that patch unchanged; an
# edit made inside a merge commit (a conflict resolution, an evil merge) lands
# in it.
#
# Branch-own identity (the per-path value every consumer keys on), stated here
# once:
#   sha256 over a frame of
#     `path <P>`         P as the symmetric half of git's `diff --git` header:
#                        `a/<path> b/<path>`, or its C-quoted form, which is
#                        injective over path bytes
#     `mode <old> <new>` the raw modes, 000000 on an addition or a deletion
#   then, for a text path, the `-U3` patch body with every hunk header line
#   reduced to `@@` and every other byte verbatim (whitespace, the
#   `\ No newline at end of file` marker); or, for a symlink (120000),
#   a submodule (160000), a typechange, or a path git reports as binary under
#   the pinned flags, `blob <old blob id> <new blob id>`.
#   A typechange's consecutive patch sections fold into one identity.
#
# Why the three lines of context: a context-free identity cannot see a
# resolution that moves an unchanged branch line below the call it guards. The
# accepted cost is that a base edit within three lines of a branch hunk rotates
# that path on a clean catch-up; relocation between byte-identical contexts is
# an accepted residue. Why the whole hunk header goes, not only its line
# numbers: the text after the second `@@` is the nearest preceding
# function-looking line, which a base edit far above the hunk can change.
#
# Return codes for every function taking a <base-tip>: 0 success; 4 the base
# tip is not a commit present locally (next step `git fetch origin`); 3 the
# target has more than one merge base with the tip (next step: merge the base
# branch so the merge base is unique); 1 any other failure. Every failure
# prints nothing on stdout: output is assembled in a temporary file and
# printed only on success.
#
# Pinning. Every git call goes through _audit_branch_patch_git, which runs in a
# subshell that drops the environment variables able to redirect the
# repository, inject configuration or swap history (replace refs, grafts), and
# passes flags and `-c` settings that override every diff-shaping config key
# git reads, so a hostile local config or a tracked `.gitattributes` cannot
# change an identity. Attributes are neutralized with `attr.tree` set to the
# empty tree. Its honest limit: git older than 2.46 ignores that key and
# honors attributes, which can only turn a text path into a binary one; a
# binary path is keyed on blob ids, which rotate on every content change, so
# the residue over-rotates and never hides an edit. `$GIT_DIR/info/attributes`
# is local operator state and is read on every git version.

# Empty tree id: the attribute source that has no `.gitattributes` at all.
_AUDIT_BRANCH_PATCH_EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

# _audit_branch_patch_git <root> <git arguments...>: the one git entry point.
# The scrub happens in the subshell, never in the caller's shell.
_audit_branch_patch_git() (
  root="$1"
  shift
  unset GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EXTERNAL_DIFF GIT_DIFF_OPTS \
    GIT_REPLACE_REF_BASE GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE \
    GIT_ATTR_SOURCE GIT_CONFIG
  for name in ${!GIT_CONFIG_KEY_*} ${!GIT_CONFIG_VALUE_*}; do
    unset "$name"
  done
  GIT_NO_REPLACE_OBJECTS=1
  GIT_GRAFT_FILE=/dev/null
  GIT_OPTIONAL_LOCKS=0
  export GIT_NO_REPLACE_OBJECTS GIT_GRAFT_FILE GIT_OPTIONAL_LOCKS
  exec git -C "$root" --no-replace-objects --literal-pathspecs \
    -c core.quotepath=false \
    -c core.bigFileThreshold=1g \
    -c core.attributesFile=/dev/null \
    -c attr.tree="$_AUDIT_BRANCH_PATCH_EMPTY_TREE" \
    -c diff.orderFile=/dev/null \
    -c diff.suppressBlankEmpty=false \
    -c diff.interHunkContext=0 \
    -c diff.indentHeuristic=true \
    -c diff.noprefix=false \
    -c diff.mnemonicPrefix=false \
    -c diff.submodule=short \
    -c color.ui=false \
    -c log.showSignature=false \
    "$@"
)

# Flags for every patch this file generates. The context width is the one
# literal the relocation guard depends on.
_audit_branch_patch_diff_flags() {
  printf '%s\n' -U3 --no-color --no-ext-diff --no-textconv --diff-algorithm=myers \
    --indent-heuristic --inter-hunk-context=0 --no-relative --src-prefix=a/ \
    --dst-prefix=b/ --full-index --ignore-submodules=none --submodule=short --no-renames
}

# _audit_branch_patch_sha256_command: the sha256 tool on PATH, or non-zero.
_audit_branch_patch_sha256_command() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum\n'
  elif command -v shasum >/dev/null 2>&1; then
    printf 'shasum\n'
  else
    return 1
  fi
}

# _audit_branch_patch_commit <root> <revision>: the 40-hex commit, or non-zero.
_audit_branch_patch_commit() {
  local commit
  commit="$(_audit_branch_patch_git "$1" rev-parse --verify --quiet --end-of-options "$2^{commit}" 2>/dev/null)" || return 1
  case "$commit" in
    *[!0-9a-f]* | "") return 1 ;;
  esac
  [ "${#commit}" -eq 40 ] || return 1
  printf '%s\n' "$commit"
}

# _audit_branch_patch_unique_merge_base <root> <base-tip> <target>: prints the
# merge base; returns 4, 3 or 1 per the shared codes.
_audit_branch_patch_unique_merge_base() {
  local root="$1" tip="$2" target="$3" tip_commit target_commit merge_bases
  [ -n "$root" ] && [ -n "$tip" ] && [ -n "$target" ] || return 1
  tip_commit="$(_audit_branch_patch_commit "$root" "$tip")" || return 4
  target_commit="$(_audit_branch_patch_commit "$root" "$target")" || return 1
  merge_bases="$(_audit_branch_patch_git "$root" merge-base --all "$target_commit" "$tip_commit" 2>/dev/null)" || return 1
  [ -n "$merge_bases" ] || return 1
  case "$merge_bases" in
    *$'\n'*) return 3 ;;
  esac
  printf '%s\n' "${merge_bases%%$'\n'*}"
}

# _audit_branch_patch_header_half <path>: sets _audit_branch_patch_header to
# the text after `diff --git ` that git prints for <path>, using git's C-style
# quoting under core.quotepath=false: bytes at or above 0x80 stay verbatim;
# control bytes, DEL, `"` and `\` are escaped. A variable rather than stdout,
# so the per-path call forks nothing.
_audit_branch_patch_header_half() {
  local path="$1" quoted="" character code index=0 length=${#1}
  case "$path" in
    *[[:cntrl:]]* | *\"* | *\\*) ;;
    *)
      _audit_branch_patch_header="a/$path b/$path"
      return 0
      ;;
  esac
  while [ "$index" -lt "$length" ]; do
    character="${path:$index:1}"
    case "$character" in
      '"') quoted="$quoted\\\"" ;;
      \\) quoted="$quoted\\\\" ;;
      $'\a') quoted="$quoted\\a" ;;
      $'\b') quoted="$quoted\\b" ;;
      $'\t') quoted="$quoted\\t" ;;
      $'\n') quoted="$quoted\\n" ;;
      $'\v') quoted="$quoted\\v" ;;
      $'\f') quoted="$quoted\\f" ;;
      $'\r') quoted="$quoted\\r" ;;
      [[:cntrl:]])
        printf -v code '%03o' "'$character"
        quoted="$quoted\\$code"
        ;;
      *) quoted="$quoted$character" ;;
    esac
    index=$((index + 1))
  done
  _audit_branch_patch_header="\"a/$quoted\" \"b/$quoted\""
}

# _audit_branch_patch_records <root> <merge-base> <target-tree-ish> <work
# directory> <output file>: writes the sorted NUL-terminated
# `<identity>\t<path>` records. Callers run it inside their own subshell with
# LC_ALL=C and pipefail set.
_audit_branch_patch_records() {
  local root="$1" merge_base="$2" target="$3" work="$4" output="$5"
  local raw="$work/raw" metadata="$work/metadata" patch="$work/patch" frames="$work/frames"
  local hashes="$work/hashes" unsorted="$work/unsorted" sha256_command
  local meta path old_mode new_mode old_blob new_blob status kind record_count=0
  local hex frame_file index
  local -a record_path record_hash

  sha256_command="$(_audit_branch_patch_sha256_command)" || return 1
  rm -rf "$frames" && mkdir "$frames" || return 1

  _audit_branch_patch_git "$root" diff-tree -r --raw -z --no-abbrev --no-renames \
    --ignore-submodules=none --no-ext-diff --no-textconv \
    "$merge_base" "$target" >"$raw" 2>/dev/null || return 1

  : >"$metadata" || return 1
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    meta="${meta#:}"
    old_mode="${meta%% *}"; meta="${meta#* }"
    new_mode="${meta%% *}"; meta="${meta#* }"
    old_blob="${meta%% *}"; meta="${meta#* }"
    new_blob="${meta%% *}"; status="${meta#* }"
    case "$status" in M | A | D | T) ;; *) return 1 ;; esac
    kind=text
    case "$old_mode:$new_mode:$status" in
      120000:* | 160000:* | *:120000:* | *:160000:* | *:T) kind=blob ;;
    esac
    record_count=$((record_count + 1))
    record_path[record_count]="$path"
    _audit_branch_patch_header_half "$path"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$old_mode" "$new_mode" "$old_blob" \
      "$new_blob" "$status" "$_audit_branch_patch_header" >>"$metadata" || return 1
  done <"$raw"

  : >"$output" || return 1
  [ "$record_count" -gt 0 ] || return 0

  # shellcheck disable=SC2046 # one flag per line, none with whitespace
  _audit_branch_patch_git "$root" diff-tree -r -p $(_audit_branch_patch_diff_flags) \
    "$merge_base" "$target" >"$patch" 2>/dev/null || return 1

  # The patch's sections arrive in the raw listing's order, one per record and
  # two for a typechange; each section's header must equal the record's
  # expected header, so a misaligned or unparseable patch fails closed rather
  # than framing one path's hunks under another's name. Every frame file is
  # closed before the next opens, so the descriptor count stays fixed.
  awk -v metadata_file="$metadata" -v frames="$frames" '
    BEGIN { FS = "\t"; record_count = 0; current = 0; in_hunk = 0; failed = 0 }
    FILENAME == metadata_file {
      record_count++
      kind[record_count] = $1; old_mode[record_count] = $2; new_mode[record_count] = $3
      old_blob[record_count] = $4; new_blob[record_count] = $5; status[record_count] = $6
      header[record_count] = $7
      next
    }
    function finish_record() {
      if (current == 0) return
      if (kind[current] != "text" || binary) print "blob " old_blob[current] " " new_blob[current] > frame_file   # frame: blobs
      close(frame_file)
    }
    substr($0, 1, 11) == "diff --git " {
      section_header = substr($0, 12)
      in_hunk = 0
      if (current > 0 && section_header == header[current] && status[current] == "T") next
      finish_record()
      current++
      if (current > record_count || section_header != header[current]) { failed = 1; exit }
      frame_file = frames "/" sprintf("%09d", current)
      binary = 0
      print "path " header[current] > frame_file   # frame: path
      print "mode " old_mode[current] " " new_mode[current] > frame_file   # frame: modes
      next
    }
    current == 0 { failed = 1; exit }
    in_hunk == 0 && substr($0, 1, 13) == "Binary files " { binary = 1; next }
    substr($0, 1, 3) == "@@ " { in_hunk = 1; if (kind[current] == "text") print "@@" > frame_file; next }   # frame: hunks
    in_hunk == 1 { if (kind[current] == "text") print $0 > frame_file; next }   # frame: hunks
    { next }
    END {
      if (failed) exit 1
      finish_record()
      if (current != record_count) exit 1
    }
  ' "$metadata" "$patch" || return 1

  # One sha256 process for the whole batch (find splits only past ARG_MAX).
  if [ "$sha256_command" = shasum ]; then
    find "$frames" -type f -exec shasum -a 256 {} + >"$hashes" 2>/dev/null || return 1
  else
    find "$frames" -type f -exec sha256sum {} + >"$hashes" 2>/dev/null || return 1
  fi

  while IFS= read -r hex; do
    frame_file="${hex##*/}"
    hex="${hex%% *}"
    case "$frame_file" in *[!0-9]* | "") return 1 ;; esac
    index=$((10#$frame_file))
    [ "$index" -ge 1 ] && [ "$index" -le "$record_count" ] || return 1
    case "$hex" in *[!0-9a-f]* | "") return 1 ;; esac
    [ "${#hex}" -eq 64 ] || return 1
    [ -z "${record_hash[index]:-}" ] || return 1
    record_hash[index]="$hex"
  done <"$hashes"

  : >"$unsorted" || return 1
  index=1
  while [ "$index" -le "$record_count" ]; do
    [ -n "${record_hash[index]:-}" ] || return 1
    printf '%s\t%s\0' "${record_hash[index]}" "${record_path[index]}" >>"$unsorted" || return 1
    index=$((index + 1))
  done
  sort -z -t $'\t' -k2 "$unsorted" >"$output" || return 1
}

# _audit_branch_patch_changed_between <first records> <second records>
# <output>: NUL-terminated, sorted, unique paths whose record differs between
# the two record files or that appear in only one. A record present in both
# files sorts next to its twin; every unpaired record names a changed path.
_audit_branch_patch_changed_between() {
  local first="$1" second="$2" output="$3" record previous="" have_previous=0 unpaired="$3.unpaired"
  : >"$unpaired" || return 1
  while IFS= read -r -d '' record; do
    if [ "$have_previous" = 1 ] && [ "$record" = "$previous" ]; then
      have_previous=0
      continue
    fi
    if [ "$have_previous" = 1 ]; then
      printf '%s\0' "${previous:65}" >>"$unpaired" || return 1
    fi
    previous="$record"
    have_previous=1
  done < <(cat "$first" "$second" | sort -z)
  if [ "$have_previous" = 1 ]; then
    printf '%s\0' "${previous:65}" >>"$unpaired" || return 1
  fi
  sort -z -u "$unpaired" >"$output"
}

# audit_branch_patch_merge_base <root> <base-tip> [<target-commit>=HEAD]: the
# unique merge base, 40-hex.
audit_branch_patch_merge_base() (
  LC_ALL=C
  export LC_ALL
  _audit_branch_patch_unique_merge_base "${1:-}" "${2:-}" "${3:-HEAD}"
)

# audit_branch_patch_fork_point <root> <base-tip> [<target-commit>=HEAD]: the
# first parent of the oldest commit on the target's first-parent chain that the
# base tip cannot reach; the target itself when the tip reaches it. A catch-up
# merge's first parent is the branch side, so the value survives catch-ups.
# Uniqueness of the merge base is not needed to define it, so this function
# never returns 3.
audit_branch_patch_fork_point() (
  LC_ALL=C
  export LC_ALL
  root="${1:-}"
  [ -n "$root" ] && [ -n "${2:-}" ] || exit 1
  tip_commit="$(_audit_branch_patch_commit "$root" "$2")" || exit 4
  target_commit="$(_audit_branch_patch_commit "$root" "${3:-HEAD}")" || exit 1
  chain="$(_audit_branch_patch_git "$root" rev-list --first-parent "$target_commit" "^$tip_commit" 2>/dev/null)" || exit 1
  if [ -z "$chain" ]; then
    printf '%s\n' "$target_commit"
    exit 0
  fi
  oldest="${chain##*$'\n'}"
  _audit_branch_patch_commit "$root" "$oldest^1" || exit 1
)

# audit_branch_patch_identities <root> <merge-base> <target-tree-ish>:
# NUL-terminated `<identity>\t<path>` records for the branch-own patch
# `merge-base..target`, ordered by path bytes.
audit_branch_patch_identities() (
  root="${1:-}" merge_base="${2:-}" target="${3:-}"
  [ -n "$root" ] && [ -n "$merge_base" ] && [ -n "$target" ] || exit 1
  LC_ALL=C
  export LC_ALL
  set -o pipefail
  work="$(mktemp -d 2>/dev/null)" || exit 1
  trap 'rm -rf "$work"' EXIT
  _audit_branch_patch_records "$root" "$merge_base" "$target" "$work" "$work/records" || exit 1
  cat "$work/records"
)

# _audit_branch_patch_side_records <root> <base-tip> <commit> <work> <output>
# <code variable>: records for `merge_base(commit, tip)..commit`; on failure
# the shared return code.
_audit_branch_patch_side_records() {
  local root="$1" tip="$2" commit="$3" work="$4" output="$5" merge_base status=0
  merge_base="$(_audit_branch_patch_unique_merge_base "$root" "$tip" "$commit")" || return $?
  mkdir -p "$work" || return 1
  _audit_branch_patch_records "$root" "$merge_base" "$commit" "$work" "$output" || status=1
  return "$status"
}

# audit_branch_patch_changed_paths <root> <base-tip> <anchor-commit>
# [<target-commit>=HEAD]: NUL-terminated paths whose identity differs between
# the anchor's branch-own patch and the target's, plus every path in only one.
audit_branch_patch_changed_paths() (
  root="${1:-}" tip="${2:-}" anchor="${3:-}" target="${4:-HEAD}"
  [ -n "$root" ] && [ -n "$tip" ] && [ -n "$anchor" ] || exit 1
  LC_ALL=C
  export LC_ALL
  set -o pipefail
  work="$(mktemp -d 2>/dev/null)" || exit 1
  trap 'rm -rf "$work"' EXIT
  _audit_branch_patch_side_records "$root" "$tip" "$target" "$work/target" "$work/target.records" || exit $?
  _audit_branch_patch_side_records "$root" "$tip" "$anchor" "$work/anchor" "$work/anchor.records" || exit $?
  _audit_branch_patch_changed_between "$work/anchor.records" "$work/target.records" "$work/changed" || exit 1
  cat "$work/changed"
)

# audit_branch_patch_supports_remerge_diff <root>: 0 when this git accepts
# `--remerge-diff`, 1 otherwise. An unknown option is a usage error, which is
# the only way the probe on the empty tree fails.
audit_branch_patch_supports_remerge_diff() {
  [ -n "${1:-}" ] || return 1
  _audit_branch_patch_git "$1" show --remerge-diff -s --format= "$_AUDIT_BRANCH_PATCH_EMPTY_TREE" >/dev/null 2>&1
}

# _audit_branch_patch_load_paths <NUL path file>: loads the paths into the
# caller's `selected` array.
_audit_branch_patch_load_paths() {
  local path
  selected=()
  while IFS= read -r -d '' path; do
    selected[${#selected[@]}]="$path"
  done <"$1"
}

# audit_branch_patch_review_input <root> <base-tip> <anchor-commit or empty>
# <target-commit> [<path>...]: the unified diff a member reviews. For each
# selected path whose identity changed since the anchor: the target patch's
# hunks whose header-stripped text is absent from the anchor patch on that
# path (each path's section header always, so a mode-only or binary change
# still shows), then, per merge commit since the anchor that changed that
# path's identity against its first parent, that merge's remerge-diff on it.
# Without remerge-diff support: the selected paths' full branch-own patch.
# Never a whole file unless the branch adds it, never a base-only hunk.
audit_branch_patch_review_input() (
  root="${1:-}" tip="${2:-}" anchor="${3:-}" target="${4:-}"
  [ -n "$root" ] && [ -n "$tip" ] && [ -n "$target" ] || exit 1
  shift 4
  LC_ALL=C
  export LC_ALL
  set -o pipefail
  work="$(mktemp -d 2>/dev/null)" || exit 1
  trap 'rm -rf "$work"' EXIT

  target_merge_base="$(_audit_branch_patch_unique_merge_base "$root" "$tip" "$target")" || exit $?
  target_commit="$(_audit_branch_patch_commit "$root" "$target")" || exit 1
  mkdir "$work/target" || exit 1
  _audit_branch_patch_records "$root" "$target_merge_base" "$target_commit" "$work/target" "$work/target.records" || exit 1

  anchor_commit=""
  if [ -n "$anchor" ]; then
    anchor_commit="$(_audit_branch_patch_commit "$root" "$anchor")" || exit 1
    anchor_merge_base="$(_audit_branch_patch_unique_merge_base "$root" "$tip" "$anchor_commit")" || exit $?
    mkdir "$work/anchor" || exit 1
    _audit_branch_patch_records "$root" "$anchor_merge_base" "$anchor_commit" "$work/anchor" "$work/anchor.records" || exit 1
  else
    : >"$work/anchor.records" || exit 1
  fi
  _audit_branch_patch_changed_between "$work/anchor.records" "$work/target.records" "$work/changed" || exit 1

  # Narrow to the requested paths: a path in both sorted, unique lists sorts
  # next to its twin.
  if [ "$#" -gt 0 ]; then
    : >"$work/requested" || exit 1
    for path in "$@"; do
      printf '%s\0' "$path" >>"$work/requested" || exit 1
    done
    sort -z -u "$work/requested" >"$work/requested.sorted" || exit 1
    : >"$work/selected" || exit 1
    previous="" have_previous=0
    while IFS= read -r -d '' path; do
      if [ "$have_previous" = 1 ] && [ "$path" = "$previous" ]; then
        printf '%s\0' "$path" >>"$work/selected" || exit 1
        have_previous=0
        continue
      fi
      previous="$path"
      have_previous=1
    done < <(cat "$work/changed" "$work/requested.sorted" | sort -z)
  else
    cp "$work/changed" "$work/selected" || exit 1
  fi
  _audit_branch_patch_load_paths "$work/selected"
  if [ "${#selected[@]}" -eq 0 ]; then
    exit 0
  fi

  # shellcheck disable=SC2046 # one flag per line, none with whitespace
  _audit_branch_patch_git "$root" diff-tree -r -p $(_audit_branch_patch_diff_flags) \
    "$target_merge_base" "$target_commit" -- ${selected[@]+"${selected[@]}"} >"$work/target.patch" 2>/dev/null || exit 1

  if ! audit_branch_patch_supports_remerge_diff "$root"; then
    cat "$work/target.patch"
    exit 0
  fi

  : >"$work/anchor.patch" || exit 1
  if [ -n "$anchor_commit" ]; then
    # shellcheck disable=SC2046 # one flag per line, none with whitespace
    _audit_branch_patch_git "$root" diff-tree -r -p $(_audit_branch_patch_diff_flags) \
      "$anchor_merge_base" "$anchor_commit" -- ${selected[@]+"${selected[@]}"} >"$work/anchor.patch" 2>/dev/null || exit 1
  fi

  # Interdiff by hunk: a target hunk is new when its header-stripped text is
  # not a hunk of the anchor patch on the same path.
  awk -v anchor_file="$work/anchor.patch" '
    function flush_hunk() {
      if (hunk_text == "") return
      key = section SUBSEP hunk_text
      if (phase == "anchor") seen[key] = 1
      else if (!(key in seen)) {
        if (!header_printed) { printf "%s", header_text; header_printed = 1 }
        printf "%s", hunk_original
      }
      hunk_text = ""; hunk_original = ""
    }
    function flush_section() {
      flush_hunk()
      if (phase == "target" && section != "" && !header_printed) printf "%s", header_text
      section = ""; header_text = ""; header_printed = 0; in_hunk = 0
    }
    FNR == 1 { flush_section(); phase = (FILENAME == anchor_file) ? "anchor" : "target" }
    substr($0, 1, 11) == "diff --git " { flush_section(); section = $0; header_text = $0 "\n"; next }
    substr($0, 1, 3) == "@@ " { flush_hunk(); in_hunk = 1; hunk_text = "@@\n"; hunk_original = $0 "\n"; next }
    in_hunk { hunk_text = hunk_text $0 "\n"; hunk_original = hunk_original $0 "\n"; next }
    { header_text = header_text $0 "\n" }
    END { flush_section() }
  ' "$work/anchor.patch" "$work/target.patch" >"$work/review" || exit 1

  # Merge commits the branch made since the anchor (never the base's own,
  # which the tip reaches), each with its first parent.
  if [ -n "$anchor_commit" ]; then
    merges="$(_audit_branch_patch_git "$root" rev-list --merges --parents "$target_commit" "^$anchor_commit" "^$tip" 2>/dev/null)" || exit 1
  else
    merges="$(_audit_branch_patch_git "$root" rev-list --merges --parents "$target_commit" "^$tip" 2>/dev/null)" || exit 1
  fi
  merge_index=0
  while IFS=' ' read -r merge first_parent _; do
    [ -n "$merge" ] || continue
    merge_index=$((merge_index + 1))
    _audit_branch_patch_side_records "$root" "$tip" "$merge" "$work/merge-$merge_index" "$work/merge-$merge_index.records" || exit 1
    _audit_branch_patch_side_records "$root" "$tip" "$first_parent" "$work/parent-$merge_index" "$work/parent-$merge_index.records" || exit 1
    _audit_branch_patch_changed_between "$work/parent-$merge_index.records" "$work/merge-$merge_index.records" "$work/merge-$merge_index.changed" || exit 1
    : >"$work/merge-$merge_index.paths" || exit 1
    previous="" have_previous=0
    while IFS= read -r -d '' path; do
      if [ "$have_previous" = 1 ] && [ "$path" = "$previous" ]; then
        printf '%s\0' "$path" >>"$work/merge-$merge_index.paths" || exit 1
        have_previous=0
        continue
      fi
      previous="$path"
      have_previous=1
    done < <(cat "$work/merge-$merge_index.changed" "$work/selected" | sort -z)
    _audit_branch_patch_load_paths "$work/merge-$merge_index.paths"
    [ "${#selected[@]}" -gt 0 ] || continue
    # shellcheck disable=SC2046 # one flag per line, none with whitespace
    _audit_branch_patch_git "$root" show --format= --no-notes --remerge-diff \
      $(_audit_branch_patch_diff_flags) "$merge" -- ${selected[@]+"${selected[@]}"} >>"$work/review" 2>/dev/null || exit 1
  done <<EOF
$merges
EOF
  cat "$work/review"
)

# audit_branch_patch_rebased_anchor_tree <root> <base-tip> <anchor-commit>
# [<target-commit>=HEAD]: the tree of the anchor's branch-own change replayed
# onto the target's merge base. Non-zero on a conflict or when this git lacks
# `merge-tree --write-tree --merge-base`.
audit_branch_patch_rebased_anchor_tree() (
  root="${1:-}" tip="${2:-}" anchor="${3:-}" target="${4:-HEAD}"
  [ -n "$root" ] && [ -n "$tip" ] && [ -n "$anchor" ] || exit 1
  LC_ALL=C
  export LC_ALL
  anchor_merge_base="$(_audit_branch_patch_unique_merge_base "$root" "$tip" "$anchor")" || exit $?
  target_merge_base="$(_audit_branch_patch_unique_merge_base "$root" "$tip" "$target")" || exit $?
  anchor_commit="$(_audit_branch_patch_commit "$root" "$anchor")" || exit 1
  result="$(_audit_branch_patch_git "$root" merge-tree --write-tree --no-messages \
    --merge-base="$anchor_merge_base" "$target_merge_base" "$anchor_commit" 2>/dev/null)" || exit 1
  tree="${result%%$'\n'*}"
  case "$tree" in *[!0-9a-f]* | "") exit 1 ;; esac
  [ "${#tree}" -eq 40 ] || exit 1
  printf '%s\n' "$tree"
)
