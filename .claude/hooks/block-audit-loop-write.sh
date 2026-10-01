#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit + Bash/Monitor hook: deny Claude any write,
# edit, move or delete of the audit loop state directory
# (<main>/.gaia/local/audit-loop/).
#
# WHY. That directory holds each branch's audit history and its human-granted
# allowance. Only audit-loop-bound.sh may write history and only
# audit-loop-grant.sh may write allowance; if Claude could write the files
# through its own tools it could forge an allowance or reset the history. This
# guard closes the tool path. The two writer hooks run as hooks, never as tool
# calls, so they are not subject to it.
#
# WHAT IS COVERED.
#   Edit / Write / MultiEdit: .tool_input.file_path is resolved physically (the
#     deepest existing ancestor through `pwd -P`, `..` collapsed, the rest
#     re-appended), so a linked worktree's `.gaia/local` symlink to the main
#     checkout resolves to the real directory. Denied when the result lies
#     inside <main>/.gaia/local/audit-loop/ (<main> from gaia_resolve_main_root
#     of the payload cwd), or when the literal path contains
#     `/.gaia/local/audit-loop/` or ends in `/.gaia/local/audit-loop` (catches a
#     worktree spelling whose symlink target cannot be resolved).
#   Bash / Monitor: .tool_input.command. Cheap pre-filter first: allowed unless
#     the command contains `audit-loop/` or a token ending in
#     `.gaia/local/audit-loop`. A command that names the directory is denied
#     when it also carries a write, move or delete spelling: a `>` or `>>`
#     redirect (a redirect to /dev/null or a descriptor duplication such as
#     2>&1 is not one), rm, mv, cp, tee, ln, install, dd, touch, truncate,
#     chmod, rsync, unlink, shred, `sed -i`, `perl -i`, or python/node/perl/ruby
#     given -c or -e. Read-only commands naming the path (cat, jq, ls) are
#     allowed. The scripts audit-loop-eval.sh and audit-loop-record.sh and the
#     audit-loop hooks contain `audit-loop-` but never `audit-loop/`, so running
#     them is not denied. A `cp` or `mv` that only READS the directory is denied
#     too: the verb is armed, the direction is not parsed, and the over-deny is
#     the safe side.
#
# WHAT IS NOT COVERED (exotic spellings, outside the guarantee; see
# .claude/rules/maintainers/harness-triage-threshold.md): a `cd` into the
# directory followed by relative names; `eval` or `bash -c` wrappers that build
# the path at run time; glob spellings such as `.gaia/local/audit-*`; paths
# built from variables or command substitutions; a verb joined to the path by
# quoting tricks; a symlink alias to the directory whose own path never says
# `audit-loop` (the payload then carries no such literal, and only a denied
# `ln` could have made it).
#
# THE PARENT. Deleting the parent `.gaia/local` (which would take the state with
# it) is block-rm-rf.sh's remit, not this guard's, and is not widened here.
#
# Fail mode: a missing jq refuses only a call whose tool_input mentions
# `audit-loop` (exit 2, via lib/jq-availability.sh), so installing jq stays
# allowed. A deny is JSON on stdout with exit 0.
#
# Bash 3.2 compatible.
set -euo pipefail

payload=$(cat)

# Raw pre-filter. Every call this guard can bind carries the literal
# `audit-loop` in its payload (JSON never escapes those characters), so a
# payload without it is outside the remit with no jq read at all. This is the
# path every ordinary Bash call takes.
case "$payload" in
  *audit-loop*) ;;
  *) exit 0 ;;
esac

_jq_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_lib_dir=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_lib_dir" ] && [ -f "$_jq_lib_dir/jq-availability.sh" ] && . "$_jq_lib_dir/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the audit loop state guard' "$payload" tool_input 'audit-loop'

tool_name=$(jq -r '.tool_name // empty' <<<"$payload")

DENY_MSG="BLOCKED: the audit loop state (<main>/.gaia/local/audit-loop/) is written only by the audit loop hooks. Claude never writes, edits, moves or deletes it. A human extends a checkpoint by typing a whole prompt that is exactly the grant or accept line (see wiki/concepts/PR Merge Workflow.md, #### The branch checkpoint). A corrupt state file is repaired by a human from a terminal outside Claude Code."

deny() {
  jq -n --arg r "$DENY_MSG" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# physical_path <path> <base-dir>: print the physically resolved absolute path.
# Walks the segments; while each prefix exists as a directory it is entered with
# `pwd -P` (symlinks and `..` resolved by the filesystem), and once a segment is
# missing the rest is joined lexically with `..` collapsed.
physical_path() {
  local p="$1" base="$2" cur seg lexical=0 rest hops=0 target
  case "$p" in
    /*) ;;
    *) p="$base/$p" ;;
  esac
  cur=/
  rest="${p#/}"
  while [ -n "$rest" ]; do
    case "$rest" in
      */*)
        seg="${rest%%/*}"
        rest="${rest#*/}"
        ;;
      *)
        seg="$rest"
        rest=''
        ;;
    esac
    case "$seg" in
      '' | .) continue ;;
      ..)
        if [ "$lexical" -eq 1 ]; then
          cur="${cur%/*}"
          [ -n "$cur" ] || cur=/
        else
          cur=$( (cd "${cur%/}/.." 2>/dev/null && pwd -P) ) || cur=/
        fi
        continue
        ;;
    esac
    if [ "$lexical" -eq 0 ] && [ -d "${cur%/}/$seg" ]; then
      cur=$( (cd "${cur%/}/$seg" 2>/dev/null && pwd -P) ) || { lexical=1; cur="${cur%/}/$seg"; }
    else
      # A final component that is itself a symlink (a file link into the
      # directory): follow it, a bounded number of hops.
      if [ "$lexical" -eq 0 ] && [ -z "$rest" ] && [ -L "${cur%/}/$seg" ] && [ "$hops" -lt 8 ]; then
        hops=$((hops + 1))
        target=$(readlink "${cur%/}/$seg" 2>/dev/null) || target=''
        if [ -n "$target" ]; then
          physical_path "$target" "$cur"
          return 0
        fi
      fi
      lexical=1
      cur="${cur%/}/$seg"
    fi
  done
  printf '%s' "$cur"
}

case "$tool_name" in
  Edit | Write | MultiEdit)
    file_path=$(jq -r '.tool_input.file_path // empty' <<<"$payload")
    [[ -n "$file_path" ]] || exit 0

    # Literal spelling first: it needs no resolution and survives a symlink
    # target that cannot be resolved.
    case "$file_path" in
      */.gaia/local/audit-loop/* | */.gaia/local/audit-loop) deny ;;
    esac

    cwd=$(jq -r '.cwd // empty' <<<"$payload")
    [[ -n "$cwd" ]] || cwd=$(pwd -P)
    resolved=$(physical_path "$file_path" "$cwd")

    main_root=''
    _main_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.gaia/scripts/main-root-lib.sh"
    if [ -f "$_main_lib" ]; then
      set +e
      # shellcheck source=../../.gaia/scripts/main-root-lib.sh
      . "$_main_lib" 2>/dev/null
      main_root=$(gaia_resolve_main_root "$cwd" 2>/dev/null)
      set -e
    fi
    if [ -n "$main_root" ]; then
      guarded="$main_root/.gaia/local/audit-loop"
      case "$resolved" in
        "$guarded" | "$guarded"/*) deny ;;
      esac
    fi
    # Resolved spelling that still names the directory (a symlinked checkout
    # whose main root could not be resolved).
    case "$resolved" in
      */.gaia/local/audit-loop/* | */.gaia/local/audit-loop) deny ;;
    esac
    exit 0
    ;;

  Bash | Monitor)
    cmd=$(jq -r '.tool_input.command // empty' <<<"$payload")
    [[ -n "$cmd" ]] || exit 0

    # Pre-filter: does the command name the directory at all?
    names_re='\.gaia/local/audit-loop([[:space:]"'\'';|&)<>]|$)'
    case "$cmd" in
      *audit-loop/*) ;;
      *)
        [[ "$cmd" =~ $names_re ]] || exit 0
        ;;
    esac

    # Drop redirects that cannot write the directory: descriptor duplication
    # (2>&1, >&2) and a redirect to /dev/null.
    scrub="$cmd"
    scrub=$(sed -E 's/[0-9]*>&[0-9-]+//g; s/[0-9&]*>>?[[:space:]]*\/dev\/null//g' <<<"$scrub")

    # A redirect to anything else.
    case "$scrub" in
      *'>'*) deny ;;
    esac

    verbs_re='(^|[[:space:];&|(`/])(rm|mv|cp|tee|ln|install|dd|touch|truncate|chmod|rsync|unlink|shred)([[:space:]]|$)'
    [[ "$scrub" =~ $verbs_re ]] && deny

    sedi_re='(^|[[:space:];&|(`/])(sed|perl)[[:space:]]+(-[a-zA-Z]*i|--in-place)'
    [[ "$scrub" =~ $sedi_re ]] && deny

    interp_re='(^|[[:space:];&|(`/])(python[0-9.]*|node|perl|ruby)[[:space:]]+-[a-zA-Z]*[ce]'
    [[ "$scrub" =~ $interp_re ]] && deny

    exit 0
    ;;

  *)
    exit 0
    ;;
esac
