# shellcheck shell=bash
#
# Per-branch audit loop state: keying, paths, schema-1 validation, locking,
# atomic writes, input validators and the grant/accept line grammar. The
# verdict formulas, the defaults and the allowance fold live in
# audit-loop-eval.sh's header, not here.
#
# Writers. The state file has three writers: audit-loop-bound.sh writes every
# top-level key except `allowance`; audit-loop-grant.sh (typed grant/accept
# lines) and audit-loop-ask-grant.sh (selections of the pinned AskUserQuestion)
# write only `allowance`. All take gaia_loop_lock, re-read the file under it
# (another writer may have landed while they waited), validate, and write
# through gaia_loop_write_state. Nothing else writes the file, and
# audit-loop-eval.sh's CLI never calls a write function. A typed `audit-accept`
# is a deliberate human override of the accept-eligibility gate that the
# AskUserQuestion accept option carries.
#
# Corrupt means not valid JSON, `schema != 1`, a missing required key, or a
# recorded tree/commit/merge base that is not a hex object id. A corrupt file
# is reported (rc 5) and never rewritten or reset: gaia_loop_write_state
# refuses to replace anything with JSON that fails the same check, so a bad
# writer cannot launder a reset through it.
#
# Sourcing defines functions only and runs no external command, so it is safe
# under `set -u` with PATH empty; gaia_loop_parse_line, gaia_loop_grant_line
# and gaia_loop_accept_line use builtins only, because the grant hook
# classifies every prompt before it may call jq or git. Bash 3.2 compatible.
# Never `cd`s.
#
# Exit statuses shared by the functions below: 1 absent or refused, 4 detached
# HEAD, 5 not keyable or corrupt, 6 a required tool (git, jq) is missing.

_gaia_loop_lib_dir="${BASH_SOURCE[0]%/*}"
[ "$_gaia_loop_lib_dir" = "${BASH_SOURCE[0]}" ] && _gaia_loop_lib_dir="."
# shellcheck source=/dev/null
. "$_gaia_loop_lib_dir/branch-name-lib.sh"
# shellcheck source=/dev/null
. "$_gaia_loop_lib_dir/main-root-lib.sh"
# shellcheck source=/dev/null
. "$_gaia_loop_lib_dir/audit-key-lib.sh"
unset _gaia_loop_lib_dir

# Git with the repository-discovery overrides stripped, so an ambient GIT_DIR
# (a git hook, a `rebase -x` step) cannot point a read at another repository.
_gaia_loop_git() {
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git "$@"
}

# gaia_loop_is_oid <s>: a full sha1 or sha256 object id, lowercase hex.
gaia_loop_is_oid() {
  local LC_ALL=C
  [[ "${1-}" =~ ^[0-9a-f]{40}$ || "${1-}" =~ ^[0-9a-f]{64}$ ]]
}

# gaia_loop_is_uint <s>: a non-negative decimal integer, no leading zero, at
# most nine digits (so shell arithmetic on it can never overflow).
gaia_loop_is_uint() {
  local LC_ALL=C
  [[ "${1-}" =~ ^(0|[1-9][0-9]{0,8})$ ]]
}

# gaia_loop_is_safe_relpath <s>: relative, no leading `-` (never read as an
# option), no `..` segment, no newline. bash strings cannot hold NUL.
gaia_loop_is_safe_relpath() {
  local p="${1-}" nl=$'\n'
  [ -n "$p" ] || return 1
  case "$p" in
    /* | -* | *"$nl"*) return 1 ;;
  esac
  case "/$p/" in
    */../*) return 1 ;;
  esac
  return 0
}

# The normalized-key rule (README C1): what may name a state file. A `..`, an
# empty segment or an edge slash would let a branch name climb out of, or
# alias a sibling inside, the audit-loop directory.
_gaia_loop_keyable() {
  local LC_ALL=C k="${1-}"
  [[ "$k" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || return 1
  case "$k" in
    *..* | *//* | /* | */) return 1 ;;
  esac
  return 0
}

# gaia_loop_key <audited-root>: the normalized branch key B.
gaia_loop_key() {
  local root="${1-}" raw b
  command -v git >/dev/null 2>&1 || return 6
  raw="$(_gaia_loop_git -C "$root" branch --show-current 2>/dev/null)" || return 5
  [ -n "$raw" ] || return 4
  b="$(gaia_branch_normalize "$raw")"
  _gaia_loop_keyable "$b" || return 5
  printf '%s\n' "$b"
}

# gaia_loop_state_file <main-root> <B>: the branch state path (C1).
gaia_loop_state_file() {
  printf '%s/.gaia/local/audit-loop/%s.json\n' "$1" "$2"
}

# gaia_loop_stamp_file <main-root> <B> <r>: the round-r dispatch stamp.
gaia_loop_stamp_file() {
  printf '%s/.gaia/local/audit-loop/%s.d/round-%s.stamp\n' "$1" "$2" "$3"
}

# gaia_loop_run_dir <main-root> <B>: the execution run folder for B.
gaia_loop_run_dir() {
  printf '%s/.gaia/local/runs/%s\n' "$1" "$2"
}

# The schema-1 check, applied to a slurped input so a file holding two JSON
# values is corrupt rather than silently reading as its first one.
# shellcheck disable=SC2016
_GAIA_LOOP_SCHEMA_JQ='
def oid: type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
def int1: type == "number" and . == floor and . >= 1 and . <= 99;
def isint: type == "number" and . == floor;
def opt($k; f): (has($k) | not) or (.[$k] | f);
def hex16: type == "string" and test("^[0-9a-f]{16}$");
def unit_ok:
  type == "object" and (.unit | isint) and .unit >= 1 and (.start_round | isint)
  and (.k | isint) and (.through_round | isint) and (.after_checkpoint | isint)
  and (.admitted_on == "context" or .admitted_on == "grant" or .admitted_on == "accept" or .admitted_on == "fallback");
def config_ok:
  type == "object" and (.ask_tokens | isint) and .ask_tokens >= 1
  and (.ask_window_pct | isint) and .ask_window_pct >= 1 and .ask_window_pct <= 100;
def ok:
  type == "object" and .schema == 1
  and (.key | type == "string") and (.branch | type == "string")
  and has("pr") and (.pr == null or (.pr | type == "number" and . == floor and . >= 0))
  and (.history | type == "object")
  and (.history.rounds | type == "array") and (.history.checkpoints | type == "array")
  and (.allowance | type == "object") and (.allowance.answers | type == "array")
  and ((.history.rounds | length) == 0
       or (.history.knobs | type == "object" and (.checkpoint_round | int1) and (.grant_rounds | int1)))
  and (.history | opt("context_config"; config_ok))
  and (.history | opt("units"; type == "array" and all(.[]; unit_ok)))
  and all(.history.rounds[];
          type == "object" and (.tree | oid) and (.commit | oid)
          and (.members | type == "array")
          and (.snapshot == null
               or (.snapshot | type == "object"
                   and (.merge_base == null or (.merge_base | oid)))))
  and all(.history.checkpoints[];
          type == "object" and (.index | type == "number") and (.at_round | type == "number")
          and opt("nonce"; hex16) and opt("trigger"; type == "string")
          and opt("accept_eligible"; type == "boolean")
          and opt("question"; type == "object" and (.questions | type == "array" and length == 1)))
  and all(.allowance.answers[];
          type == "object" and (.checkpoint | type == "number")
          and (.kind == "accept" or (.kind == "grant" and (.n | type == "number" and . == floor and . >= 1 and . <= 10)))
          and opt("source"; . == "typed" or . == "ask")
          and opt("option"; type == "string") and opt("nonce"; hex16));
if length == 1 and (.[0] | ok) then .[0] else error("corrupt") end
'

# gaia_loop_read_state <file>: prints the state JSON (compact). rc 1 absent,
# rc 5 corrupt (prints nothing), rc 6 jq missing.
gaia_loop_read_state() {
  local f="${1-}" out
  [ -e "$f" ] || return 1
  command -v jq >/dev/null 2>&1 || return 6
  out="$(jq -c -s "$_GAIA_LOOP_SCHEMA_JQ" <"$f" 2>/dev/null)" || return 5
  [ -n "$out" ] || return 5
  printf '%s\n' "$out"
}

# gaia_loop_write_state <file> <json>: validate, then temp file plus `mv`.
# Any failure writes nothing and leaves an existing file byte-identical.
gaia_loop_write_state() {
  local f="${1-}" json="${2-}" out dir tmp
  command -v jq >/dev/null 2>&1 || return 6
  out="$(printf '%s' "$json" | jq -s "$_GAIA_LOOP_SCHEMA_JQ" 2>/dev/null)" || return 5
  [ -n "$out" ] || return 5
  dir="${f%/*}"
  mkdir -p "$dir" || return 1
  tmp="$f.tmp.$$.$RANDOM"
  printf '%s\n' "$out" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# gaia_loop_lock <file> <deadline-epoch>: take `<file>.lock` by `mkdir`
# (atomic on every local filesystem). A lock older than a minute belongs to a
# writer that died: every writer holds it for a few jq calls, far below that,
# so it is broken once. rc 1 when the deadline passes. The caller re-reads the
# state after this returns.
gaia_loop_lock() {
  local f="${1-}" deadline="${2-}" lock broke=0 now
  lock="$f.lock"
  case "$deadline" in '' | *[!0-9]*) return 1 ;; esac
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  while :; do
    mkdir "$lock" 2>/dev/null && return 0
    if [ "$broke" -eq 0 ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null || rm -rf "$lock"
      broke=1
      continue
    fi
    now="$(date +%s)"
    [ "$now" -ge "$deadline" ] && return 1
    sleep 0.1
  done
}

# gaia_loop_unlock <file>: release the lock taken by gaia_loop_lock.
gaia_loop_unlock() {
  rmdir "${1-}.lock" 2>/dev/null || rm -rf "${1-}.lock"
}

# gaia_loop_resolve_audited_root <payload-json>: the audited checkout (C7).
# The dispatch prompt's `Working root: <path>` wins over the payload cwd,
# because an orchestrator may audit a linked worktree from the main checkout
# and the audited checkout, not the session's cwd, owns the branch.
gaia_loop_resolve_audited_root() {
  local payload="${1-}" prompt cwd rest p top
  command -v jq >/dev/null 2>&1 || return 6
  prompt="$(printf '%s' "$payload" | jq -r '.tool_input.prompt // "" | strings' 2>/dev/null)" || prompt=""
  cwd="$(printf '%s' "$payload" | jq -r '.cwd // "" | strings' 2>/dev/null)" || cwd=""
  case "$prompt" in
    *"Working root: "*)
      rest="${prompt#*Working root: }"
      p="${rest%%[,[:space:]]*}"
      case "$p" in
        /*)
          if top="$(gaia_resolve_tree_root "$p")" && [ -n "$top" ]; then
            printf '%s\n' "$top"
            return 0
          fi
          ;;
      esac
      ;;
  esac
  case "$cwd" in
    /*)
      if top="$(gaia_resolve_tree_root "$cwd" 2>/dev/null)" && [ -n "$top" ]; then
        printf '%s\n' "$top"
      else
        printf '%s\n' "$cwd"
      fi
      return 0
      ;;
  esac
  return 1
}

# gaia_loop_grant_line <n>: the one spelling of the grant line (C6).
gaia_loop_grant_line() {
  case "${1-}" in
    [1-9] | 10) printf 'audit-grant %s\n' "$1" ;;
    *) return 2 ;;
  esac
}

# gaia_loop_accept_line: the one spelling of the accept line (C6).
gaia_loop_accept_line() {
  printf 'audit-accept\n'
}

# gaia_loop_parse_line <text>: prints `grant <n>`, `accept`, `malformed` or
# `none`. The whole prompt, trimmed of spaces, tabs, CR and LF, must be the
# line; a line inside longer text mentions the keyword and is `malformed`,
# so pasted text never grants. Builtins only.
gaia_loop_parse_line() {
  local LC_ALL=C t="${1-}" ws=$' \t\r\n' edge
  edge="${t%%[!"$ws"]*}"
  t="${t#"$edge"}"
  edge="${t##*[!"$ws"]}"
  t="${t%"$edge"}"
  case "$t" in
    audit-accept) printf 'accept\n' ;;
    "audit-grant "[1-9] | "audit-grant 10") printf 'grant %s\n' "${t#audit-grant }" ;;
    *audit-grant* | *audit-accept*) printf 'malformed\n' ;;
    *) printf 'none\n' ;;
  esac
}

# _GAIA_LOOP_ASK_RECORDER: 1 when the PostToolUse recorder
# (audit-loop-ask-grant.sh) is built (probe P3 passed), 0 when selecting an
# option records nothing and the human must type the line instead.
_GAIA_LOOP_ASK_RECORDER=1

# gaia_loop_new_nonce: 16 lowercase hex chars from /dev/urandom; rc 6 when it
# cannot produce them.
gaia_loop_new_nonce() {
  local n
  n="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 6
  [[ "$n" =~ ^[0-9a-f]{16}$ ]] || return 6
  printf '%s\n' "$n"
}

# gaia_loop_session_is_interactive <transcript_path>: rc 0 only when
# CLAUDE_CODE_ENTRYPOINT is `cli`, the transcript exists, and every record
# carrying `entrypoint` holds `cli`. Shared by both recorders.
gaia_loop_session_is_interactive() {
  local transcript="${1-}" entry=""
  [ "${CLAUDE_CODE_ENTRYPOINT-}" = cli ] || return 1
  if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    entry="$(jq -r -n '[inputs | select(type == "object" and has("entrypoint")) | .entrypoint] | if length > 0 and all(. == "cli") then "cli" else "other" end' <"$transcript" 2>/dev/null)" || entry=""
  fi
  [ "$entry" = cli ]
}

# gaia_loop_pinned_question <branch> <nonce> <rounds_used> <k>
# <accept_eligible:true|false> <cap:true|false> <trigger>: the whole pinned
# AskUserQuestion tool_input, compact JSON, one question. The only builder of
# these strings (the recorder compares a payload against its output). rc 2 and
# nothing printed on a bad input.
gaia_loop_pinned_question() {
  local branch="${1-}" nonce="${2-}" used="${3-}" k="${4-}" elig="${5-}" cap="${6-}" trigger="${7-}"
  local LC_ALL=C typed_g typed_a
  command -v jq >/dev/null 2>&1 || return 6
  _gaia_loop_keyable "$branch" || return 2
  [[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || return 2
  gaia_loop_is_uint "$used" || return 2
  gaia_loop_is_uint "$k" || return 2
  [ "$k" -ge 1 ] || return 2
  case "$elig" in true | false) ;; *) return 2 ;; esac
  case "$cap" in true | false) ;; *) return 2 ;; esac
  [[ "$trigger" =~ ^(context|cap|fallback|rubric:[A-Za-z0-9_.-]+)$ ]] || return 2
  typed_g=""
  typed_a=""
  if [ "$_GAIA_LOOP_ASK_RECORDER" = 0 ]; then
    typed_g=" Selecting this records nothing; type \`audit-grant $k\` as the whole prompt."
    typed_a=" Selecting this records nothing; type \`audit-accept\` as the whole prompt."
  fi
  jq -n -c --arg branch "$branch" --arg nonce "$nonce" --arg used "$used" --arg k "$k" \
    --arg trigger "$trigger" --argjson elig "$elig" --argjson cap "$cap" \
    --arg tg "$typed_g" --arg ta "$typed_a" '
    ("Grant " + $k + ", continue here") as $g1
    | ("Grant " + $k + ", new session") as $g2
    | [
        (if $cap then empty else
          {label: $g1, description: ("Records " + $k + " more rounds and keeps working in this session." + $tg)},
          {label: $g2, description: ("Records the same " + $k + "-round grant, then prints a continuation prompt for a fresh session." + $tg)}
        end),
        (if $elig then
          {label: "Accept the remainder", description: ("One closing round, then the remainder is recorded as accepted residuals." + $ta)}
        else empty end),
        (if $cap and ($elig | not) then
          {label: "Type audit-accept instead", description: "Records nothing. The human may type `audit-accept` as the whole prompt, a deliberate override of the eligibility gate."}
        else empty end),
        {label: "Stop and file the remainder", description: "Records nothing, leaves the PR open, and files the remainder as tech debt."}
      ] as $opts
    | {questions: [{
        question: ("Audit checkpoint " + $nonce + " on " + $branch + ": " + $used + " rounds used (" + $trigger + "). How should the audit loop continue?"),
        header: "Audit loop",
        multiSelect: false,
        options: $opts}]}'
}

# gaia_loop_pending_checkpoint <state-json>: the pending checkpoint object, or
# nothing. Pending is the LATEST checkpoint when no answer names its index;
# an older unanswered checkpoint behind a newer one is stale, never pending,
# so an answer can only ever reach the checkpoint the loop is stopped at.
gaia_loop_pending_checkpoint() {
  printf '%s' "${1-}" | jq -c '
    (.allowance.answers | map(.checkpoint)) as $a
    | (.history.checkpoints | last) as $c
    | if $c != null and (any($a[]; . == $c.index) | not) then $c else empty end' 2>/dev/null
  return 0
}

# gaia_loop_next_closing <state-json>: `true` when the next recorded round is
# the closing round an accept grants (the latest answer is an accept and the
# round after its checkpoint is not yet recorded), else `false`.
gaia_loop_next_closing() {
  local out
  out="$(printf '%s' "${1-}" | jq -r '
    (.allowance.answers | last) as $a
    | if $a == null or $a.kind != "accept" then false
      else ([.history.checkpoints[] | select(.index == $a.checkpoint)] | .[0].at_round) as $c
      | ($c != null and (.history.rounds | length) <= $c)
      end' 2>/dev/null)" || out=false
  [ "$out" = true ] && printf 'true\n' || printf 'false\n'
}

# _gaia_loop_hunks <git-dir> <a> <b>: one `diff -U0` of a..b, printed as
# `<path>\t<first>\t<last>` per new-side hunk. The prefixes and every option a
# user's config could flip (noprefix, mnemonicPrefix, external diff, relative,
# quotePath) are pinned on the command line. `+++ ` names a path only in a
# file header: with -U0 an added content line `++ x` prints as `+++ x`. A path
# git still quotes (a double quote, backslash or control byte in it) does not
# match any finding's path, so such a path's lines read as not authored; the
# path set from _gaia_loop_names is unaffected. rc 1 when git fails, so the
# caller fails closed rather than reading an empty hunk set as "none".
_gaia_loop_hunks() {
  local out
  gaia_loop_is_oid "${2-}" && gaia_loop_is_oid "${3-}" || return 2
  out="$(_gaia_loop_git -C "$1" -c core.quotePath=false diff -U0 -M --no-color --no-ext-diff \
    --no-relative --src-prefix=a/ --dst-prefix=b/ "$2" "$3" -- 2>/dev/null)" || return 1
  printf '%s\n' "$out" |
    awk '
      /^diff --git / { hdr = 1; cur = ""; next }
      hdr && /^\+\+\+ / {
        p = substr($0, 5); sub(/\t$/, "", p)
        if (p == "/dev/null") cur = ""; else if (substr(p, 1, 2) == "b/") cur = substr(p, 3); else cur = p
        next
      }
      /^@@ / {
        hdr = 0
        if (cur == "") next
        i = index($0, " +"); rest = substr($0, i + 2); j = index(rest, " ")
        spec = substr(rest, 1, j - 1); k = index(spec, ",")
        if (k) { c = substr(spec, 1, k - 1) + 0; d = substr(spec, k + 1) + 0 } else { c = spec + 0; d = 1 }
        if (d > 0) printf "%s\t%d\t%d\n", cur, c, c + d - 1
      }'
}

# _gaia_loop_names <git-dir> <a> <b>: `diff --name-only -M` of a..b, one path
# per line (`-z` so no path is C-quoted).
_gaia_loop_names() {
  gaia_loop_is_oid "${2-}" && gaia_loop_is_oid "${3-}" || return 2
  # A subshell so pipefail carries git's own failure out without changing the
  # caller's shell options.
  (
    set -o pipefail
    _gaia_loop_git -C "$1" diff --name-only -z -M --no-relative "$2" "$3" -- 2>/dev/null | tr '\0' '\n'
  )
}

# _gaia_loop_hunks_json <git-dir> <a> <b>: new-side hunks as JSON, or `null`
# when the diff cannot be read.
_gaia_loop_hunks_json() {
  local out
  out="$(_gaia_loop_hunks "$@")" || { printf 'null\n'; return 0; }
  printf '%s' "$out" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {p: .[0], s: (.[1] | tonumber), e: (.[2] | tonumber)})'
}

# _gaia_loop_merge_base <git-dir> <commit>: merge base with the default branch
# (origin's HEAD target, else origin/main, else local main, else master).
# Full ref names only, so no ref text can be read as an option.
_gaia_loop_merge_base() {
  local dir="$1" commit="$2" ref oid mb
  gaia_loop_is_oid "$commit" || return 1
  for ref in "$(_gaia_loop_git -C "$dir" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" \
    refs/remotes/origin/main refs/heads/main refs/heads/master; do
    case "$ref" in refs/*) ;; *) continue ;; esac
    oid="$(_gaia_loop_git -C "$dir" rev-parse -q --verify "$ref^{commit}" 2>/dev/null)" || continue
    gaia_loop_is_oid "$oid" || continue
    mb="$(_gaia_loop_git -C "$dir" merge-base "$oid" "$commit" 2>/dev/null)" || return 1
    gaia_loop_is_oid "$mb" || return 1
    printf '%s\n' "$mb"
    return 0
  done
  return 1
}

# _gaia_loop_disposed <main-root> <B> <r>: identity keys disposed non-fix in
# any dispositions-<k>.json, k < r. An unreadable file excludes nothing, so a
# lost file counts more findings, never fewer.
_gaia_loop_disposed() {
  local run k out acc="[]"
  run="$(gaia_loop_run_dir "$1" "$2")"
  k=1
  while [ "$k" -lt "$3" ]; do
    if [ -f "$run/dispositions-$k.json" ]; then
      out="$(jq -c '[.entries[] | select(.disposition == "accept-residual" or .disposition == "waive-out-of-scope" or .disposition == "file")
        | [.member, .finding_class, .path, .line]]' <"$run/dispositions-$k.json" 2>/dev/null)" || out=""
      [ -n "$out" ] && acc="$(jq -n -c --argjson a "$acc" --argjson b "$out" '$a + $b')"
    fi
    k=$((k + 1))
  done
  printf '%s\n' "$acc"
}
