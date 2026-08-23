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
# else, beyond the bash-version refusal below.
#
# Needs bash 5. On bash 3.2 the scan over a file's logical lines does not end
# early, it dies: the process segfaults on the child side of a fork, before
# exec, inside the system notify library's atfork handler, and takes every
# record past that point with it. It exits 133 and prints nothing, and a
# consumer reading the walk over a pipe or a process substitution sees an
# ordinary end of input, so reach comes back under-reported rather than
# over-reported. That is the direction that cannot surface as a finding, so
# this refuses instead of answering.
#
# The dependency is on a bash that does not crash, and no restructuring here
# removes it. Reading the outer input through an explicit descriptor and
# buffering it ahead of the loop both leave the crash where it was, and no
# single detector triggers it: the write scan and the invocation scan are each
# clean alone and crash only together. The crash point also moves with edits to
# the loop body that cannot affect it causally, which is the signature of heap
# corruption rather than of a descriptor this code owns. The version guard is
# the repair; a code change that appears to fix it has only perturbed the
# allocation pattern, and the next unrelated edit re-rolls it.
#
# A library cannot re-exec on its own behalf, so each executable entry point
# carries its own discovery-and-re-exec block ahead of sourcing this file and
# never reaches here; this is the backstop that gives a future consumer the
# refusal without it having to remember the guard.
#
# Every detector here is deliberately incomplete in one direction and says so in
# its own header. The oracle is lexical: it does not evaluate, it does not model
# the call graph across function boundaries, and a path a script computes at run
# time is reported as belonging to whoever computes it. Those limits are stated
# at each site rather than summarized here, so a reader auditing one detector
# sees the limit that applies to it.

if [ "${BASH_VERSINFO[0]}" -lt 5 ]; then
  printf 'capability-oracle-lib: requires bash >= 5, found %s\n' "${BASH_VERSION}" >&2
  printf '  bash 3.2 crashes partway through the walk, so reach is\n' >&2
  printf '  under-reported.\n' >&2
  exit 2
fi

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

# Command words that only ever mean reach when the shell is going to run them:
# every name the detectors below look for, plus the `.` builtin. Held with
# leading and trailing spaces so a membership test is one `case`.
_GAIA_CAPCHECK_QUOTED_WORDS=" mkdir rm touch tee install mktemp cp mv ln sed find bash sh source . curl wget gh git "

# _gaia_capcheck_strip_quoted_code <text>: inside every DOUBLE-quoted span,
# blanks the command words listed above and the `>` redirect operator, leaving
# the result in _GAIA_CAPCHECK_RET.
#
# A command name inside a double-quoted string is prose: a deny message that
# says `rm -rf of .git is forbidden`, a usage block that spells out
# `bash .gaia/scripts/x.sh`, a jq program comparing `$a > $b`. The shell will
# never run any of it, and read as code it produces write targets and
# invocation targets that name nothing -- the `fs-write:forbidden.` family, and
# the `.gaia/scripts/...` a reader is being told to type.
#
# Only the command words and the redirect operator are blanked, never the whole
# span: `rm -f "$sentinel"` keeps its operand, which is the target the write
# detector exists to find. That asymmetry is the whole point -- the command word
# of a real invocation is always OUTSIDE the quotes, its operand routinely
# inside them.
#
# A line carrying a command substitution is left ALONE. `"$( cd "$x" && bash
# "$y" )"` is real code whose own quotes nest inside the outer pair, and a flat
# odd/even reading of the quotes on such a line lands on the wrong side of
# them: it read ` && bash ` as quoted prose and blinded the oracle to a live
# invocation. Skipping those lines keeps today's answer for them, which is the
# safe direction.
#
# Deliberately incomplete in four directions. It does not model `bash -c
# "..."`, `ssh host "..."`, or any other eval, for the same reason
# _gaia_capcheck_strip_literals does not: an eval is outside this oracle. It
# does not model a backslash-escaped `\"`, which reads as a span boundary. It
# skips any line carrying `$(` or a backtick, per the paragraph above. And it
# is per logical line, so a double-quoted string spanning several real lines is
# only recognized on the line that opens it; the joiner joins backslash
# continuations, not string bodies.
_gaia_capcheck_strip_quoted_code() {
  local t="$1" out="" head body word
  case "$t" in
    *'$('*|*'`'*) _GAIA_CAPCHECK_RET="$t"; return 0 ;;
    *'"'*) ;;
    *) _GAIA_CAPCHECK_RET="$t"; return 0 ;;
  esac
  while :; do
    case "$t" in
      *'"'*) ;;
      *) out="$out$t"; break ;;
    esac
    head="${t%%\"*}"
    out="$out$head"
    t="${t#*\"}"
    case "$t" in
      *'"'*) body="${t%%\"*}"; t="${t#*\"}" ;;
      *) body="$t"; t="" ;;
    esac
    # Padded so a word at either end of the span still has a space on both
    # sides, which is what makes one `case` test and one substitution enough.
    body=" $body "
    case "$body" in *'>'*) body="${body//>/ }" ;; esac
    # shellcheck disable=SC2086
    for word in $_GAIA_CAPCHECK_QUOTED_WORDS; do
      case "$body" in *" $word "*) body="${body// $word / }" ;; esac
    done
    body="${body# }"; body="${body% }"
    out="$out\"$body\""
    [ -n "$t" ] || break
  done
  _GAIA_CAPCHECK_RET="$out"
  return 0
}

# _gaia_capcheck_strip_tests <text>: blanks out `[[ ... ]]` and `(( ... ))`
# spans, leaving the result in _GAIA_CAPCHECK_RET. `>` inside a conditional or
# an arithmetic expression is a comparison, not a redirect, and the two are
# indistinguishable to a redirect matcher.
#
# The tail is spliced from the closer that FOLLOWS the opener, not from the
# first closer anywhere in the line. A logical line may carry a `]]` that
# closes nothing -- a POSIX bracket expression inside an earlier regex, a
# `case` arm, a message -- ahead of a later complete pair, and splicing from
# that one retains it in the head and re-appends it every pass, so the string
# grows and the loop never ends. Both arms are spliced this way for the same
# reason; the `((` arm's stray closer is rarer but the asymmetry is identical.
#
# Deliberately incomplete in one direction: the span is delimited lexically, so
# an opener with no closer anywhere on the line is left alone rather than
# swallowing the rest of the text. The `case` guard requires both tokens in
# that order, which is also what makes each pass strictly remove one opener and
# so guarantees the loop terminates.
_gaia_capcheck_strip_tests() {
  local t="$1" pre post
  while :; do
    case "$t" in
      *'[['*']]'*)
        pre="${t%%\[\[*}"; post="${t#*\[\[}"; post="${post#*\]\]}"; t="$pre $post"
        ;;
      *'(('*'))'*)
        pre="${t%%\(\(*}"; post="${t#*\(\(}"; post="${post#*\)\)}"; t="$pre $post"
        ;;
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
#
# The hop may join a suffix on EITHER side of the `$(cd ... && pwd)` that wraps
# it, and a live spelling joins one on both:
#
#   "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.gaia/scripts/x.sh"
#
# Reading only the inner suffix there answers "the repo root" for a target that
# is a named file inside it, so the outer literal run is appended when the
# substitution closes on `pwd)`. Deliberately incomplete in one direction: the
# close is matched lexically on that one token, so a wrapper spelled with any
# other final command contributes no outer suffix.
_gaia_capcheck_dirhop() {
  local rel="$1" text="$2" tail suffix rest outer dir
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
  rest="${tail#"$suffix"}"
  case "$rest" in
    *'pwd)'*)
      outer="${rest#*pwd)}"
      outer="${outer%%[\"[:space:]\&|\)\;]*}"
      suffix="$suffix$outer"
      ;;
  esac
  _gaia_capcheck_dirname_rel "$rel"
  dir="$_GAIA_CAPCHECK_RET"
  _gaia_capcheck_normalize "${dir}${suffix}" || return 1
  return 0
}

# _gaia_capcheck_state_root_hop <text>: recognizes a call to one of GAIA's own
# main-anchored resolvers (ledger-path-lib.sh's gaia_resolve_plans_dir /
# gaia_resolve_specs_dir / gaia_resolve_ledger_path, main-root-lib.sh's
# gaia_resolve_main_root, and red-ledger.sh's red_ledger_path). Each takes the
# checkout to resolve from as its own argument and answers with a checkout
# root, or with a single hardcoded path joined onto the main checkout's
# .gaia/local, so unlike an arbitrary function call its result is a fixed
# repo-relative path regardless of which checkout it runs in or what argument
# it is handed -- the same closed-set, name-matched recognition idiom 3 already
# applies to the BASH_SOURCE dirname hop.
#
# gaia_resolve_main_root answers the checkout root itself, whose repo-relative
# reading is the empty string. That is what makes a main-anchored write
# (`"$main_root/.gaia/local/debt"`) reduce to the same repo-relative path in
# every checkout, which is the whole point of anchoring it. Without it the
# variable holds a value computed at run time, every write through it is
# unresolvable, and none of them is literalizable: the anchoring is the
# behaviour, so replacing it with a literal would break the worktree case it
# exists for.
#
# Two answers here are not directories, which is why callers join a suffix onto
# the answer rather than assuming one. gaia_resolve_ledger_path answers a FILE,
# and red_ledger_path answers a file under a per-tree key directory the caller
# picks at run time, so its answer carries a `*` in that one segment and
# _gaia_capcheck_path_to_term generalizes from the literal prefix in front of
# it. Deliberately incomplete in one direction: the match is on the function
# name alone, so a same-named function defined somewhere else would be read as
# this one.
_gaia_capcheck_state_root_hop() {
  local text="$1"
  case "$text" in
    *gaia_resolve_plans_dir*) _GAIA_CAPCHECK_RET=".gaia/local/plans"; return 0 ;;
    *gaia_resolve_specs_dir*) _GAIA_CAPCHECK_RET=".gaia/local/specs"; return 0 ;;
    *gaia_resolve_ledger_path*) _GAIA_CAPCHECK_RET=".gaia/local/telemetry/cost.jsonl"; return 0 ;;
    *red_ledger_path*) _GAIA_CAPCHECK_RET=".gaia/local/red-ledger/*/observations.jsonl"; return 0 ;;
    *gaia_resolve_main_root*) _GAIA_CAPCHECK_RET=""; return 0 ;;
  esac
  return 1
}

# _gaia_capcheck_home_hop <text>: recognizes an assignment whose whole value is
# the user's home directory (`"$HOME"`, `"${HOME}"`, `"${HOME:-}"`). Answers
# `~`, which is a root no repo-relative reading can be confused with.
#
# The home directory is the one root a write can be anchored at that is NOT
# this repository, and reporting it as one would name a path inside the repo
# that the file never touches. `~` keeps the reach declarable -- the term for a
# write under it generalizes to `fs-write:~/<literal prefix>/**` like any other
# -- while staying unmistakable to a reader of the manifest.
#
# Deliberately incomplete in one direction: only a value that is nothing but a
# HOME reference is matched. A home directory derived some other way
# (`getent passwd`, a `~` expansion through a command substitution) is not
# recognized, and _gaia_capcheck_home_rooted still refuses it rather than
# letting it reach the root reading.
_gaia_capcheck_home_hop() {
  local v="$1"
  _gaia_capcheck_unquote "$v"
  case "$_GAIA_CAPCHECK_RET" in
    '$HOME'|'${HOME}'|'${HOME:-}') _GAIA_CAPCHECK_RET='~'; return 0 ;;
  esac
  return 1
}

# _gaia_capcheck_toplevel_hop <text>: recognizes `git rev-parse --show-toplevel`,
# git's own answer to "where is the checkout root". Its repo-relative reading is
# the empty string, exactly what _gaia_capcheck_state_root_hop returns for
# gaia_resolve_main_root, so a write anchored at it reduces to the same
# repo-relative path in every checkout.
#
# Deliberately incomplete in one direction, and it is a different one from the
# git-directory hop's: inside a LINKED worktree this names THAT worktree, while
# gaia_resolve_main_root names the main checkout. The two disagree about which
# tree on disk is meant and agree about the repo-relative string, which is the
# only thing a capability term carries. That is the same worktree approximation
# _gaia_capcheck_git_dir_hop already takes, and it is licensed here for the same
# reason: a term never distinguishes two checkouts of one repository.
_gaia_capcheck_toplevel_hop() {
  local text="$1"
  case "$text" in
    *rev-parse*) ;;
    *) return 1 ;;
  esac
  case "$text" in
    *--show-toplevel*) _GAIA_CAPCHECK_RET=""; return 0 ;;
  esac
  return 1
}

# _gaia_capcheck_first_operand <text>: the first non-flag operand in <text>,
# unquoted and stripped of the shell punctuation a whitespace split drags along.
# Returns 1 when the first thing that is not a flag is a separator, a redirect,
# or the end of the text -- a command with no operand names no path.
#
# Deliberately incomplete in one direction: a flag taking its value as a
# separate word is indistinguishable here from a flag with no value, so the
# word after such a flag reads as the operand. Every caller applies this to a
# command whose path operand comes first.
_gaia_capcheck_first_operand() {
  local text="$1" tok
  _GAIA_CAPCHECK_RET=""
  while IFS= read -r tok; do
    case "$tok" in
      ''|'--') continue ;;
      '2>'*|'>'*|'<'*|'&&'|'||'|'|'|'&'|';'*|')'*) return 1 ;;
      -*) continue ;;
    esac
    _gaia_capcheck_unquote "$tok"
    tok="$_GAIA_CAPCHECK_RET"
    while :; do
      case "$tok" in
        *')'|*'"'|*"'"|*';'|*',') tok="${tok%?}" ;;
        *) break ;;
      esac
    done
    [ -n "$tok" ] || return 1
    _GAIA_CAPCHECK_RET="$tok"
    return 0
  done < <(_gaia_capcheck_tokens "$text")
  return 1
}

# _gaia_capcheck_pathfn_operand <text> <fn>: the first operand of the
# `$(<fn> ...)` command substitution in <text>. Returns 1 when <text> opens no
# such substitution.
_gaia_capcheck_pathfn_operand() {
  local text="$1" fn="$2" tail
  case "$text" in
    *'$('"$fn"[[:space:]]*) tail="${text#*\$\("$fn"}" ;;
    *) return 1 ;;
  esac
  _gaia_capcheck_first_operand "$tail"
}

# _gaia_capcheck_dirname_values <repo_root> <rel> <operand>: idiom 12, the
# DIRNAME hop. `d="$(dirname "$f")"` names the directory of a path the file
# already locates, so where <operand> resolves, `d` does too -- one
# `DIRHOP:<dir>` line per resolved candidate, left in _GAIA_CAPCHECK_RET.
# Returns 1 when <operand> resolves to nothing, which leaves the assignment
# reading exactly as it did before this idiom existed.
#
# _GAIA_CAPCHECK_DNDEPTH bounds the mutual recursion this opens: resolving the
# operand goes back through _gaia_capcheck_assignment_values, which may meet
# another `dirname` assignment (or the same one, in `x="$(dirname "$x")"`).
# The counter rides through the command substitutions the walk already uses, so
# each nested resolution sees its own depth and a cycle stops rather than hangs.
#
# Deliberately incomplete in one direction: the caller-designated `**` sentinel
# has no parent to take, so it is passed through unchanged rather than being
# narrowed to something the caller did not choose.
_gaia_capcheck_dirname_values() {
  local repo_root="$1" rel="$2" operand="$3" sub p out="" n=0
  # The bump being local to this substitution is the mechanism, not a bug: the
  # nested resolution runs inside it and inherits the raised count, while the
  # caller's own count is left where it was. Shellcheck reads the pair as a
  # value that might be lost, which is the case this deliberately wants.
  # shellcheck disable=SC2030
  sub="$(
    _GAIA_CAPCHECK_DNDEPTH=$(( ${_GAIA_CAPCHECK_DNDEPTH:-0} + 1 ))
    _gaia_capcheck_write_paths "$repo_root" "$rel" "$operand" 0
  )" || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$p" = '**' ]; then
      out="${out}**
"
      n=$((n + 1))
      continue
    fi
    _gaia_capcheck_dirname_rel "$p"
    out="${out}DIRHOP:${_GAIA_CAPCHECK_RET}
"
    n=$((n + 1))
  done <<DNVALS
$sub
DNVALS
  [ "$n" -ge 1 ] || return 1
  _GAIA_CAPCHECK_RET="$out"
  return 0
}

# _gaia_capcheck_git_dir_hop <text>: recognizes an assignment whose value is
# git's own answer to "where is the git directory" -- `rev-parse` carrying
# `--git-dir`, `--absolute-git-dir`, or `--git-common-dir`. Like the state-root
# hop above this is a closed-set, name-matched recognition rather than an
# evaluation: whatever the absolute answer is on the day, its repo-relative
# reading is `.git`, so a lock file or a marker written beside it reduces to the
# same repo-relative path in every checkout.
#
# Deliberately incomplete in one direction: inside a LINKED worktree
# `--git-dir` answers `.git/worktrees/<name>` while `--git-common-dir` answers
# the main `.git`, and this reads both as `.git`. That is a prefix of the truth
# in the worktree case, never a different tree, which is the direction a
# capability term can absorb. `--show-toplevel` is deliberately not matched
# here: it names the checkout, not the git directory, and its own hop above
# answers for it.
_gaia_capcheck_git_dir_hop() {
  local text="$1"
  case "$text" in
    *rev-parse*) ;;
    *) return 1 ;;
  esac
  case "$text" in
    *--absolute-git-dir*|*--git-common-dir*|*--git-dir*)
      _GAIA_CAPCHECK_RET=".git"
      return 0
      ;;
  esac
  return 1
}

# _gaia_capcheck_assignment_values <repo_root> <rel> <var>: one value per
# assignment of <var> in <rel>, in file order. A value is either the raw right
# side, `DIRHOP:<repo-relative-path>`, or `MKTEMP:<template>`.
_gaia_capcheck_assignment_values() {
  local repo_root="$1" rel="$2" var="$3" file="$1/$2"
  [ -f "$file" ] || return 0
  local line tail v rest pre cand found lastch operand
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
    if _gaia_capcheck_git_dir_hop "$tail"; then
      printf 'DIRHOP:%s\n' "$_GAIA_CAPCHECK_RET"
      continue
    fi
    if _gaia_capcheck_toplevel_hop "$tail"; then
      printf 'DIRHOP:%s\n' "$_GAIA_CAPCHECK_RET"
      continue
    fi
    if _gaia_capcheck_home_hop "$tail"; then
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
    # Idiom 11, the `$(cd <dir> ... && pwd)` ABSOLUTIZER. The substitution
    # answers the absolute path of its own operand, so the value the variable
    # holds is that operand, and every resolver already knows how to read one.
    # Reading the substitution instead leaves a value beginning `$(`, which is
    # refused as computed at run time even where the operand resolves fully.
    # The dirhop above claims the `$(cd "$(dirname "${BASH_SOURCE[0]}")..." && pwd)`
    # spelling first, so this only ever sees the ones it does not.
    #
    # Deliberately incomplete in one direction: `pwd` is matched anywhere in the
    # tail rather than parsed as the substitution's final command, so a `cd`
    # substitution ending in something else contributes nothing and a line
    # carrying an unrelated later `pwd` reads its `cd` operand as the value.
    case "$tail" in
      *'$(cd '*)
        case "$tail" in
          *pwd*)
            if _gaia_capcheck_pathfn_operand "$tail" cd; then
              printf '%s\n' "$_GAIA_CAPCHECK_RET"
              continue
            fi
            ;;
        esac
        ;;
    esac
    # Idiom 12, the DIRNAME hop. Bounded against the mutual recursion resolving
    # the operand opens; past the bound the assignment reads as it did before.
    case "$tail" in
      *'$(dirname'*)
        # shellcheck disable=SC2031
        if [ "${_GAIA_CAPCHECK_DNDEPTH:-0}" -lt 2 ] \
          && _gaia_capcheck_pathfn_operand "$tail" dirname \
          && operand="$_GAIA_CAPCHECK_RET" \
          && _gaia_capcheck_dirname_values "$repo_root" "$rel" "$operand"; then
          printf '%s' "$_GAIA_CAPCHECK_RET"
          continue
        fi
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
      # `${var:?}` / `${var:?message}` asserts the variable is set and expands
      # to its value or nothing at all -- there is no alternative value to
      # disagree with, so the operator names the same variable a bare `$var`
      # does. `${var:-default}` deliberately stays rejected: it carries a second
      # value this oracle would have to choose between.
      case "$name" in
        *':?'*) name="${name%%':?'*}" ;;
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
  # A positional IS the caller's answer, with no assignment to trace. The scan
  # below only ever visits assignments, so without this the direct spelling
  # (`"$1/RUNNING"`) would fall through to the root reading and report a narrow
  # term, while the variable-mediated one (`target="$1"`) reported `**`. Same
  # write, same caller, two answers, and the narrow one is a fail-open.
  _gaia_capcheck_is_positional_name "$var" && return 0
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

# _gaia_capcheck_home_rooted <repo_root> <rel> <var> <seen>: true when <var>
# holds the user's home directory, directly or through its assignment chain.
#
# This is the guard on the root reading in _gaia_capcheck_write_paths. Nothing
# in a script ever assigns `$HOME`, so a home-anchored variable reaches that
# reading with no resolved assignment and is claimed as the repo root, which
# turns `$HOME/.claude/projects/<slug>/gaia` into a write into THIS repo's
# `.claude/projects/` -- a path the script never touches, reported to a reader
# and, through the manifest, to an adopter. A home-rooted target takes the same
# answer an absolute path takes: unresolved.
#
# <seen> is the recursion's cycle guard, exactly as in
# _gaia_capcheck_caller_supplied. Deliberately incomplete in one direction: a
# home directory a script derives some other way (`getent passwd`, `~`
# expansion through a command substitution) is not recognized.
_gaia_capcheck_home_rooted() {
  local repo_root="$1" rel="$2" var="$3" seen="$4" v name
  case "$var" in HOME) return 0 ;; esac
  case " $seen " in *" $var "*) return 1 ;; esac
  seen="$seen $var"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    case "$v" in
      DIRHOP:*|MKTEMP:*) continue ;;
      *'$HOME'*|*'${HOME'*) return 0 ;;
    esac
    if _gaia_capcheck_ref_name "$v"; then
      name="$_GAIA_CAPCHECK_RET"
      _gaia_capcheck_home_rooted "$repo_root" "$rel" "$name" "$seen" && return 0
    fi
  done < <(_gaia_capcheck_assignment_values "$repo_root" "$rel" "$var")
  return 1
}

# _gaia_capcheck_resolve_dir <repo_root> <rel> <var>: the repo-relative
# directory a variable holds, when its assignments agree on exactly one.
# Idiom 4, one-hop constant propagation, with idioms 2 and 3 applied to the
# assignment's own value.
#
# Idiom 6, the SELF-APPEND, is the one assignment that is allowed to disagree.
# The two-step spelling
#
#   gaia_scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
#   gaia_scripts="$gaia_scripts/.gaia/scripts"
#
# names one directory in two moves, but read as two independent values it names
# the repo root and then `.gaia/scripts`, which disagree, so every invocation
# through the variable went unresolved. An assignment whose root variable IS
# the variable being resolved is a continuation of the value so far, not a
# fresh one, so it is composed onto it. Deliberately incomplete in one
# direction: only the leading root segment is followed, so a self-reference
# anywhere but the front of the value (`x="$prefix/$x"`) still disagrees, and a
# self-append before any resolvable assignment has nothing to compose onto and
# fails.
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
          if [ "$_GAIA_CAPCHECK_VAR" = "$var" ]; then
            [ "$n" -ge 1 ] || return 1
            _gaia_capcheck_normalize "${found:+$found/}$_GAIA_CAPCHECK_SUFFIX" || return 1
            found="$_GAIA_CAPCHECK_RET"
            n=$((n + 1))
            continue
          fi
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
  local repo_root="$1" rel="$2" sc="$3" text="$4" depth="${5:-0}" tok cand dir v
  local one="" agreed=0
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
      # Idiom 8, the FILE-valued variable. `. "$LIB"` names a whole path, not a
      # directory with a suffix to join, so the resolvers above have nothing to
      # append and read the variable's own root segment as the repo root --
      # which answers `lib/x.sh` for a `$SELF_DIR/lib/x.sh` that resolves
      # perfectly well one hop further in. Each assignment is put back through
      # this same resolver instead.
      #
      # Every assignment has to resolve and they all have to AGREE, which is the
      # rule idiom 4 applies to a directory-valued variable and holds here for
      # the same reason: a file assigned one path and then another names the
      # target at run time, and taking whichever of the two happens to exist
      # would report a call to a script the run may never make. Bounded to two
      # hops, so a longer chain or a cycle stays unresolved rather than costing
      # the walk.
      if [ -z "$suffix" ] && [ "$depth" -lt 2 ]; then
        while IFS= read -r v; do
          [ -n "$v" ] || continue
          case "$v" in
            MKTEMP:*) return 1 ;;
            DIRHOP:*)
              cand="${v#DIRHOP:}"
              [ -n "$cand" ] || return 1
              [ -f "$repo_root/$cand" ] || return 1
              ;;
            *)
              # `-` rather than `$sc`: the source directive annotates the site,
              # not the variable, so idiom 5 stays the outer call's to apply.
              _gaia_capcheck_resolve_invocation "$repo_root" "$rel" "-" "$v" $((depth + 1)) || return 1
              cand="$_GAIA_CAPCHECK_RET"
              ;;
          esac
          if [ "$agreed" -gt 0 ] && [ "$cand" != "$one" ]; then return 1; fi
          one="$cand"
          agreed=$((agreed + 1))
        done < <(_gaia_capcheck_assignment_values "$repo_root" "$rel" "$var")
        if [ "$agreed" -ge 1 ]; then _GAIA_CAPCHECK_RET="$one"; return 0; fi
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

# _gaia_capcheck_same_segment_tail <repo_root> <rel> <raw> <depth>: idiom 9,
# a reference joined to a literal INSIDE one segment ("${state_file}.tmp.$$",
# "$memo_file.$$.tmp"). One candidate repo-relative path per line; 0 with
# output, 1 otherwise.
#
# _gaia_capcheck_split_var stops at this shape because there is no `/` to split
# a root segment off, so every write through a scratch sibling of a resolvable
# file went unresolved. The reference in front of the literal is an ordinary
# variable whose own assignments resolve like any other, so it is resolved as
# one and the literal appended with no separator.
# _gaia_capcheck_path_to_term then generalizes whatever the tail leaves
# non-literal: a `$$` in it yields the parent directory's `/**`, which is the
# honest term for a sibling whose name the file picks at run time.
#
# Deliberately incomplete in two directions: only a reference at the FRONT of
# the segment is followed, so `prefix-${var}` stays unresolved, and a
# positional in that position is left to the caller-supplied test rather than
# claimed here.
_gaia_capcheck_same_segment_tail() {
  local repo_root="$1" rel="$2" raw="$3" depth="$4"
  local var tail sub base n=0
  [ "$depth" -le 3 ] || return 1
  _gaia_capcheck_ref_name "$raw" || return 1
  var="$_GAIA_CAPCHECK_RET"
  tail="$_GAIA_CAPCHECK_REFREST"
  [ -n "$tail" ] || return 1
  case "$tail" in /*) return 1 ;; esac
  _gaia_capcheck_is_positional_name "$var" && return 1
  sub="$(_gaia_capcheck_write_paths "$repo_root" "$rel" "\$$var" $((depth + 1)))" || return 1
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if [ "$base" = '**' ]; then
      printf '%s\n' '**'
      n=$((n + 1))
      continue
    fi
    _gaia_capcheck_normalize "$base$tail" || continue
    printf '%s\n' "$_GAIA_CAPCHECK_RET"
    n=$((n + 1))
  done <<TAILVALS
$sub
TAILVALS
  [ "$n" -ge 1 ] || return 1
  return 0
}

# _gaia_capcheck_loop_values <repo_root> <rel> <var>: idiom 10, the LOOP-BOUND
# target. One candidate raw target per line for a variable no assignment in the
# file ever names because a loop binds it instead; 0 with output, 1 otherwise.
#
# Two bindings are read. `for <var> in <words>` contributes each word, which is
# routinely a glob whose root is a variable the resolvers already know
# (`"$audit_dir"/*.ok`), and the glob's own non-literal segment is what
# _gaia_capcheck_path_to_term generalizes from. A `find <dir> ... | while read
# <var>` contributes `<dir>/**`, which is the honest term for a path chosen out
# of a directory the file locates: `find` may descend, so the parent's `/**` is
# the reading, never the parent itself.
#
# Deliberately incomplete in three directions. A `read` loop fed by anything but
# a `find` -- a redirect, a `jq`, a `git` listing -- contributes nothing, so the
# site stays unresolved rather than being claimed for a directory this cannot
# see. A `for` over a command substitution or an array contributes nothing for
# the same reason. And the two shapes are recognized per logical line, so a
# pipeline split across two statements is not followed.
_gaia_capcheck_loop_values() {
  local repo_root="$1" rel="$2" var="$3" file="$1/$2"
  local lineno sc text tail tok n=0 stop
  [ -f "$file" ] || return 1
  local pre="(^|[[:space:]|&;(])for[[:space:]]+${var}[[:space:]]+in[[:space:]]"
  local rd="read([[:space:]]+-[A-Za-z-]+)*[[:space:]]+${var}([[:space:]]|;|\$)"
  grep -qE "${pre}|${rd}" "$file" 2>/dev/null || return 1
  while IFS=$'\t' read -r lineno sc text; do
    [ -n "$lineno" ] || continue
    if [[ $text =~ $pre ]]; then
      tail="${text#*for "$var" in }"
      stop=0
      while IFS= read -r tok; do
        [ "$stop" -eq 0 ] || break
        case "$tok" in
          ''|'do'|'#'*) break ;;
        esac
        case "$tok" in *';'*) tok="${tok%%;*}"; stop=1 ;; esac
        [ -n "$tok" ] || break
        _gaia_capcheck_unquote "$tok"
        tok="$_GAIA_CAPCHECK_RET"
        tok="${tok//\"/}"
        [ -n "$tok" ] || continue
        printf '%s\n' "$tok"
        n=$((n + 1))
      done < <(_gaia_capcheck_tokens "$tail")
      continue
    fi
    if [[ $text =~ $rd ]]; then
      case "$text" in
        *'find '*)
          tail="${text#*find }"
          if _gaia_capcheck_first_operand "$tail"; then
            printf '%s/**\n' "$_GAIA_CAPCHECK_RET"
            n=$((n + 1))
          fi
          ;;
      esac
    fi
  done < <(_gaia_capcheck_logical_lines "$file")
  [ "$n" -ge 1 ] || return 1
  return 0
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
  local v n=0 runtime=0 supplied=0 unresolved_assign=0 vals sub base out="" lvals
  [ "$depth" -le 4 ] || return 1
  _gaia_capcheck_unquote "$raw"
  raw="$_GAIA_CAPCHECK_RET"
  case "$raw" in
    ''|/dev/*|'&'*|'|'*) return 2 ;;
    '$('*|'`'*|*'$('*) return 2 ;;
    # Rooted at the system temporary directory. _gaia_capcheck_detect_tmp has
    # already claimed the line for the `tmp` term, and the same write is not a
    # second finding -- the same reason the MKTEMP branch below gives for a
    # write through the variable holding an mktemp result. There is no
    # repo-relative reading of it to report either way.
    '$TMPDIR'*|'${TMPDIR'*) return 2 ;;
    "$repo_root"/*) raw="${raw#"$repo_root"/}" ;;
  esac
  if _gaia_capcheck_split_var "$raw"; then
    if [ -z "$_GAIA_CAPCHECK_VAR" ]; then
      _gaia_capcheck_same_segment_tail "$repo_root" "$rel" "$raw" "$depth"
      return $?
    fi
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
            # A hop answering the checkout root itself contributes no literal
            # prefix of its own, so a suffix opening with a reference leaves a
            # candidate whose very first segment is not a path. Counting it
            # would report a target with nothing to generalize from and hide
            # the readings below, which do describe this shape: the caller
            # names the path, and `**` is the term that says so.
            case "${_GAIA_CAPCHECK_RET%%/*}" in
              *'$'*) ;;
              *)
                out="${out}${_GAIA_CAPCHECK_RET}
"
                n=$((n + 1))
                ;;
            esac
          fi
          ;;
        *)
          sub="$(_gaia_capcheck_write_paths "$repo_root" "$rel" "$v" $((depth + 1)))"
          case "$?" in
            0) ;;
            2) runtime=1; continue ;;
            *)
              # An unresolved assignment that joins a LITERAL path onto a
              # reference (`local_dir="$root/.gaia/local"`) pins what the
              # variable is NOT: it is that root plus that literal, never the
              # root itself, so the root reading at the end must not claim it.
              # Without this the walk answers `cache` for a `$cache_dir` whose
              # real target is `.gaia/local/cache` -- a shorter, wrong path,
              # which is worse than saying so because it reaches the manifest.
              # A value that is nothing but a reference this oracle cannot parse
              # (`repo_root="${args[0]%/}"`) pins nothing either way, and the
              # root reduction still holds for it.
              if _gaia_capcheck_ref_name "$v" && [ -n "$_GAIA_CAPCHECK_REFREST" ]; then
                unresolved_assign=1
              fi
              continue
              ;;
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
      # A home-anchored variable is not a root this repo can read. It is tested
      # first because it reaches every branch below unresolved, and the root
      # reading at the end would claim it.
      _gaia_capcheck_home_rooted "$repo_root" "$rel" "$var" "" && return 1
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
      # Idiom 10, the LOOP-BOUND target. Tried after the two tests above,
      # because a caller-designated or home-anchored root is the stronger
      # reading, and before the root reduction below, because a loop binding is
      # a structural reading and the reduction is a fallback that would answer
      # with a bare suffix instead.
      if [ "$depth" -le 3 ]; then
        lvals="$(_gaia_capcheck_loop_values "$repo_root" "$rel" "$var")" || lvals=""
        while IFS= read -r v; do
          [ -n "$v" ] || continue
          sub="$(_gaia_capcheck_write_paths "$repo_root" "$rel" "$v" $((depth + 1)))" || continue
          while IFS= read -r base; do
            [ -n "$base" ] || continue
            if [ "$base" = '**' ]; then
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
          done <<LOOPINNER
$sub
LOOPINNER
        done <<LOOPVALS
$lvals
LOOPVALS
        if [ "$n" -gt 0 ]; then
          printf '%s' "$out"
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
      [ "$unresolved_assign" -eq 0 ] || return 1
      _gaia_capcheck_normalize "$suffix" || return 1
      printf '%s\n' "$_GAIA_CAPCHECK_RET"
      return 0
    fi
    printf '%s' "$out"
    return 0
  fi
  case "$raw" in
    /*|'~'*) return 1 ;;
    # A leading reference _gaia_capcheck_split_var could not parse
    # (`${args[0]%/}`, `${var%/*}`). It is not a literal path and must not be
    # printed as one: doing that hands the caller a candidate whose first
    # segment still carries a `$`, which _gaia_capcheck_path_to_term cannot
    # generalize, so the site reports UNRESOLVED even where the variable is a
    # checkout root and the literal remainder alone is the answer. Failing here
    # instead lets the caller fall through to its root reading, which is the
    # reduction that already applies to a `--root` parameter.
    '$'*) return 1 ;;
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

# The boundary a BARE `.` has to sit behind to be the source builtin. Plain
# whitespace is not enough for this one name: `jq -e . "$f"` and `find . -name`
# put a lone `.` after a flag or a command, and read through the general
# boundary above every one of them is an invocation of the operand that
# follows. A real `.` is in command position -- opening the line, or behind a
# separator, a subshell, or a keyword -- and that is what this matches.
# Deliberately incomplete in one direction: a `.` behind a keyword this list
# does not name reads as an operand and its target is missed.
_GAIA_CAPCHECK_DOTCMD='(^|[;|&(`{}]|[[:space:]](then|else|do|elif|!))[[:space:]]*'

# The boundary a BARE PATH has to sit behind to be an execution. It is
# _GAIA_CAPCHECK_DOTCMD's vocabulary with the lone `(` narrowed to `$(`, and
# the narrowing is the whole reason this is a separate constant.
#
# A bare `.` survives the general boundary because `.` is one of
# _GAIA_CAPCHECK_QUOTED_WORDS, so a `.` written as prose inside a double-quoted
# span is blanked before any anchor sees it. A path is not a command word and
# no blanking reaches it, so the anchor is the only defence it has -- and a
# deny message naming a script in a parenthetical (`may not run the remit
# writer (.gaia/scripts/write-audit-remits.sh)`) puts a real repo path behind a
# real `(`. Requiring the `$` keeps the command substitution, which is the
# idiom this detector exists for, and drops the parenthetical.
#
# `{` and `}` come off for a second reason, unrelated to prose: a path token
# carries `${...}`, so a brace kept as a boundary anchors INSIDE the variable
# and hands the resolver `dir}/x.sh`. The shape the brace was there for,
# `{ .gaia/x.sh; }`, is reachable through the `;` or `&&` a brace group is
# almost always written with anyway.
#
# What this anchor misses, in full, because a partial list here reads as a
# completeness claim the pattern does not make:
#
#   A `( ... )` subshell with nothing in front of the paren, which is the same
#   shape _GAIA_CAPCHECK_DOTCMD accepts for itself, and a brace group with
#   nothing in front of the brace, per the two departures above.
#
#   `if <path>; then`. The keyword list is _GAIA_CAPCHECK_DOTCMD's verbatim and
#   `if` is not on it, so a path in the condition of an `if` is missed exactly
#   as a `.` there is. Adding `if` to one list and not the other would buy a
#   third divergence between two constants whose whole readability rests on
#   being one vocabulary with two named departures.
#
# It also OVER-reads, on every arm rather than any one: nothing blanks a repo
# path inside a double-quoted span, the same fact that narrows `(` to `$(`
# above, so any anchor character surviving inside one fabricates a CALL edge
# into a subtree the caller never runs. A path in a message string and a path in
# command position are the same bytes once the quoting is invisible, so no
# per-arm narrowing reaches this: the repair is not this anchor's, and #1536
# carries where it does belong. Mostly it fails closed and loud, not wholly: a
# fabricated edge can mask a real SURPLUS by making a declared-but-unreached
# term look reached.
#
# The keyword arm is FLATTENED rather than nested, which _GAIA_CAPCHECK_DOTCMD
# has no reason to do and this constant does: its one and only caller reads the
# path token back out of BASH_REMATCH by index, and a nested group here shifts
# that index without changing what the pattern matches. The caller then reads an
# empty token off a matching line and resolves nothing, silently, which is the
# exact failure this whole detector exists to end.
_GAIA_CAPCHECK_PATHCMD='(^|[;|&`]|\$\(|[[:space:]]then|[[:space:]]else|[[:space:]]do|[[:space:]]elif|[[:space:]]!)[[:space:]]*'

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
    # An operand that is neither quoted nor carries a directory separator is
    # not a redirect target. The `>` a matcher finds on such an operand is
    # overwhelmingly a comparison inside an embedded jq or awk program
    # (`($n - $epoch) > $ttl`, `$x.timestamp > .tmax`) that a multi-line
    # single-quoted span hid from _gaia_capcheck_strip_literals, which works one
    # logical line at a time. This widens the bare-word miss already documented
    # in _gaia_capcheck_emit_write: the accepted loss is a real redirect written
    # unquoted into the current directory (`cmd > out.txt`), and no write in
    # either obligated closure is spelled that way.
    case "$tgt" in
      \"*|\'*|*/*) ;;
      *) continue ;;
    esac
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
  local pat="(${_GAIA_CAPCHECK_CMD}(bash|sh|source)|${_GAIA_CAPCHECK_DOTCMD}\\.)[[:space:]]+"
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
      # A backtick or a backslash in the operand says this is prose or a
      # substitution, not a path: a usage block telling a reader to run
      # `bash .gaia/scripts/x.sh` carries the closing backtick into the operand,
      # and no path in this tree holds either character.
      *'`'*|*\\*) continue ;;
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

# _gaia_capcheck_scan_bare_invocations <repo_root> <rel> <sc> <text> <loc>:
# the same `CALL`/`UNRESC` records for a script executed by its OWN path with
# no interpreter word in front of it -- `BASE_REF="$(.github/audit/x.sh)"`.
#
# `_gaia_capcheck_scan_invocations` above reads a call only behind `bash`,
# `sh`, `source`, or a bare `.`, so this shape was not an unresolved call, it
# was not a call at all: the target and its whole subtree stayed outside the
# closure with nothing on any UNRESOLVED line to say so. Silence is the reason
# this is a separate scanner and not a widened alternation over there -- the
# anchor a bare path needs is not the anchor an interpreter word needs.
#
# Two things narrow it, and each one draws the line somewhere a reader can
# check:
#
#   The ANCHOR is _GAIA_CAPCHECK_PATHCMD, strict command position. Any token
#   behind plain whitespace would read `[ -f .claude/hooks/lib/x.sh ]` and
#   `--base .gaia/scripts/y.sh` as calls, and both are operands.
#
#   The TOKEN has to carry a directory separator and end in `.sh`, with an
#   optional closing quote so `"$dir"/x.sh` is the same site as `$dir/x.sh`;
#   the resolver unquotes what it is handed. A bare
#   `foo.sh` with no directory is a PATH lookup, not a file in this tree, and
#   an extensionless executable (`.gaia/cli/gaia`) is deliberately missed:
#   admitting every command-position token that happens to name an on-disk
#   file makes every `git`, `jq`, and `gh` a resolution attempt.
#
# A token that clears both and still does not resolve prints `UNRESC`, exactly
# as the interpreter-prefixed form does, so a shape this scanner ACCEPTS can
# never fail quietly. A shape the anchor rejects is a different matter and is
# still silent, which is why _GAIA_CAPCHECK_PATHCMD enumerates its misses in
# full rather than naming the two that came to mind.
#
# The trailing group is the token's own boundary and it carries the separators,
# not whitespace alone. A `.sh` followed immediately by `)`, `;`, `|`, `&`, or a
# backtick is an execution whose operand list simply ended, and requiring a
# space after it dropped `$(<path>)` called with no arguments while detecting
# the same call the moment it grew one flag: precisely the quiet miss above,
# reintroduced one token further along.
_gaia_capcheck_scan_bare_invocations() {
  local repo_root="$1" rel="$2" sc="$3" text="$4" loc="$5"
  local rest="$text" tok hops=0
  local pat="${_GAIA_CAPCHECK_PATHCMD}([A-Za-z0-9_.\$@{}~+/\"-]*/[A-Za-z0-9_.\$@{}~+/\"-]*\\.sh\"?)([[:space:]);|&\`]|\$)"
  while [ "$hops" -lt 4 ] && [[ $rest =~ $pat ]]; do
    hops=$((hops + 1))
    # Group 2, because _GAIA_CAPCHECK_PATHCMD is flattened to exactly one
    # group; that flattening is what this index depends on.
    tok="${BASH_REMATCH[2]}"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
    [ -n "$tok" ] || continue
    if _gaia_capcheck_resolve_invocation "$repo_root" "$rel" "$sc" "$tok"; then
      printf 'CALL\t%s\t%s\n' "$_GAIA_CAPCHECK_RET" "$loc"
    else
      printf 'UNRESC\t%s\t%s\n' "$loc" "$tok"
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
    _gaia_capcheck_strip_quoted_code "$_GAIA_CAPCHECK_RET"
    stripped="$_GAIA_CAPCHECK_RET"
    _gaia_capcheck_detect_network "$stripped" && printf 'TERM\tnetwork\t%s\n' "$loc"
    _gaia_capcheck_detect_github_write "$stripped" && printf 'TERM\tgithub-write\t%s\n' "$loc"
    _gaia_capcheck_detect_git_write "$stripped" && printf 'TERM\tgit-write\t%s\n' "$loc"
    _gaia_capcheck_detect_tmp "$stripped" && printf 'TERM\ttmp\t%s\n' "$loc"
    _gaia_capcheck_scan_writes "$repo_root" "$rel" "$stripped" "$loc"
    _gaia_capcheck_scan_invocations "$repo_root" "$rel" "$sc" "$stripped" "$loc"
    _gaia_capcheck_scan_bare_invocations "$repo_root" "$rel" "$sc" "$stripped" "$loc"
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
