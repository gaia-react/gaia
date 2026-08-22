#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2016
#
# SC2034 is disabled file-wide because this is a PARTIAL copy: it holds the
# eleven bodies the change rewrote and no others, so a local one of them
# declares for a sibling it hands off to reads as unused here even though the
# sibling is live in the oracle itself. Vendoring that sibling to quiet the
# warning would be worse -- a function the change did not touch belongs on the
# shipped side of the comparison, not the frozen one.
# shellcheck disable=SC2034
#
# The pre-change bodies of every function this repository's termination fix,
# detector repairs and resolution idioms rewrote in
# .gaia/scripts/capability-oracle-lib.sh, copied verbatim.
#
# Sourced AFTER the shipped oracle, it redefines those eleven functions and
# nothing else, which restores the oracle's whole previous behaviour: none of
# the four functions the change ADDED is reachable once these bodies are back,
# because every call to one of them lives inside a body this file overrides.
#
# Two suites read it, for two different jobs.
#
#   check-script-capabilities.bats compares the allowlisted-script surface's
#   computed reach before and after, byte for byte. That comparison is only
#   worth running IN-PROCESS: check-script-capabilities.sh re-sources the
#   shipped oracle from its own directory at load time, so a child process
#   started with `bash <check> --print-reach` clobbers any inherited definition
#   and compares two identical shipped runs, which can never fail.
#
#   capability-oracle-termination.bats asserts the red: the pre-change
#   _gaia_capcheck_strip_tests below does not terminate on a logical line
#   carrying a `]]` that closes nothing ahead of a later complete pair.
#
# This file is a frozen copy, not a mirror. Do not "update" it when the oracle
# changes again: a later change vendors its own before-side, and editing this
# one to match the shipped oracle makes both suites compare a thing to itself.
#
# It is therefore a SECOND definition, in this tree, of every function it holds,
# `_gaia_capcheck_scan_writes` and `_gaia_capcheck_strip_tests` among them. Any
# check asserting the oracle has exactly one definition of a name is asserting
# that no CALLER forked it, and has to count definitions outside this directory
# to say that; counting them tree-wide reports a frozen test input as a fork.

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

_gaia_capcheck_state_root_hop() {
  local text="$1"
  case "$text" in
    *gaia_resolve_plans_dir*) _GAIA_CAPCHECK_RET=".gaia/local/plans"; return 0 ;;
    *gaia_resolve_specs_dir*) _GAIA_CAPCHECK_RET=".gaia/local/specs"; return 0 ;;
  esac
  return 1
}

_gaia_capcheck_assignment_values() {
  local repo_root="$1" rel="$2" var="$3" file="$1/$2"
  [ -f "$file" ] || return 0
  local line tail v rest pre cand found lastch
  while IFS= read -r line; do
    _gaia_capcheck_is_comment_line "$line" && continue
    # Boundary-anchored, to match the grep that selected this line. A plain
    # `${line#*"$var"=}` is a shortest-prefix strip, so a line carrying both
    # `PLAN_root=zzz` and `root="$1"` yields `zzz` -- a wrong value shaped like
    # a right one, reported as a narrow reach instead of failing loud.
    rest="$line"
    tail=""
    found=0
    while :; do
      pre="${rest%%"$var"=*}"
      [ "$pre" = "$rest" ] && break
      cand="${rest#"$pre""$var"=}"
      if [ -z "$pre" ]; then
        tail="$cand"
        found=1
        break
      fi
      lastch="${pre#"${pre%?}"}"
      case "$lastch" in
        [[:space:]] | '|' | '&' | ';' | '(')
          tail="$cand"
          found=1
          break
          ;;
      esac
      rest="$cand"
    done
    [ "$found" -eq 1 ] || continue
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
