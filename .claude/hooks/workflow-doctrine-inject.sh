#!/usr/bin/env bash
# SessionStart and PostToolUse hook: injects the execution doctrine
# (.claude/doctrine/execution.md) into the session's context, verbatim through
# hookSpecificOutput.additionalContext, exactly when the session works on a
# branch. It injects when the session's tree is a linked worktree, or the main
# checkout on a branch other than the default; a session that stays on the
# default branch in the main checkout never receives it.
#
# Triggers: SessionStart (startup, resume, clear, compact), PostToolUse
# EnterWorktree, and PostToolUse Bash when the command arms the checkout/switch
# fragment below. The arm only decides whether to look; the decision is always
# the tree's HEAD after the command ran. Branch detection and keys reuse the
# usage ledger's primitives (usage-lib.sh, branch-name-lib.sh, main-root-lib.sh);
# this hook adds no second branch rule.
#
# Cost order, because it runs on every Bash call: CI and jq gates, one payload
# parse, the arming check before any git process, then one git call. Branch,
# worktree kind, and origin/HEAD are read from the git directory's files after
# that call, falling back to git where the layout is not the plain files
# format. The marker's main root, the doctrine, and the libraries are only
# touched on paths that inject or that must clear a marker. The inject path
# spends no second jq: the output is encoded in bash when the text is plain
# printable ASCII, and only other text goes through jq.
#
# Output: nothing, or exactly one JSON value on stdout whose hookEventName
# echoes the input event. The key line (a branch key or a session key, with the
# command that links or binds research to it) precedes the doctrine and is
# omitted, never rewritten, when the key fails the ledger's ref grammar or is a
# hashed off-grammar branch. On EnterWorktree onto the harness's worktree
# spelling, a line naming the rename to the canonical branch precedes the key
# line. Nothing is written to stderr and every path exits
# 0: any failure means no injection.
#
# Dedupe: a per-session marker under <main root>/.gaia/local/cache holds the
# last injected key. startup and PostToolUse skip when it matches; clear,
# compact, and resume always inject, because a resumed session may not hold
# context injected earlier. A no-injection decision on those three events
# removes the marker, so a stale one cannot suppress the next real injection.
# The marker lives under the main root only; nothing is created in the tree
# the session entered.
#
# A doctrine file that is missing or over the byte cap is skipped silently,
# never truncated.
#
# Without jq only SessionStart injects: the event and session id are read from
# the flat payload with sed, the tree is the process cwd, the JSON is built with
# awk, and no marker is read or written. PostToolUse exits silently.
#
# The tree is the session's own (payload cwd, or the EnterWorktree
# worktreePath), never the path a `git -C <path>` command aims at, so a
# command that changes another tree's branch is not seen.

set -uo pipefail
trap 'exit 0' ERR

# Byte-wise string lengths, and no locale cost in the hot path. Not exported.
LC_ALL=C

[ -n "${GITHUB_ACTIONS:-}" ] && exit 0

here="${BASH_SOURCE[0]}"
case "$here" in */*) here="${here%/*}" ;; *) here=. ;; esac
doctrine_document="$here/../doctrine/execution.md"
scripts="$here/../../.gaia/scripts"
maximum_bytes=3584

payload=$(cat)

event="" session_id="" source="" tool="" worktree_path="" cwd="" tool_command=""
have_jq=0
if command -v jq >/dev/null 2>&1; then
  have_jq=1
  fields=$(jq -r '
    def s(f): (try (f | strings) catch null) // "";
    [ s(.hook_event_name), s(.session_id), s(.source), s(.tool_name),
      s(.tool_response.worktreePath), s(.cwd), s(.tool_input.command) ]
    | join("\u001f")' <<<"$payload") || exit 0
  IFS=$'\037' read -r -d '' event session_id source tool worktree_path cwd tool_command <<<"$fields" || true
else
  event=$(printf '%s\n' "$payload" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | sed -n 1p)
  [ "$event" = SessionStart ] || exit 0
  session_id=$(printf '%s\n' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | sed -n 1p)
  source=$(printf '%s\n' "$payload" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | sed -n 1p)
fi

case "$event" in
  SessionStart) ;;
  PostToolUse)
    case "$tool" in
      EnterWorktree) ;;
      Bash)
        _verb_arming_library="$here/lib/verb-arming.sh"
        # shellcheck source=/dev/null
        [ -f "$_verb_arming_library" ] && . "$_verb_arming_library" 2>/dev/null
        type gaia_verb_armed >/dev/null 2>&1 || exit 0
        verb_pattern='(git([[:space:]]+-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+))?[[:space:]]+(checkout|switch)|gh[[:space:]]+pr[[:space:]]+checkout)([[:space:]]|$)'
        if gaia_verb_armed "$verb_pattern" 'git checkout;git switch;git -C * checkout;git -C * switch;gh pr checkout' "$tool_command"; then
          :
        else
          exit 0
        fi
        ;;
      *) exit 0 ;;
    esac
    ;;
  *) exit 0 ;;
esac

# Which tree the session is in.
tree=""
if [ "$event" = PostToolUse ] && [ "$tool" = EnterWorktree ]; then tree="$worktree_path"; fi
[ -n "$tree" ] || tree="$cwd"
[ -n "$tree" ] || tree="$PWD"
case "$tree" in
  /*) ;;
  *) exit 0 ;;
esac
[ -d "$tree" ] || exit 0

# Repository state is read from git's on-disk layout after one git call, which
# costs a third of the git processes the plumbing commands would. A reftable
# repository or any HEAD this reader does not recognize falls back to git.
git_directory=$(git -C "$tree" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
[ -n "$git_directory" ] || exit 0

# A linked worktree's git dir carries a commondir file; the main checkout's
# does not.
linked=0
common="$git_directory"
if [ -f "$git_directory/commondir" ]; then
  linked=1
  commondir_content=""
  IFS= read -r commondir_content <"$git_directory/commondir" || true
  case "$commondir_content" in
    "") exit 0 ;;
    /*) common="$commondir_content" ;;
    *) common="$git_directory/$commondir_content" ;;
  esac
fi

# Current branch; empty when detached.
raw=""
head_ok=0
if [ ! -d "$common/reftable" ]; then
  headline=""
  IFS= read -r headline <"$git_directory/HEAD" || true
  case "$headline" in
    "ref: refs/heads/.invalid") ;;
    "ref: refs/heads/"?*) raw="${headline#ref: refs/heads/}"; head_ok=1 ;;
    "ref: "*) ;;
    *[!0-9a-f]* | "") ;;
    *) head_ok=1 ;;
  esac
fi
if [ "$head_ok" = 0 ]; then
  # symbolic-ref exits 1 on a detached HEAD and 128 outside a repository.
  exit_status=0
  raw=$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null) || exit_status=$?
  case "$exit_status" in
    0) ;;
    1) raw="" ;;
    *) exit 0 ;;
  esac
fi

# Marker work is possible only with jq and a valid session id.
use_marker=0
if [ "$have_jq" = 1 ] && [[ "$session_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then use_marker=1; fi
refresh=0
if [ "$event" = SessionStart ]; then
  case "$source" in clear | compact | resume) refresh=1 ;; esac
fi

# Names that survive normalization unchanged skip the library.
normalized_branch_name=""
if [ -n "$raw" ]; then
  case "$raw" in
    worktree-* | *+*)
      # shellcheck source=/dev/null
      . "$scripts/branch-name-lib.sh" 2>/dev/null || exit 0
      type gaia_branch_normalize >/dev/null 2>&1 || exit 0
      normalized_branch_name=$(gaia_branch_normalize "$raw")
      ;;
    *) normalized_branch_name="$raw" ;;
  esac
fi

# The default branch, by the ledger's own rules: origin/HEAD's target, else
# main, else master, else main. Rules one and two are file reads (a loose main
# ref); the ledger's function answers anything they leave open, such as a
# packed main or a master default.
default=""
if [ -n "$normalized_branch_name" ] && [ "$normalized_branch_name" != HEAD ]; then
  default_branch_reference=""
  if [ -d "$common/reftable" ]; then
    default_branch_reference=$(git -C "$tree" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || default_branch_reference=""
  else
    if [ -f "$common/refs/remotes/origin/HEAD" ]; then
      IFS= read -r default_branch_reference <"$common/refs/remotes/origin/HEAD" || default_branch_reference=""
    fi
    case "$default_branch_reference" in "ref: "*) default_branch_reference="${default_branch_reference#ref: }" ;; *) default_branch_reference="" ;; esac
  fi
  default_branch_reference="${default_branch_reference#refs/remotes/origin/}"
  if [ -n "$default_branch_reference" ]; then
    default="$default_branch_reference"
  elif [ "$normalized_branch_name" = main ]; then
    default=main
  elif [ ! -d "$common/reftable" ] && { [ -f "$common/refs/heads/main" ] || [ -f "$common/refs/remotes/origin/main" ]; }; then
    default=main
  else
    # shellcheck source=/dev/null
    . "$scripts/usage-lib.sh" 2>/dev/null || exit 0
    type gaia_usage_default_branch >/dev/null 2>&1 || exit 0
    default=$(gaia_usage_default_branch "$tree")
  fi
fi

# A linked worktree injects whatever its branch.
inject="$linked"
if [ -n "$normalized_branch_name" ] && [ "$normalized_branch_name" != HEAD ] && [ "$normalized_branch_name" != "$default" ]; then inject=1; fi

# The main checkout's root, which anchors the marker. A standard layout (git
# dir named .git) reads straight off the common directory; any other layout
# goes through the shared resolver.
marker=""
main_root=""
resolve_marker() {
  local resolved_common_directory="$common"
  if [ "$linked" = 1 ]; then resolved_common_directory=$(cd "$common" 2>/dev/null && pwd -P) || resolved_common_directory=""; fi
  case "$resolved_common_directory" in
    /?*/.git) main_root="${resolved_common_directory%/.git}" ;;
    *)
      type gaia_resolve_main_root >/dev/null 2>&1 || {
        # shellcheck source=/dev/null
        . "$scripts/main-root-lib.sh" 2>/dev/null || return 1
      }
      main_root=$(gaia_resolve_main_root "$tree" 2>/dev/null) || return 1
      ;;
  esac
  [ -n "$main_root" ] || return 1
  marker="$main_root/.gaia/local/cache/doctrine-injected.$session_id"
}

if [ "$inject" = 0 ]; then
  if [ "$refresh" = 1 ] && [ "$use_marker" = 1 ] && resolve_marker; then
    rm -f "$marker" 2>/dev/null
  fi
  exit 0
fi

# Doctrine file: present, readable, and within the byte cap. At most one byte
# past the cap is read, so an oversize file costs the same as a full one.
[ -f "$doctrine_document" ] && [ -r "$doctrine_document" ] || exit 0
content=""
IFS= read -r -d '' -n $((maximum_bytes + 1)) content <"$doctrine_document" || true
[ "${#content}" -le "$maximum_bytes" ] || exit 0

# Key, mirroring the ledger's key derivation: detached, an agent worktree
# branch, and the default branch are session spend.
type gaia_usage_valid_reference >/dev/null 2>&1 || {
  # shellcheck source=/dev/null
  . "$scripts/usage-lib.sh" 2>/dev/null || exit 0
}
type gaia_usage_valid_reference >/dev/null 2>&1 || exit 0
case "$raw" in
  "" | worktree-agent-*) key="session:$session_id" ;;
  *)
    if [ -z "$normalized_branch_name" ] || [ "$normalized_branch_name" = HEAD ] || [ "$normalized_branch_name" = "$default" ]; then
      key="session:$session_id"
    else
      key=$(gaia_usage_branch_key "$normalized_branch_name") || exit 0
    fi
    ;;
esac

# EnterWorktree({name}) lands on the harness's `worktree-<name>` spelling, and
# GAIA's rename to the canonical name lives only in the isolation reference a
# skill reads. A session that called EnterWorktree on its own would push the
# spelling, fail the head-branch conventions check, and need a new pull
# request, since GitHub cannot rename a pull request's head. Naming the rename
# here covers that path; the hook does not run it, because only the main thread
# changes git state. Agent worktrees are the harness's own and keep their name.
rename_line=""
if [ "$tool" = EnterWorktree ]; then
  case "$raw" in
    worktree-agent-* | *[!A-Za-z0-9._/+-]*) ;;
    worktree-?*) rename_line="This branch is the worktree spelling the harness assigns; rename it to its canonical name before the first push: git -C \"$tree\" branch -m $raw $normalized_branch_name" ;;
  esac
fi

if [ "$use_marker" = 1 ]; then
  resolve_marker || exit 0
  # A pending rename is not deduped: re-entering an unrenamed worktree repeats it.
  if [ "$refresh" = 0 ] && [ -z "$rename_line" ] && [ -f "$marker" ]; then
    last=""
    IFS= read -r last <"$marker" || true
    [ "$last" = "$key" ] && exit 0
  fi
fi

# The command word is a variable so the key lines read as text, not as a
# cwd-relative interpreter call, to the cwd-relative-load lint.
run=bash
keyline=""
if gaia_usage_valid_reference "$key"; then
  case "$key" in
    branch:%*) ;;
    branch:*) keyline="Branch key: $key. Link its initiative once with: $run .gaia/scripts/usage.sh link $key research:<topic>-<date> (or issue:<n>)" ;;
    session:*) keyline="Session key: $key. Bind research with: $run .gaia/scripts/usage.sh declare research:<topic>-<date> --session $session_id" ;;
  esac
fi
if [ -n "$rename_line" ]; then
  if [ -n "$keyline" ]; then keyline="$rename_line"$'\n'"$keyline"; else keyline="$rename_line"; fi
fi

if [ "$have_jq" = 1 ]; then
  # The doctrine already sits in $content. Plain printable ASCII is encoded in
  # bash, in the pretty-printed shape jq emits; anything else (a control byte,
  # a non-ASCII byte) goes through jq so the encoding stays jq's.
  text="$content"
  [ -z "$keyline" ] || text="$keyline"$'\n'"$content"
  text=${text//\\/\\\\}
  text=${text//\"/\\\"}
  text=${text//$'\n'/\\n}
  text=${text//$'\t'/\\t}
  text=${text//$'\r'/\\r}
  case "$text" in
    *[![:print:]]*)
      hook_output=$(jq -n --arg event_name "$event" --arg keyline "$keyline" --rawfile doctrine "$doctrine_document" \
        '{hookSpecificOutput:{hookEventName:$event_name, additionalContext:(if $keyline == "" then $doctrine else $keyline + "\n" + $doctrine end)}}') || exit 0
      ;;
    *)
      hook_output='{
  "hookSpecificOutput": {
    "hookEventName": "'"$event"'",
    "additionalContext": "'"$text"'"
  }
}'
      ;;
  esac
  [ -n "$hook_output" ] || exit 0
  printf '%s\n' "$hook_output"
else
  body=$({ [ -z "$keyline" ] || printf '%s\n' "$keyline"; cat "$doctrine_document"; } | awk '
    function esc(text,   i, character, escaped_text) {
      escaped_text = ""
      for (i = 1; i <= length(text); i++) {
        character = substr(text, i, 1)
        if (character == "\\") escaped_text = escaped_text "\\\\"
        else if (character == "\"") escaped_text = escaped_text "\\\""
        else if (character == "\t") escaped_text = escaped_text "\\t"
        else if (character == "\r") escaped_text = escaped_text "\\r"
        else escaped_text = escaped_text character
      }
      return escaped_text
    }
    { printf "%s\\n", esc($0) }') || exit 0
  [ -n "$body" ] || exit 0
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$body"
fi

# The marker is written only after the output went out; a failure here costs a
# repeat injection, never a lost one.
if [ "$use_marker" = 1 ]; then
  cache="${marker%/*}"
  if [ -d "$cache" ] || mkdir -p "$cache" 2>/dev/null; then
    temporary_marker_file="$cache/.doctrine-injected.$session_id.$$"
    if printf '%s\n' "$key" >"$temporary_marker_file" 2>/dev/null; then
      mv -f "$temporary_marker_file" "$marker" 2>/dev/null || rm -f "$temporary_marker_file" 2>/dev/null
    else
      rm -f "$temporary_marker_file" 2>/dev/null
    fi
  fi
fi
exit 0
