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
# hashed off-grammar branch. Nothing is written to stderr and every path exits
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
doc="$here/../doctrine/execution.md"
scripts="$here/../../.gaia/scripts"
max_bytes=3584

payload=$(cat)

event="" sid="" source="" tool="" wt="" cwd="" cmd=""
have_jq=0
if command -v jq >/dev/null 2>&1; then
  have_jq=1
  fields=$(jq -r '
    def s(f): (try (f | strings) catch null) // "";
    [ s(.hook_event_name), s(.session_id), s(.source), s(.tool_name),
      s(.tool_response.worktreePath), s(.cwd), s(.tool_input.command) ]
    | join("\u001f")' <<<"$payload") || exit 0
  IFS=$'\037' read -r -d '' event sid source tool wt cwd cmd <<<"$fields" || true
else
  event=$(printf '%s\n' "$payload" | sed -n 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | sed -n 1p)
  [ "$event" = SessionStart ] || exit 0
  sid=$(printf '%s\n' "$payload" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([A-Za-z0-9_-]*\)".*/\1/p' | sed -n 1p)
  source=$(printf '%s\n' "$payload" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([A-Za-z]*\)".*/\1/p' | sed -n 1p)
fi

case "$event" in
  SessionStart) ;;
  PostToolUse)
    case "$tool" in
      EnterWorktree) ;;
      Bash)
        _va="$here/lib/verb-arming.sh"
        # shellcheck source=/dev/null
        [ -f "$_va" ] && . "$_va" 2>/dev/null
        type gaia_verb_armed >/dev/null 2>&1 || exit 0
        frag='(git([[:space:]]+-C[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+))?[[:space:]]+(checkout|switch)|gh[[:space:]]+pr[[:space:]]+checkout)([[:space:]]|$)'
        if gaia_verb_armed "$frag" 'git checkout;git switch;git -C * checkout;git -C * switch;gh pr checkout' "$cmd"; then
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
if [ "$event" = PostToolUse ] && [ "$tool" = EnterWorktree ]; then tree="$wt"; fi
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
gd=$(git -C "$tree" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
[ -n "$gd" ] || exit 0

# A linked worktree's git dir carries a commondir file; the main checkout's
# does not.
linked=0
common="$gd"
if [ -f "$gd/commondir" ]; then
  linked=1
  cdir=""
  IFS= read -r cdir <"$gd/commondir" || true
  case "$cdir" in
    "") exit 0 ;;
    /*) common="$cdir" ;;
    *) common="$gd/$cdir" ;;
  esac
fi

# Current branch; empty when detached.
raw=""
head_ok=0
if [ ! -d "$common/reftable" ]; then
  headline=""
  IFS= read -r headline <"$gd/HEAD" || true
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
  rc=0
  raw=$(git -C "$tree" symbolic-ref --quiet --short HEAD 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    1) raw="" ;;
    *) exit 0 ;;
  esac
fi

# Marker work is possible only with jq and a valid session id.
use_marker=0
if [ "$have_jq" = 1 ] && [[ "$sid" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then use_marker=1; fi
refresh=0
if [ "$event" = SessionStart ]; then
  case "$source" in clear | compact | resume) refresh=1 ;; esac
fi

# Names that survive normalization unchanged skip the library.
norm=""
if [ -n "$raw" ]; then
  case "$raw" in
    worktree-* | *+*)
      # shellcheck source=/dev/null
      . "$scripts/branch-name-lib.sh" 2>/dev/null || exit 0
      type gaia_branch_normalize >/dev/null 2>&1 || exit 0
      norm=$(gaia_branch_normalize "$raw")
      ;;
    *) norm="$raw" ;;
  esac
fi

# The default branch, by the ledger's own rules: origin/HEAD's target, else
# main, else master, else main. Rules one and two are file reads (a loose main
# ref); the ledger's function answers anything they leave open, such as a
# packed main or a master default.
default=""
if [ -n "$norm" ] && [ "$norm" != HEAD ]; then
  ref=""
  if [ -d "$common/reftable" ]; then
    ref=$(git -C "$tree" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null) || ref=""
  else
    if [ -f "$common/refs/remotes/origin/HEAD" ]; then
      IFS= read -r ref <"$common/refs/remotes/origin/HEAD" || ref=""
    fi
    case "$ref" in "ref: "*) ref="${ref#ref: }" ;; *) ref="" ;; esac
  fi
  ref="${ref#refs/remotes/origin/}"
  if [ -n "$ref" ]; then
    default="$ref"
  elif [ "$norm" = main ]; then
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
if [ -n "$norm" ] && [ "$norm" != HEAD ] && [ "$norm" != "$default" ]; then inject=1; fi

# The main checkout's root, which anchors the marker. A standard layout (git
# dir named .git) reads straight off the common directory; any other layout
# goes through the shared resolver.
marker=""
main_root=""
resolve_marker() {
  local c="$common"
  if [ "$linked" = 1 ]; then c=$(cd "$common" 2>/dev/null && pwd -P) || c=""; fi
  case "$c" in
    /?*/.git) main_root="${c%/.git}" ;;
    *)
      type gaia_resolve_main_root >/dev/null 2>&1 || {
        # shellcheck source=/dev/null
        . "$scripts/main-root-lib.sh" 2>/dev/null || return 1
      }
      main_root=$(gaia_resolve_main_root "$tree" 2>/dev/null) || return 1
      ;;
  esac
  [ -n "$main_root" ] || return 1
  marker="$main_root/.gaia/local/cache/doctrine-injected.$sid"
}

if [ "$inject" = 0 ]; then
  if [ "$refresh" = 1 ] && [ "$use_marker" = 1 ] && resolve_marker; then
    rm -f "$marker" 2>/dev/null
  fi
  exit 0
fi

# Doctrine file: present, readable, and within the byte cap. At most one byte
# past the cap is read, so an oversize file costs the same as a full one.
[ -f "$doc" ] && [ -r "$doc" ] || exit 0
content=""
IFS= read -r -d '' -n $((max_bytes + 1)) content <"$doc" || true
[ "${#content}" -le "$max_bytes" ] || exit 0

# Key, mirroring the ledger's key derivation: detached, an agent worktree
# branch, and the default branch are session spend.
type gaia_usage_valid_ref >/dev/null 2>&1 || {
  # shellcheck source=/dev/null
  . "$scripts/usage-lib.sh" 2>/dev/null || exit 0
}
type gaia_usage_valid_ref >/dev/null 2>&1 || exit 0
case "$raw" in
  "" | worktree-agent-*) key="session:$sid" ;;
  *)
    if [ -z "$norm" ] || [ "$norm" = HEAD ] || [ "$norm" = "$default" ]; then
      key="session:$sid"
    else
      key=$(gaia_usage_branch_key "$norm") || exit 0
    fi
    ;;
esac

if [ "$use_marker" = 1 ]; then
  resolve_marker || exit 0
  if [ "$refresh" = 0 ] && [ -f "$marker" ]; then
    last=""
    IFS= read -r last <"$marker" || true
    [ "$last" = "$key" ] && exit 0
  fi
fi

# The command word is a variable so the key lines read as text, not as a
# cwd-relative interpreter call, to the cwd-relative-load lint.
run=bash
keyline=""
if gaia_usage_valid_ref "$key"; then
  case "$key" in
    branch:%*) ;;
    branch:*) keyline="Branch key: $key. Link its initiative once with: $run .gaia/scripts/usage.sh link $key research:<topic>-<date> (or issue:<n>)" ;;
    session:*) keyline="Session key: $key. Bind research with: $run .gaia/scripts/usage.sh declare research:<topic>-<date> --session $sid" ;;
  esac
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
      out=$(jq -n --arg e "$event" --arg k "$keyline" --rawfile d "$doc" \
        '{hookSpecificOutput:{hookEventName:$e, additionalContext:(if $k == "" then $d else $k + "\n" + $d end)}}') || exit 0
      ;;
    *)
      out='{
  "hookSpecificOutput": {
    "hookEventName": "'"$event"'",
    "additionalContext": "'"$text"'"
  }
}'
      ;;
  esac
  [ -n "$out" ] || exit 0
  printf '%s\n' "$out"
else
  body=$({ [ -z "$keyline" ] || printf '%s\n' "$keyline"; cat "$doc"; } | awk '
    function esc(s,   i, c, o) {
      o = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") o = o "\\\\"
        else if (c == "\"") o = o "\\\""
        else if (c == "\t") o = o "\\t"
        else if (c == "\r") o = o "\\r"
        else o = o c
      }
      return o
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
    tmp="$cache/.doctrine-injected.$sid.$$"
    if printf '%s\n' "$key" >"$tmp" 2>/dev/null; then
      mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi
fi
exit 0
