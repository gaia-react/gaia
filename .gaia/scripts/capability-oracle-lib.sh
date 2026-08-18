#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
#
# capability-oracle-lib.sh -- the static-analysis half of the allowlisted-script
# capability check: how a line of shell becomes a capability term, and how one
# script's reach becomes the closure of everything it invokes.
#
# Sourced by .gaia/scripts/check-script-capabilities.sh, which owns the manifest
# assertions, the exit codes, and the command line. The split is by subject: the
# oracle answers "what does this file reach for", the check answers "does the
# declaration agree". Sourcing this file defines its functions and does nothing
# else.
#
# Every detector here is deliberately incomplete in one direction and says so in
# its own header. The oracle is lexical: it does not evaluate, it does not model
# the call graph across function boundaries, and a path a script computes at run
# time is reported as belonging to whoever computes it. Those limits are stated
# at each site rather than summarized here, so a reader auditing one detector
# sees the limit that applies to it.

# Hot paths return through this rather than through `$(...)`: the oracle runs
# every detector over every non-comment line of every file in every obligated
# script's closure, and a subshell per call turns that into minutes.
_GAIA_CAPCHECK_RET=""

# ---------------------------------------------------------------------------
# Lexical helpers
# ---------------------------------------------------------------------------

# _gaia_capcheck_is_comment_line <line>: true when <line>, trimmed of leading
# whitespace, is a bash comment line. Same classifier idiom the hook-scope
# manifest check uses, defined here so this check stands alone.
_gaia_capcheck_is_comment_line() {
  local line="$1" trimmed
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [[ "$trimmed" == \#* ]]
}

# _gaia_capcheck_strip_literals <text>: blanks out every single-quoted span,
# leaving the result in _GAIA_CAPCHECK_RET.
#
# Single-quoted text is a literal argument -- a jq/awk/sed program, a grep
# pattern, a message -- not shell syntax the shell will execute, and those
# programs are where `>`, `gh`, and `/tmp` show up as data rather than as
# reach. It deliberately does NOT model `bash -c '...'`: an eval is outside
# this oracle, and a script that evals its way to a capability is a finding
# for a reader, not for a lexical scan.
_gaia_capcheck_strip_literals() {
  local t="$1" out="" head
  while :; do
    case "$t" in
      *\'*) ;;
      *) out="$out$t"; break ;;
    esac
    head="${t%%\'*}"
    out="$out$head "
    t="${t#*\'}"
    case "$t" in
      *\'*) t="${t#*\'}" ;;
      *) break ;;
    esac
  done
  _GAIA_CAPCHECK_RET="$out"
}

# _gaia_capcheck_strip_tests <text>: blanks out `[[ ... ]]` and `(( ... ))`
# spans, leaving the result in _GAIA_CAPCHECK_RET. `>` inside a conditional or
# an arithmetic expression is a comparison, not a redirect, and the two are
# indistinguishable to a redirect matcher.
_gaia_capcheck_strip_tests() {
  local t="$1" pre post
  while :; do
    case "$t" in
      *'[['*']]'*) pre="${t%%\[\[*}"; post="${t#*\]\]}"; t="$pre $post" ;;
      *'(('*'))'*) pre="${t%%\(\(*}"; post="${t#*\)\)}"; t="$pre $post" ;;
      *) break ;;
    esac
  done
  _GAIA_CAPCHECK_RET="$t"
}

# _gaia_capcheck_unquote <token>: strips one layer of surrounding quotes.
_gaia_capcheck_unquote() {
  local v="$1"
  v="${v#\"}"; v="${v%\"}"
  v="${v#\'}"; v="${v%\'}"
  _GAIA_CAPCHECK_RET="$v"
}

# _gaia_capcheck_normalize <path>: resolves <path> lexically against the repo
# root -- collapse `.` segments, collapse `..` against the preceding segment,
# drop empty segments -- and leaves a repo-relative path in _GAIA_CAPCHECK_RET.
# Returns 1 when the path escapes the repo root, which C-6 makes a finding
# rather than a silent pass.
#
# Every idiom's output passes through here BEFORE it is compared to a declared
# `invokes:` term, so a `..`-bearing live invocation site stays declarable while
# a `..`-bearing declaration is still rejected.
_gaia_capcheck_normalize() {
  local rest="$1" seg out=""
  while [ "${rest%/}" != "$rest" ]; do rest="${rest%/}"; done
  while [ -n "$rest" ]; do
    if [ "${rest%%/*}" = "$rest" ]; then
      seg="$rest"; rest=""
    else
      seg="${rest%%/*}"; rest="${rest#*/}"
    fi
    case "$seg" in
      ''|'.') ;;
      '..')
        [ -n "$out" ] || return 1
        case "$out" in
          */*) out="${out%/*}" ;;
          *) out="" ;;
        esac
        ;;
      *) out="${out:+$out/}$seg" ;;
    esac
  done
  _GAIA_CAPCHECK_RET="$out"
  return 0
}

# _gaia_capcheck_dirname_rel <rel>: the directory part of a repo-relative path,
# empty for a top-level file.
_gaia_capcheck_dirname_rel() {
  case "$1" in
    */*) _GAIA_CAPCHECK_RET="${1%/*}" ;;
    *) _GAIA_CAPCHECK_RET="" ;;
  esac
}

# _gaia_capcheck_heredoc_delim <logical-line>: the here-document delimiter the
# line opens, or empty. Here-doc BODIES are skipped by the scanner: a usage
# block that prints `gh api ...` or a path is documentation, not reach.
_gaia_capcheck_heredoc_delim() {
  local t="${1//<<</ }" d
  case "$t" in
    *'<<'*) ;;
    *) _GAIA_CAPCHECK_RET=""; return 0 ;;
  esac
  d="${t#*<<}"
  d="${d#-}"
  d="${d#"${d%%[![:space:]]*}"}"
  d="${d%%[[:space:];)|&]*}"
  d="${d//\'/}"
  d="${d//\"/}"
  _GAIA_CAPCHECK_RET="$d"
}

# _gaia_capcheck_logical_lines <file>: prints one record per NON-COMMENT
# logical line as `<first-lineno>\t<shellcheck-source-or-->\t<text>`.
#
# Three things happen here rather than in the detectors. Backslash
# continuations are joined, so a `gh api` and the `--method POST` on its
# continuation line are one line to the oracle. Here-document bodies are
# dropped. And a `# shellcheck source=<path>` directive on the immediately
# preceding line rides along with the line it annotates, which is how idiom 5
# reaches the invocation it describes.
_gaia_capcheck_logical_lines() {
  local file="$1"
  [ -f "$file" ] || return 0
  local line trimmed lineno=0 start=0 acc="" cur_sc="-" pending_sc="-" cont=0 hd=""
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ -n "$hd" ]; then
      trimmed="${line#"${line%%[![:space:]]*}"}"
      if [ "$trimmed" = "$hd" ] || [ "$line" = "$hd" ]; then hd=""; fi
      continue
    fi
    if [ "$cont" -eq 0 ]; then
      trimmed="${line#"${line%%[![:space:]]*}"}"
      if [ -z "$trimmed" ]; then pending_sc="-"; continue; fi
      case "$trimmed" in
        \#*)
          case "$trimmed" in
            '# shellcheck source='*)
              pending_sc="${trimmed#*source=}"
              pending_sc="${pending_sc%%[[:space:]]*}"
              ;;
            *) pending_sc="-" ;;
          esac
          continue
          ;;
      esac
      start="$lineno"; acc="$line"; cur_sc="$pending_sc"; pending_sc="-"
    else
      acc="$acc $line"
    fi
    case "$acc" in
      *\\) acc="${acc%\\}"; cont=1; continue ;;
    esac
    cont=0
    printf '%s\t%s\t%s\n' "$start" "$cur_sc" "$acc"
    _gaia_capcheck_heredoc_delim "$acc"
    hd="$_GAIA_CAPCHECK_RET"
    acc=""
  done < "$file"
  if [ "$cont" -eq 1 ]; then
    printf '%s\t%s\t%s\n' "$start" "$cur_sc" "$acc"
  fi
  return 0
}

# _gaia_capcheck_tokens <text>: one whitespace-separated token per line, with
# globbing off. Quoted paths carrying a literal space split; no such path
# exists in the framework's own shell, and the alternative is a per-character
# scan the closure walk cannot afford.
_gaia_capcheck_tokens() {
  local saved_glob=0 tok
  case "$-" in *f*) saved_glob=1 ;; esac
  set -f
  # shellcheck disable=SC2086
  for tok in $1; do printf '%s\n' "$tok"; done
  [ "$saved_glob" -eq 1 ] || set +f
  return 0
}

# ---------------------------------------------------------------------------
# Resolution idioms (C-6): how an invocation or write target becomes a path
# ---------------------------------------------------------------------------

# _gaia_capcheck_dirhop <rel> <text>: idiom 3, the own-directory hop, matched
# STRUCTURALLY rather than as a quoted literal. Every live instance wraps
# `dirname "${BASH_SOURCE[0]}"` differently -- some in `cd ... && pwd`, some
# carrying `2>/dev/null` inside the substitution and `|| true` outside it --
# and each joins a literal suffix of any number of segments, not a basename.
# Resolves to the scanned file's own directory joined with that suffix.
_gaia_capcheck_dirhop() {
  local rel="$1" text="$2" tail suffix dir
  case "$text" in
    *BASH_SOURCE*) ;;
    *) return 1 ;;
  esac
  case "$text" in
    *dirname*) ;;
    *) return 1 ;;
  esac
  tail="${text#*BASH_SOURCE}"
  tail="${tail#*)}"
  suffix="${tail%%[\"[:space:]\&|\)\;]*}"
  _gaia_capcheck_dirname_rel "$rel"
  dir="$_GAIA_CAPCHECK_RET"
  _gaia_capcheck_normalize "${dir}${suffix}" || return 1
  return 0
}

# _gaia_capcheck_state_root_hop <text>: recognizes a call to one of GAIA's own
# main-anchored local-state directory resolvers (ledger-path-lib.sh's
# gaia_resolve_plans_dir / gaia_resolve_specs_dir). Each takes the checkout to
# resolve from as its own argument and joins a single hardcoded subdir onto
# the main checkout's .gaia/local, so unlike an arbitrary function call, its
# result is a fixed repo-relative directory regardless of which checkout it
# runs in or what argument it is handed -- the same closed-set, name-matched
# recognition idiom 3 already applies to the BASH_SOURCE dirname hop.
_gaia_capcheck_state_root_hop() {
  local text="$1"
  case "$text" in
    *gaia_resolve_plans_dir*) _GAIA_CAPCHECK_RET=".gaia/local/plans"; return 0 ;;
    *gaia_resolve_specs_dir*) _GAIA_CAPCHECK_RET=".gaia/local/specs"; return 0 ;;
  esac
  return 1
}

# _gaia_capcheck_assignment_values <repo_root> <rel> <var>: one value per
# assignment of <var> in <rel>, in file order. A value is either the raw right
# side, `DIRHOP:<repo-relative-path>`, or `MKTEMP:<template>`.
_gaia_capcheck_assignment_values() {
  local repo_root="$1" rel="$2" var="$3" file="$1/$2"
  [ -f "$file" ] || return 0
  local line tail v
  while IFS= read -r line; do
    _gaia_capcheck_is_comment_line "$line" && continue
    tail="${line#*"$var"=}"
    [ "$tail" = "$line" ] && continue
    if _gaia_capcheck_dirhop "$rel" "$tail"; then
      printf 'DIRHOP:%s\n' "$_GAIA_CAPCHECK_RET"
      continue
    fi
    if _gaia_capcheck_state_root_hop "$tail"; then
      printf 'DIRHOP:%s\n' "$_GAIA_CAPCHECK_RET"
      continue
    fi
    case "$tail" in
      *mktemp*)
        _gaia_capcheck_mktemp_template "$tail"
        printf 'MKTEMP:%s\n' "$_GAIA_CAPCHECK_RET"
        continue
        ;;
    esac
    case "$tail" in
      '"'*) v="${tail#\"}"; v="${v%%\"*}" ;;
      "'"*) v="${tail#\'}"; v="${v%%\'*}" ;;
      *) v="${tail%%[[:space:];]*}" ;;
    esac
    [ -n "$v" ] && printf '%s\n' "$v"
  done < <(grep -E "(^|[[:space:]|&;(])${var}=" "$file" 2>/dev/null)
  return 0
}

# _gaia_capcheck_mktemp_template <text>: the first non-flag operand of the
# `mktemp` call in <text>, or empty for a bare/flags-only call.
_gaia_capcheck_mktemp_template() {
  local tail="${1#*mktemp}" tok seen=0
  _GAIA_CAPCHECK_RET=""
  while IFS= read -r tok; do
    case "$tok" in
      -*) continue ;;
      '') continue ;;
      '2>'*|'>'*|'||'|'&&'|';'*|')'*) break ;;
    esac
    _gaia_capcheck_unquote "$tok"
    seen=1
    break
  done < <(_gaia_capcheck_tokens "$tail")
  [ "$seen" -eq 1 ] || _GAIA_CAPCHECK_RET=""
  return 0
}

# _gaia_capcheck_split_var <token>: splits a leading `$VAR/` or `${VAR}/` root
# segment off <token>. Leaves the variable name in _GAIA_CAPCHECK_VAR and the
# literal remainder in _GAIA_CAPCHECK_SUFFIX; returns 1 when <token> does not
# begin with a variable reference. _GAIA_CAPCHECK_SUFFIX is empty for a bare
# `$VAR`, and _GAIA_CAPCHECK_VAR is empty when the first segment is a variable
# that is not followed by `/` (`${digest}.ok`) -- a shape no idiom resolves.
_gaia_capcheck_split_var() {
  local t="$1" rest name
  _GAIA_CAPCHECK_VAR=""
  _GAIA_CAPCHECK_SUFFIX=""
  case "$t" in
    '${'*)
      rest="${t#\$\{}"
      name="${rest%%\}*}"
      rest="${rest#*\}}"
      # `${var%/}` (trim a trailing slash before joining) is common enough on
      # directory-holding variables to recognize by name: the trim never
      # changes the joined result, since a suffix is appended right after.
      # Any other parameter-expansion operator (`#`, `:-`, `//`, ...) leaves
      # `name` holding the operator and its pattern rather than a bare
      # identifier, which is a shape no idiom resolves; reject it outright
      # instead of falling through with a name no assignment will ever match,
      # which the caller would misread as "truly unassigned" and wrongly
      # treat as a safe-to-strip root.
      case "$name" in
        *'%/') name="${name%'%/'}" ;;
      esac
      case "$name" in
        ''|*[!A-Za-z0-9_]*) return 1 ;;
      esac
      ;;
    '$'*)
      rest="${t#\$}"
      name="${rest%%[!A-Za-z0-9_]*}"
      rest="${rest#"$name"}"
      ;;
    *) return 1 ;;
  esac
  [ -n "$name" ] || return 1
  case "$rest" in
    '') _GAIA_CAPCHECK_VAR="$name"; return 0 ;;
    /*) _GAIA_CAPCHECK_VAR="$name"; _GAIA_CAPCHECK_SUFFIX="${rest#/}"; return 0 ;;
    *) return 0 ;;
  esac
}

# _gaia_capcheck_ref_name <text>: the variable name the `$`-reference at the
# START of <text> names, left in _GAIA_CAPCHECK_RET, with whatever follows that
# reference in _GAIA_CAPCHECK_REFREST. Returns 1 when <text> does not begin with
# a reference this oracle reads. `1`..`9`, `@`, and `*` are legal names here: a
# positional is the one reference whose value no assignment in the file holds.
_gaia_capcheck_ref_name() {
  local t="$1" rest name
  _GAIA_CAPCHECK_REFREST=""
  case "$t" in
    '${'*)
      rest="${t#\$\{}"
      case "$rest" in *'}'*) ;; *) return 1 ;; esac
      name="${rest%%\}*}"
      case "$name" in
        *'%/') name="${name%'%/'}" ;;
      esac
      # A positional carrying a default or alternate operator (`${1-}`,
      # `${2:-x}`) is still that positional. No shell variable name may begin
      # with a digit, so a leading digit run followed by anything else is
      # always an operator rather than part of a name.
      case "$name" in
        [0-9]*[!0-9]*) name="${name%%[!0-9]*}" ;;
        '@'[!A-Za-z0-9_]*|'*'[!A-Za-z0-9_]*) name="${name%"${name#?}"}" ;;
      esac
      _GAIA_CAPCHECK_REFREST="${rest#*\}}"
      ;;
    '$'*)
      rest="${t#\$}"
      case "$rest" in
        [0-9]*) name="${rest%%[!0-9]*}" ;;
        '@'*|'*'*) name="${rest%"${rest#?}"}" ;;
        *) name="${rest%%[!A-Za-z0-9_]*}" ;;
      esac
      _GAIA_CAPCHECK_REFREST="${rest#"$name"}"
      ;;
    *) return 1 ;;
  esac
  case "$name" in
    '@'|'*') ;;
    ''|*[!A-Za-z0-9_]*) return 1 ;;
  esac
  _GAIA_CAPCHECK_RET="$name"
  return 0
}

# _gaia_capcheck_is_positional_name <name>: true for a positional parameter.
_gaia_capcheck_is_positional_name() {
  case "$1" in
    '@'|'*') return 0 ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  return 0
}

# _gaia_capcheck_caller_supplied <repo_root> <rel> <var> <seen>: true when <var>
# holds a path the caller names at run time -- a positional parameter, or a
# variable whose assignment begins or ends in one.
#
# This is the test that separates a write into a caller-designated directory
# from a write the file itself locates, and it is consulted only after every
# resolution idiom has failed to find a literal prefix, so a variable naming a
# real directory never reaches it. Both ends of an assignment are examined
# because either half of a join can be the caller's: `lock_file` reaches a
# positional through the reference its value begins with, `source_abs` through
# the one its value ends with, its other half being the repo root.
#
# <seen> is the recursion's cycle guard: a trim like `root="${root%/}"` is a
# self-reference, not a chain, and a file may hold several of them.
_gaia_capcheck_caller_supplied() {
  local repo_root="$1" rel="$2" var="$3" seen="$4" v name tail
  case " $seen " in *" $var "*) return 1 ;; esac
  seen="$seen $var"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in DIRHOP:*|MKTEMP:*) continue ;; esac
    if _gaia_capcheck_ref_name "$v"; then
      name="$_GAIA_CAPCHECK_RET"
      _gaia_capcheck_is_positional_name "$name" && return 0
      _gaia_capcheck_caller_supplied "$repo_root" "$rel" "$name" "$seen" && return 0
    fi
    case "$v" in
      *'$'*) tail="\$${v##*\$}" ;;
      *) continue ;;
    esac
    _gaia_capcheck_ref_name "$tail" || continue
    # A trailing reference only counts when the value truly ends in it; a
    # literal tail means the file, not the caller, named the last segment.
    [ -z "$_GAIA_CAPCHECK_REFREST" ] || continue
    name="$_GAIA_CAPCHECK_RET"
    _gaia_capcheck_is_positional_name "$name" && return 0
    _gaia_capcheck_caller_supplied "$repo_root" "$rel" "$name" "$seen" && return 0
  done < <(_gaia_capcheck_assignment_values "$repo_root" "$rel" "$var")
  return 1
}

# _gaia_capcheck_resolve_dir <repo_root> <rel> <var>: the repo-relative
# directory a variable holds, when its assignments agree on exactly one.
# Idiom 4, one-hop constant propagation, with idioms 2 and 3 applied to the
# assignment's own value.
_gaia_capcheck_resolve_dir() {
  local repo_root="$1" rel="$2" var="$3" v n=0 found="" this
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in
      DIRHOP:*) this="${v#DIRHOP:}" ;;
      MKTEMP:*) return 1 ;;
      *)
        if _gaia_capcheck_split_var "$v"; then
          [ -n "$_GAIA_CAPCHECK_VAR" ] || return 1
          _gaia_capcheck_normalize "$_GAIA_CAPCHECK_SUFFIX" || return 1
        else
          _gaia_capcheck_normalize "$v" || return 1
        fi
        this="$_GAIA_CAPCHECK_RET"
        ;;
    esac
    # Repeated assignments are fine as long as they agree: a lib that derives
    # its own directory once per function still names one directory.
    if [ "$n" -gt 0 ] && [ "$this" != "$found" ]; then return 1; fi
    found="$this"
    n=$((n + 1))
  done < <(_gaia_capcheck_assignment_values "$repo_root" "$rel" "$var")
  [ "$n" -ge 1 ] || return 1
  _GAIA_CAPCHECK_RET="$found"
  return 0
}

# _gaia_capcheck_resolve_invocation <repo_root> <rel> <sc-source> <text>:
# resolves the invocation target <text> introduces, applying C-6's idioms in
# order and normalizing before anything compares the result. Leaves the
# repo-relative target in _GAIA_CAPCHECK_RET.
#
# Idiom 2 (root-variable join) is tried before idiom 4 (constant propagation)
# and a candidate is accepted only when a file exists at it, which is what lets
# `"$root/.gaia/scripts/x.sh"` and `"$_lib_dir/x.sh"` -- identical in shape,
# one rooted at the repo and one at a directory -- both land on the right file.
_gaia_capcheck_resolve_invocation() {
  local repo_root="$1" rel="$2" sc="$3" text="$4" tok cand dir
  if _gaia_capcheck_dirhop "$rel" "$text"; then
    cand="$_GAIA_CAPCHECK_RET"
    if [ -f "$repo_root/$cand" ]; then _GAIA_CAPCHECK_RET="$cand"; return 0; fi
  fi
  tok="${text%%[[:space:];|&)]*}"
  _gaia_capcheck_unquote "$tok"
  tok="$_GAIA_CAPCHECK_RET"
  case "$tok" in
    "$repo_root"/*) tok="${tok#"$repo_root"/}" ;;
  esac
  if _gaia_capcheck_split_var "$tok"; then
    if [ -n "$_GAIA_CAPCHECK_VAR" ]; then
      local var="$_GAIA_CAPCHECK_VAR" suffix="$_GAIA_CAPCHECK_SUFFIX"
      if [ -n "$suffix" ] && _gaia_capcheck_normalize "$suffix"; then
        cand="$_GAIA_CAPCHECK_RET"
        if [ -f "$repo_root/$cand" ]; then _GAIA_CAPCHECK_RET="$cand"; return 0; fi
      fi
      if _gaia_capcheck_resolve_dir "$repo_root" "$rel" "$var"; then
        dir="$_GAIA_CAPCHECK_RET"
        if _gaia_capcheck_normalize "${dir:+$dir/}$suffix"; then
          cand="$_GAIA_CAPCHECK_RET"
          if [ -f "$repo_root/$cand" ]; then _GAIA_CAPCHECK_RET="$cand"; return 0; fi
        fi
      fi
    fi
  elif _gaia_capcheck_normalize "$tok"; then
    cand="$_GAIA_CAPCHECK_RET"
    if [ -f "$repo_root/$cand" ]; then _GAIA_CAPCHECK_RET="$cand"; return 0; fi
  fi
  # Idiom 5. A `# shellcheck source=` directive is an accepted target
  # declaration, read repo-relative first and then against the sourcing file's
  # own directory, because both forms are live.
  if [ -n "$sc" ] && [ "$sc" != "-" ] && [ "$sc" != "/dev/null" ]; then
    if _gaia_capcheck_normalize "$sc"; then
      cand="$_GAIA_CAPCHECK_RET"
      if [ -f "$repo_root/$cand" ]; then _GAIA_CAPCHECK_RET="$cand"; return 0; fi
    fi
    _gaia_capcheck_dirname_rel "$rel"
    dir="$_GAIA_CAPCHECK_RET"
    if _gaia_capcheck_normalize "${dir:+$dir/}$sc"; then
      cand="$_GAIA_CAPCHECK_RET"
      if [ -f "$repo_root/$cand" ]; then _GAIA_CAPCHECK_RET="$cand"; return 0; fi
    fi
  fi
  return 1
}

# _gaia_capcheck_write_paths <repo_root> <rel> <raw> <depth>: one candidate
# repo-relative path per line for the write target <raw>, which may still carry
# a variable tail. Returns 0 with output, 1 when the target has no resolvable
# literal prefix at all, and 2 when the target is deliberately not a write.
#
# One output line is not a path: the sentinel `**` stands for a directory the
# caller designates at run time, which has no repo-relative reading at all.
# _gaia_capcheck_path_to_term turns it into the term that says so.
#
# The `$var/` reduction is what "resolved against the resolved state root
# rather than the invoking tree" means operationally: a variable whose own
# assignments resolve to a directory contributes that directory, and one that
# does not is read as a root and stripped, so a main-anchored write reduces to
# the same repo-relative path whichever checkout it lands in.
_gaia_capcheck_write_paths() {
  local repo_root="$1" rel="$2" raw="$3" depth="$4"
  local v n=0 runtime=0 supplied=0 vals sub base out=""
  [ "$depth" -le 4 ] || return 1
  _gaia_capcheck_unquote "$raw"
  raw="$_GAIA_CAPCHECK_RET"
  case "$raw" in
    ''|/dev/*|'&'*|'|'*) return 2 ;;
    '$('*|'`'*|*'$('*) return 2 ;;
    "$repo_root"/*) raw="${raw#"$repo_root"/}" ;;
  esac
  if _gaia_capcheck_split_var "$raw"; then
    [ -n "$_GAIA_CAPCHECK_VAR" ] || return 1
    local var="$_GAIA_CAPCHECK_VAR" suffix="$_GAIA_CAPCHECK_SUFFIX"
    vals="$(_gaia_capcheck_assignment_values "$repo_root" "$rel" "$var")"
    while IFS= read -r v; do
      [ -n "$v" ] || continue
      case "$v" in
        MKTEMP:*)
          # The temp file itself is classified where mktemp is called, so a
          # write through the variable holding it is not a second finding.
          [ -z "$suffix" ] && return 2
          continue
          ;;
        '$'[0-9@*]*|'${'[0-9@*]*)
          # A caller-supplied positional. No idiom resolves one; the
          # caller-supplied test below claims the whole target for it, with or
          # without a literal suffix. The flag is the fallback for an
          # expansion that test cannot parse: a target this file demonstrably
          # does not locate stays silent rather than becoming a finding a
          # reader has no way to act on.
          [ -z "$suffix" ] && runtime=1
          continue
          ;;
        DIRHOP:*)
          base="${v#DIRHOP:}"
          if _gaia_capcheck_normalize "${base:+$base/}$suffix"; then
            out="${out}${_GAIA_CAPCHECK_RET}
"
            n=$((n + 1))
          fi
          ;;
        *)
          sub="$(_gaia_capcheck_write_paths "$repo_root" "$rel" "$v" $((depth + 1)))"
          case "$?" in
            0) ;;
            2) runtime=1; continue ;;
            *) continue ;;
          esac
          while IFS= read -r base; do
            [ -n "$base" ] || continue
            if [ "$base" = '**' ]; then
              # A caller-designated directory swallows its suffix: joining a
              # literal onto a path the caller chooses still names nothing the
              # repo can pin, so all three write shapes agree on one term.
              out="${out}**
"
              n=$((n + 1))
              continue
            fi
            if _gaia_capcheck_normalize "${base:+$base/}$suffix"; then
              out="${out}${_GAIA_CAPCHECK_RET}
"
              n=$((n + 1))
            fi
          done <<INNER
$sub
INNER
          ;;
      esac
    done <<OUTER
$vals
OUTER
    if [ "$n" -eq 0 ]; then
      # Nothing resolved, so before the variable is read as a root: a variable
      # whose own assignment traces to a positional holds a path the caller
      # designates, and the honest term for a write there is the one that says
      # the caller chooses it. Reading such a variable as the repo root instead
      # would name a file nothing ever writes, and leaving it unresolved would
      # report a shape the grammar can in fact describe.
      #
      # A caller-supplied CHECKOUT ROOT is the exception, and the literal
      # remainder is what tells the two apart: `--root` joined to
      # `.gaia/local/audit` leaves a path this repo has, so the variable is a
      # root and the reduction holds, while a lock directory joined to
      # `specs.lock` leaves a name the repo does not have and never will. This
      # is the same accepted-only-if-it-exists discipline the invocation
      # resolver applies to the root-variable join, with the first segment
      # standing in for the whole path because a write target routinely does
      # not exist yet.
      if _gaia_capcheck_caller_supplied "$repo_root" "$rel" "$var" ""; then
        case "$suffix" in
          ''|'$'*) supplied=1 ;;
          *) [ -e "$repo_root/${suffix%%/*}" ] || supplied=1 ;;
        esac
        if [ "$supplied" -eq 1 ]; then
          printf '%s\n' '**'
          return 0
        fi
      fi
      # No assignment resolved. The variable is read as the root it stands in
      # for, which leaves the literal suffix as the repo-relative target --
      # but only when the file never assigns it at all (a true external root
      # parameter). When an assignment WAS seen but only resolved to something
      # COMPUTED at run time (a command substitution, a positional, or a
      # chain ending in one), the target belongs to whoever computes it: the
      # variable is not known to be the repo root, so treating it as one and
      # keeping a bare suffix would name a path with no resolvable literal
      # prefix at all, which is an UNRESOLVED finding, not a silent guess.
      case "$suffix" in
        '')
          # Nothing but the variable, and nothing to generalize with even if
          # the prefix were known: the grammar has no term for "anywhere"
          # (`fs-write:/**` is a bad term, not a blanket pass), so a computed
          # root with no suffix stays silent rather than becoming a finding.
          [ "$runtime" -eq 1 ] && return 2
          return 1
          ;;
        '$'*)
          # The remainder after the root is itself a variable, so the path is
          # chosen by the caller or by an argument rather than by this file.
          return 2
          ;;
      esac
      [ "$runtime" -eq 0 ] || return 1
      _gaia_capcheck_normalize "$suffix" || return 1
      printf '%s\n' "$_GAIA_CAPCHECK_RET"
      return 0
    fi
    printf '%s' "$out"
    return 0
  fi
  case "$raw" in
    /*|'~'*) return 1 ;;
  esac
  _gaia_capcheck_normalize "$raw" || return 1
  printf '%s\n' "$_GAIA_CAPCHECK_RET"
  return 0
}

# _gaia_capcheck_path_to_term <path>: C-8's path-to-glob generalization, the
# single function the printer and the reconciler share. Take the longest
# leading run of literal segments; if anything after it is non-literal, emit
# `<literal-prefix>/**`, otherwise emit the path verbatim. An `XXX` run is a
# mktemp placeholder and counts as non-literal.
_gaia_capcheck_path_to_term() {
  local rest="$1" seg prefix="" literal=1
  # The caller-designated-directory sentinel. It carries no literal prefix to
  # generalize from, and the term stands for exactly that.
  if [ "$rest" = '**' ]; then
    _GAIA_CAPCHECK_RET="fs-write:**"
    return 0
  fi
  while [ -n "$rest" ]; do
    if [ "${rest%%/*}" = "$rest" ]; then
      seg="$rest"; rest=""
    else
      seg="${rest%%/*}"; rest="${rest#*/}"
    fi
    case "$seg" in
      *'$'*|*'*'*|*'?'*|*'['*|*XXX*) literal=0; break ;;
    esac
    prefix="${prefix:+$prefix/}$seg"
  done
  if [ "$literal" -eq 1 ]; then
    [ -n "$prefix" ] || return 1
    _GAIA_CAPCHECK_RET="fs-write:$prefix"
    return 0
  fi
  [ -n "$prefix" ] || return 1
  _GAIA_CAPCHECK_RET="fs-write:$prefix/**"
  return 0
}

# _gaia_capcheck_glob_match <glob> <path>: `**` crosses `/`, `*` and `?` do
# not. Used to decide whether a declared fs-write glob covers a reached path.
_gaia_capcheck_glob_match() {
  local glob="$1" path="$2" re="" c rest
  rest="$glob"
  while [ -n "$rest" ]; do
    case "$rest" in
      '**'*) re="${re}.*"; rest="${rest#??}"; continue ;;
      '*'*) re="${re}[^/]*"; rest="${rest#?}"; continue ;;
      '?'*) re="${re}[^/]"; rest="${rest#?}"; continue ;;
    esac
    c="${rest%"${rest#?}"}"
    rest="${rest#?}"
    case "$c" in
      [A-Za-z0-9/_-]) re="${re}${c}" ;;
      *) re="${re}[${c}]" ;;
    esac
  done
  re="^$re\$"
  [[ $path =~ $re ]]
}

# ---------------------------------------------------------------------------
# Per-capability detection oracle (C-9). One small named detector per term,
# each stating what it matches and what it deliberately does not.
# ---------------------------------------------------------------------------

_GAIA_CAPCHECK_CMD='(^|[[:space:]|&;(`$])'

# _gaia_capcheck_detect_network <text>: curl, wget, any gh invocation, and the
# remote-touching git verbs. Deliberately not matched: `command -v gh` and
# friends, where `gh` is an argument rather than the command -- the match
# requires a lowercase subcommand letter after it.
_gaia_capcheck_detect_network() {
  local t="$1"
  local p1="${_GAIA_CAPCHECK_CMD}(curl|wget)([[:space:]]|\$)"
  local p2="${_GAIA_CAPCHECK_CMD}gh[[:space:]]+[a-z]"
  local p3="${_GAIA_CAPCHECK_CMD}git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)?[[:space:]]+(fetch|push|clone|pull|ls-remote)([[:space:]]|\$)"
  [[ $t =~ $p1 ]] && return 0
  [[ $t =~ $p2 ]] && return 0
  [[ $t =~ $p3 ]] && return 0
  return 1
}

# _gaia_capcheck_detect_github_write <text>: an authenticated mutating gh verb.
# `gh api` counts when it carries a non-GET method or any field flag; the noun
# subcommands count on their mutating verbs only. Deliberately not matched:
# `gh pr view`, `gh repo view`, `gh issue list`, `gh auth status`, which the
# network detector already covers.
_gaia_capcheck_detect_github_write() {
  local t="$1"
  local api="${_GAIA_CAPCHECK_CMD}gh[[:space:]]+api([[:space:]]|\$)"
  local mut='(--method[[:space:]]+(POST|PUT|PATCH|DELETE)|-X[[:space:]]+(POST|PUT|PATCH|DELETE)|(^|[[:space:]])(-f|--field|--raw-field)([[:space:]]|=))'
  local verbs="${_GAIA_CAPCHECK_CMD}gh[[:space:]]+(issue|pr|release|repo|run|workflow|label|secret)[[:space:]]+(create|close|reopen|edit|comment|delete|delete-asset|transfer|pin|unpin|lock|unlock|develop|merge|ready|review|upload|fork|rename|archive|sync|cancel|rerun|run|enable|disable|clone|set)([[:space:]]|\$)"
  if [[ $t =~ $api ]]; then
    [[ $t =~ $mut ]] && return 0
  fi
  [[ $t =~ $verbs ]] && return 0
  return 1
}

# _gaia_capcheck_detect_git_write <text>: a commit, tag, or branch mutation.
# Deliberately not matched: `git branch --show-current`, `git rev-parse`,
# `git merge-base`, `git status` -- the branch arm requires an operand that
# starts a name rather than a flag or a redirect.
_gaia_capcheck_detect_git_write() {
  local t="$1"
  local g="${_GAIA_CAPCHECK_CMD}git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)?[[:space:]]+"
  local p1="${g}(commit|tag|push|merge|rebase|am|cherry-pick|stash|update-ref)([[:space:]]|\$)"
  local p2="${g}reset[[:space:]]+--hard"
  local p3="${g}(checkout[[:space:]]+-b|switch[[:space:]]+-c|worktree[[:space:]]+(add|remove))([[:space:]]|\$)"
  local p4="${g}branch[[:space:]]+(-[dDmMcC]|--delete|--move|--copy|--force|--set-upstream-to)([[:space:]]|=|\$)"
  local p5="${g}branch[[:space:]]+[A-Za-z_\"'\$][^[:space:]]*([[:space:]]|\$)"
  [[ $t =~ $p1 ]] && return 0
  [[ $t =~ $p2 ]] && return 0
  [[ $t =~ $p3 ]] && return 0
  [[ $t =~ $p4 ]] && return 0
  [[ $t =~ $p5 ]] && return 0
  return 1
}

# _gaia_capcheck_detect_tmp <text>: a write into the system temporary
# directory -- a bare/flags-only mktemp, a literal $TMPDIR, or a literal /tmp
# path. An mktemp carrying a path template is a write into that path instead,
# and the write detector claims it.
_gaia_capcheck_detect_tmp() {
  local t="$1"
  local mk="${_GAIA_CAPCHECK_CMD}mktemp([^A-Za-z0-9_-]|\$)"
  local td='\$\{?TMPDIR'
  local lit="(^|[^A-Za-z0-9_.-])/tmp(/|[\"'[:space:]]|\$)"
  if [[ $t =~ $mk ]]; then
    _gaia_capcheck_mktemp_template "$t"
    case "$_GAIA_CAPCHECK_RET" in
      */*) ;;
      *) return 0 ;;
    esac
  fi
  [[ $t =~ $td ]] && return 0
  [[ $t =~ $lit ]] && return 0
  return 1
}

# Commands whose non-flag operands are write targets, and those whose LAST
# operand alone is.
_GAIA_CAPCHECK_WRITE_ALL="mkdir rm touch tee install mktemp"
_GAIA_CAPCHECK_WRITE_LAST="cp mv ln"

# _gaia_capcheck_scan_writes <repo_root> <rel> <text> <loc>: emits a
# `TERM\tfs-write:<glob>\t<loc>` record per resolvable write target on the
# line, and `UNRES` for a target with no resolvable literal prefix at all.
#
# Redirects are read off the line; `>`/`>>` into /dev/*, a file-descriptor
# duplication, a here-document, and a here-string are never a write. The
# command arm covers mkdir/rm/cp/mv/touch/tee/ln/install, `sed -i`, a
# `find ... -exec rm`, and an mktemp carrying a path template.
_gaia_capcheck_scan_writes() {
  local repo_root="$1" rel="$2" text="$3" loc="$4"
  local stripped m tgt p rc cmd tok last stop seen_cmd=0
  _gaia_capcheck_strip_tests "$text"
  stripped="$_GAIA_CAPCHECK_RET"

  while IFS= read -r m; do
    [ -n "$m" ] || continue
    tgt="${m#*>}"
    tgt="${tgt#>}"
    tgt="${tgt#"${tgt%%[![:space:]]*}"}"
    _gaia_capcheck_emit_write "$repo_root" "$rel" "$tgt" "$loc"
  done < <(printf '%s\n' "$stripped" \
    | grep -oE '(^|[[:space:]])[0-9]?>>?[[:space:]]*[^[:space:];|&<>)]+' 2>/dev/null)

  local sedp="${_GAIA_CAPCHECK_CMD}sed[[:space:]]+(-[a-zA-Z]*i[a-zA-Z]*|--in-place)([[:space:]]|=|\$)"
  local findp="${_GAIA_CAPCHECK_CMD}find[[:space:]].*-exec[[:space:]]+rm([[:space:]]|\$)"
  if [[ $stripped =~ $findp ]]; then
    seen_cmd=0
    while IFS= read -r tok; do
      if [ "$seen_cmd" -eq 0 ]; then
        [ "${tok##*[\(\`]}" = "find" ] && seen_cmd=1
        continue
      fi
      case "$tok" in
        -*|'{}'|'+'|'\;'|';'|'|'|'&&'|'||') continue ;;
      esac
      _gaia_capcheck_emit_write "$repo_root" "$rel" "$tok" "$loc"
      break
    done < <(_gaia_capcheck_tokens "$stripped")
    return 0
  fi
  if [[ $stripped =~ $sedp ]]; then
    last=""
    while IFS= read -r tok; do
      case "$tok" in
        -*|'{}'|'\;'|';'|'|'|'&&'|'||') continue ;;
      esac
      last="$tok"
    done < <(_gaia_capcheck_tokens "$stripped")
    [ -n "$last" ] && _gaia_capcheck_emit_write "$repo_root" "$rel" "$last" "$loc"
    return 0
  fi

  # shellcheck disable=SC2086
  for cmd in $_GAIA_CAPCHECK_WRITE_ALL $_GAIA_CAPCHECK_WRITE_LAST; do
    local pat="${_GAIA_CAPCHECK_CMD}${cmd}([[:space:]]|\$)"
    [[ $stripped =~ $pat ]] || continue
    seen_cmd=0
    last=""
    while IFS= read -r tok; do
      if [ "$seen_cmd" -eq 0 ]; then
        [ "${tok##*[\(\`]}" = "$cmd" ] && seen_cmd=1
        continue
      fi
      stop=0
      case "$tok" in
        *';'*) tok="${tok%%;*}"; stop=1 ;;
      esac
      case "$tok" in
        ''|-*) [ "$stop" -eq 1 ] && break; continue ;;
        '||'|'&&'|'|'|')'|'{'|'2>'*|'>'*|'<'*) break ;;
      esac
      case " $_GAIA_CAPCHECK_WRITE_LAST " in
        *" $cmd "*) last="$tok" ;;
        *)
          if [ "$cmd" = "mktemp" ]; then
            case "$tok" in
              */*) _gaia_capcheck_emit_write "$repo_root" "$rel" "$tok" "$loc" ;;
            esac
            break
          fi
          _gaia_capcheck_emit_write "$repo_root" "$rel" "$tok" "$loc"
          ;;
      esac
      [ "$stop" -eq 1 ] && break
    done < <(_gaia_capcheck_tokens "$stripped")
    [ -n "$last" ] && _gaia_capcheck_emit_write "$repo_root" "$rel" "$last" "$loc"
  done
  return 0
}

# _gaia_capcheck_emit_write <repo_root> <rel> <target> <loc>: resolve one write
# target and print its term, or an UNRES record.
_gaia_capcheck_emit_write() {
  local repo_root="$1" rel="$2" tgt="$3" loc="$4" p rc out
  _gaia_capcheck_unquote "$tgt"
  tgt="$_GAIA_CAPCHECK_RET"
  # Trailing shell punctuation rides along on a whitespace split.
  while :; do
    case "$tgt" in
      *")"|*"}"|*'"'|*"'"|*";"|*",") tgt="${tgt%?}" ;;
      *) break ;;
    esac
  done
  case "$tgt" in
    ''|'&'*|/dev/*|'-') return 0 ;;
    [0-9]) return 0 ;;
    '$('*|'`'*|*'$('*) return 0 ;;
  esac
  # A target has to be shaped like a path: it carries a separator, an
  # extension, or a variable. Deliberately not matched, and the reason this
  # test exists: a bare word after `>` inside an embedded awk or jq program
  # (`if (n > max)`, `. as $f`) is a comparison or a binding, and those
  # programs are the overwhelming majority of what a redirect matcher finds
  # in this tree. The accepted miss is a real redirect to a bare filename
  # with no directory and no extension.
  case "$tgt" in
    */*|*.*|*'$'*) ;;
    *) return 0 ;;
  esac
  out="$(_gaia_capcheck_write_paths "$repo_root" "$rel" "$tgt" 0)"
  rc=$?
  [ "$rc" -eq 2 ] && return 0
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'UNRES\t%s\t%s\n' "$loc" "$tgt"
    return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if _gaia_capcheck_path_to_term "$p"; then
      printf 'TERM\t%s\t%s\n' "$_GAIA_CAPCHECK_RET" "$loc"
    else
      printf 'UNRES\t%s\t%s\n' "$loc" "$tgt"
    fi
  done <<EOF
$out
EOF
  return 0
}

# _gaia_capcheck_scan_invocations <repo_root> <rel> <sc> <text> <loc>: emits a
# `CALL\t<target>\t<loc>` record per resolved invocation site, or `UNRES`.
# Sourcing counts as invocation: `.` and `source` are sites exactly like
# `bash` and `sh`.
_gaia_capcheck_scan_invocations() {
  local repo_root="$1" rel="$2" sc="$3" text="$4" loc="$5"
  local rest="$text" rem head hops=0
  local pat="${_GAIA_CAPCHECK_CMD}(bash|sh|source|\\.)[[:space:]]+"
  while [ "$hops" -lt 4 ] && [[ $rest =~ $pat ]]; do
    hops=$((hops + 1))
    rem="${rest#*"${BASH_REMATCH[0]}"}"
    rest="$rem"
    # Skip the command's own flags to reach its script operand.
    while :; do
      case "$rem" in
        -*) rem="${rem#*[[:space:]]}"; rem="${rem#"${rem%%[![:space:]]*}"}" ;;
        *) break ;;
      esac
    done
    [ -n "$rem" ] || continue
    local head="${rem%%[[:space:];|&)]*}"
    case "$head" in
      */*|*.sh|*.sh\"|'$'*|'"$'*) ;;
      *) continue ;;
    esac
    if _gaia_capcheck_resolve_invocation "$repo_root" "$rel" "$sc" "$rem"; then
      printf 'CALL\t%s\t%s\n' "$_GAIA_CAPCHECK_RET" "$loc"
    else
      local raw="${rem%%[[:space:];|&)]*}"
      printf 'UNRESC\t%s\t%s\n' "$loc" "$raw"
    fi
  done
  return 0
}

# _gaia_capcheck_file_sites <repo_root> <rel>: every capability one file
# reaches for on its own, as `TERM`/`CALL`/`UNRES` records. Comment lines are
# not reach; a `gh api` in a header comment is documentation.
_gaia_capcheck_file_sites() {
  local repo_root="$1" rel="$2" file="$1/$2"
  [ -f "$file" ] || return 0
  local lineno sc text stripped loc
  while IFS=$'\t' read -r lineno sc text; do
    [ -n "$lineno" ] || continue
    loc="$rel:$lineno"
    _gaia_capcheck_strip_literals "$text"
    stripped="$_GAIA_CAPCHECK_RET"
    _gaia_capcheck_detect_network "$stripped" && printf 'TERM\tnetwork\t%s\n' "$loc"
    _gaia_capcheck_detect_github_write "$stripped" && printf 'TERM\tgithub-write\t%s\n' "$loc"
    _gaia_capcheck_detect_git_write "$stripped" && printf 'TERM\tgit-write\t%s\n' "$loc"
    _gaia_capcheck_detect_tmp "$stripped" && printf 'TERM\ttmp\t%s\n' "$loc"
    _gaia_capcheck_scan_writes "$repo_root" "$rel" "$stripped" "$loc"
    _gaia_capcheck_scan_invocations "$repo_root" "$rel" "$sc" "$stripped" "$loc"
  done < <(_gaia_capcheck_logical_lines "$file")
  return 0
}

# _gaia_capcheck_closure <repo_root> <script> <declared-invokes>: the closure
# walk (C-7). Prints `<term>\t<file>:<line>` for every capability the script
# reaches directly or through any target it invokes, and
# `UNRESOLVED\t<file>:<line>\t<raw>` for every site no idiom resolves.
#
# The visited set is keyed by resolved repo-relative path and carried per
# obligated root, so each file is entered at most once and a cycle terminates
# with a verdict rather than a hang. Targets named in the entry's `invokes:`
# array join the frontier alongside resolved ones.
_gaia_capcheck_closure() {
  local repo_root="$1" root_script="$2" declared="$3"
  local frontier="$root_script" visited="" cur kind a b
  [ -n "$declared" ] && frontier="$frontier
$declared"
  while [ -n "$frontier" ]; do
    if [ "${frontier%%$'\n'*}" = "$frontier" ]; then
      cur="$frontier"; frontier=""
    else
      cur="${frontier%%$'\n'*}"; frontier="${frontier#*$'\n'}"
    fi
    [ -n "$cur" ] || continue
    case "$visited" in
      "$cur"|"$cur"$'\n'*|*$'\n'"$cur"|*$'\n'"$cur"$'\n'*) continue ;;
    esac
    visited="${visited:+$visited$'\n'}$cur"
    [ -f "$repo_root/$cur" ] || continue
    while IFS=$'\t' read -r kind a b; do
      case "$kind" in
        TERM) printf '%s\t%s\n' "$a" "$b" ;;
        CALL)
          printf 'invokes:%s\t%s\n' "$a" "$b"
          frontier="${frontier:+$frontier$'\n'}$a"
          ;;
        UNRES) printf 'UNRESOLVED\t%s\t%s\n' "$a" "$b" ;;
        UNRESC) printf 'UNRESOLVED-CALL\t%s\t%s\n' "$a" "$b" ;;
      esac
    done < <(_gaia_capcheck_file_sites "$repo_root" "$cur")
  done
  return 0
}
