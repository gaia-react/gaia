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

_gaia_loop_library_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_loop_library_directory" = "${BASH_SOURCE[0]}" ] && _gaia_loop_library_directory="."
# shellcheck source=/dev/null
. "$_gaia_loop_library_directory/branch-name-lib.sh"
# shellcheck source=/dev/null
. "$_gaia_loop_library_directory/main-root-lib.sh"
# shellcheck source=/dev/null
. "$_gaia_loop_library_directory/audit-key-lib.sh"
unset _gaia_loop_library_directory

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

# gaia_loop_is_safe_relative_path <s>: relative, no leading `-` (never read as an
# option), no `..` segment, no newline. bash strings cannot hold NUL.
gaia_loop_is_safe_relative_path() {
  local relative_path="${1-}" newline=$'\n'
  [ -n "$relative_path" ] || return 1
  case "$relative_path" in
    /* | -* | *"$newline"*) return 1 ;;
  esac
  case "/$relative_path/" in
    */../*) return 1 ;;
  esac
  return 0
}

# The normalized-key rule: what may name a state file. A `..`, an
# empty segment or an edge slash would let a branch name climb out of, or
# alias a sibling inside, the audit-loop directory.
_gaia_loop_keyable() {
  local LC_ALL=C key="${1-}"
  [[ "$key" =~ ^[A-Za-z0-9._/-]{1,128}$ ]] || return 1
  case "$key" in
    *..* | *//* | /* | */) return 1 ;;
  esac
  return 0
}

# gaia_loop_key <audited-root>: the normalized branch key B.
gaia_loop_key() {
  local root="${1-}" raw branch_key
  command -v git >/dev/null 2>&1 || return 6
  raw="$(_gaia_loop_git -C "$root" branch --show-current 2>/dev/null)" || return 5
  [ -n "$raw" ] || return 4
  branch_key="$(gaia_branch_normalize "$raw")"
  _gaia_loop_keyable "$branch_key" || return 5
  printf '%s\n' "$branch_key"
}

# gaia_loop_state_file <main-root> <B>: the branch state path.
gaia_loop_state_file() {
  printf '%s/.gaia/local/protected/audit-loop/%s.json\n' "$1" "$2"
}

# gaia_loop_stamp_file <main-root> <B> <r>: the round-r dispatch stamp.
gaia_loop_stamp_file() {
  printf '%s/.gaia/local/protected/audit-loop/%s.d/round-%s.stamp\n' "$1" "$2" "$3"
}

# gaia_loop_run_directory <main-root> <B>: the execution run folder for B.
gaia_loop_run_directory() {
  printf '%s/.gaia/local/runs/%s\n' "$1" "$2"
}

# The schema-1 check, applied to a slurped input so a file holding two JSON
# values is corrupt rather than silently reading as its first one.
# shellcheck disable=SC2016
_GAIA_LOOP_SCHEMA_JQ='
def oid: type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$");
def knob_integer: type == "number" and . == floor and . >= 1 and . <= 99;
def is_integer: type == "number" and . == floor;
def optional($key; check): (has($key) | not) or (.[$key] | check);
def hex16: type == "string" and test("^[0-9a-f]{16}$");
def unit_ok:
  type == "object" and (.unit | is_integer) and .unit >= 1 and (.start_round | is_integer)
  and (.k | is_integer) and (.through_round | is_integer) and (.after_checkpoint | is_integer)
  and (.admitted_on == "context" or .admitted_on == "grant" or .admitted_on == "accept" or .admitted_on == "fallback");
def config_ok:
  type == "object" and (.ask_tokens | is_integer) and .ask_tokens >= 1
  and (.ask_window_pct | is_integer) and .ask_window_pct >= 1 and .ask_window_pct <= 100;
def ok:
  type == "object" and .schema == 1
  and (.key | type == "string") and (.branch | type == "string")
  and has("pr") and (.pr == null or (.pr | type == "number" and . == floor and . >= 0))
  and (.history | type == "object")
  and (.history.rounds | type == "array") and (.history.checkpoints | type == "array")
  and (.allowance | type == "object") and (.allowance.answers | type == "array")
  and ((.history.rounds | length) == 0
       or (.history.knobs | type == "object" and (.checkpoint_round | knob_integer) and (.grant_rounds | knob_integer)))
  and (.history | optional("context_config"; config_ok))
  and (.history | optional("units"; type == "array" and all(.[]; unit_ok)))
  and all(.history.rounds[];
          type == "object" and (.tree | oid) and (.commit | oid)
          and (.members | type == "array")
          and (.snapshot == null
               or (.snapshot | type == "object"
                   and (.merge_base == null or (.merge_base | oid)))))
  and all(.history.checkpoints[];
          type == "object" and (.index | type == "number") and (.at_round | type == "number")
          and optional("nonce"; hex16) and optional("trigger"; type == "string")
          and optional("accept_eligible"; type == "boolean")
          and optional("question"; type == "object" and (.questions | type == "array" and length == 1)))
  and all(.allowance.answers[];
          type == "object" and (.checkpoint | type == "number")
          and (.kind == "accept" or (.kind == "grant" and (.n | type == "number" and . == floor and . >= 1 and . <= 10)))
          and optional("source"; . == "typed" or . == "ask")
          and optional("option"; type == "string") and optional("nonce"; hex16));
if length == 1 and (.[0] | ok) then .[0] else error("corrupt") end
'

# gaia_loop_read_state <file>: prints the state JSON (compact). rc 1 absent,
# rc 5 corrupt (prints nothing), rc 6 jq missing.
gaia_loop_read_state() {
  local file="${1-}" state_json
  [ -e "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 6
  state_json="$(jq -c -s "$_GAIA_LOOP_SCHEMA_JQ" <"$file" 2>/dev/null)" || return 5
  [ -n "$state_json" ] || return 5
  printf '%s\n' "$state_json"
}

# gaia_loop_write_state <file> <json>: validate, then temp file plus `mv`.
# Any failure writes nothing and leaves an existing file byte-identical.
gaia_loop_write_state() {
  local file="${1-}" json="${2-}" validated_json directory temporary_file
  command -v jq >/dev/null 2>&1 || return 6
  validated_json="$(printf '%s' "$json" | jq -s "$_GAIA_LOOP_SCHEMA_JQ" 2>/dev/null)" || return 5
  [ -n "$validated_json" ] || return 5
  directory="${file%/*}"
  mkdir -p "$directory" || return 1
  temporary_file="$file.tmp.$$.$RANDOM"
  printf '%s\n' "$validated_json" >"$temporary_file" || { rm -f "$temporary_file"; return 1; }
  mv -f "$temporary_file" "$file" || { rm -f "$temporary_file"; return 1; }
}

# gaia_loop_lock <file> <deadline-epoch>: take `<file>.lock` by `mkdir`
# (atomic on every local filesystem). A lock older than a minute belongs to a
# writer that died: every writer holds it for a few jq calls, far below that,
# so it is broken once. rc 1 when the deadline passes. The caller re-reads the
# state after this returns.
gaia_loop_lock() {
  local file="${1-}" deadline="${2-}" lock broke=0 now
  lock="$file.lock"
  case "$deadline" in '' | *[!0-9]*) return 1 ;; esac
  mkdir -p "${file%/*}" 2>/dev/null || return 1
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

# gaia_loop_resolve_audited_root <payload-json>: the audited checkout.
# The dispatch prompt's `Working root: <path>` wins over the payload cwd,
# because an orchestrator may audit a linked worktree from the main checkout
# and the audited checkout, not the session's cwd, owns the branch.
# A prose spelling (`Working root: /abs/path.`, a backticked or quoted path)
# is retried with its wrapping quotes and trailing sentence punctuation
# stripped. A named root that still does not resolve is rc 2 with the token
# on stdout, never a fallback to cwd: the member audits the named checkout,
# so charging the cwd's branch would gate a different tree than the audited one.
gaia_loop_resolve_audited_root() {
  local payload="${1-}" prompt cwd rest candidate_path bare tree_root
  command -v jq >/dev/null 2>&1 || return 6
  prompt="$(printf '%s' "$payload" | jq -r '.tool_input.prompt // "" | strings' 2>/dev/null)" || prompt=""
  cwd="$(printf '%s' "$payload" | jq -r '.cwd // "" | strings' 2>/dev/null)" || cwd=""
  case "$prompt" in
    *"Working root: "*)
      rest="${prompt#*Working root: }"
      candidate_path="${rest%%[,[:space:]]*}"
      bare="$candidate_path"
      while :; do
        case "$bare" in
          [\`\"\'\(]*) bare="${bare#?}" ;;
          *) break ;;
        esac
      done
      while :; do
        case "$bare" in
          ?*[.\;:\)\`\"\']) bare="${bare%?}" ;;
          *) break ;;
        esac
      done
      for candidate_path in "$candidate_path" "$bare"; do
        case "$candidate_path" in
          /*)
            if tree_root="$(gaia_resolve_tree_root "$candidate_path")" && [ -n "$tree_root" ]; then
              printf '%s\n' "$tree_root"
              return 0
            fi
            ;;
        esac
      done
      printf '%s\n' "$bare"
      return 2
      ;;
  esac
  case "$cwd" in
    /*)
      if tree_root="$(gaia_resolve_tree_root "$cwd" 2>/dev/null)" && [ -n "$tree_root" ]; then
        printf '%s\n' "$tree_root"
      else
        printf '%s\n' "$cwd"
      fi
      return 0
      ;;
  esac
  return 1
}

# gaia_loop_grant_line <n>: the one spelling of the grant line.
gaia_loop_grant_line() {
  case "${1-}" in
    [1-9] | 10) printf 'audit-grant %s\n' "$1" ;;
    *) return 2 ;;
  esac
}

# gaia_loop_accept_line: the one spelling of the accept line.
gaia_loop_accept_line() {
  printf 'audit-accept\n'
}

# gaia_loop_parse_line <text>: prints `grant <n>`, `accept`, `malformed` or
# `none`. The whole prompt, trimmed of spaces, tabs, CR and LF, must be the
# line; a line inside longer text mentions the keyword and is `malformed`,
# so pasted text never grants. Builtins only.
gaia_loop_parse_line() {
  local LC_ALL=C text="${1-}" whitespace=$' \t\r\n' edge
  edge="${text%%[!"$whitespace"]*}"
  text="${text#"$edge"}"
  edge="${text##*[!"$whitespace"]}"
  text="${text%"$edge"}"
  case "$text" in
    audit-accept) printf 'accept\n' ;;
    "audit-grant "[1-9] | "audit-grant 10") printf 'grant %s\n' "${text#audit-grant }" ;;
    *audit-grant* | *audit-accept*) printf 'malformed\n' ;;
    *) printf 'none\n' ;;
  esac
}

# _GAIA_LOOP_ASK_RECORDER: 1 when the PostToolUse recorder
# (audit-loop-ask-grant.sh) is built and verified to fire, 0 when selecting an
# option records nothing and the human must type the line instead.
_GAIA_LOOP_ASK_RECORDER=1

# gaia_loop_new_nonce: 16 lowercase hex chars from /dev/urandom; rc 6 when it
# cannot produce them.
gaia_loop_new_nonce() {
  local nonce
  nonce="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 6
  [[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || return 6
  printf '%s\n' "$nonce"
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

# gaia_loop_recommended <trigger> <snapshot-json>: `grant`, `accept` or `stop`, the
# evaluator's recommendation for a checkpoint on <trigger> over the last
# round's snapshot. The brief and the pinned question both read it from here so
# the rule has one copy: a context checkpoint with no denying signal is a grant
# (the session is merely full), otherwise the verdict decides, except that a
# stalled small tail the snapshot calls accept-eligible is an accept.
gaia_loop_recommended() {
  local trigger="${1-}" snapshot="${2:-null}"
  printf '%s' "$snapshot" | jq -r --arg trigger "$trigger" '
    . as $snapshot
    | (if ($snapshot.signals | type) == "object" then $snapshot.signals
       else {enriching: ($snapshot.verdict == "enriching"), stalled: ($snapshot.verdict == "stalled")} end) as $signals
    | (any($signals | to_entries[]; .key != "quiet" and .value == true)) as $denying
    | if $trigger == "context" and ($denying | not) then "grant"
      elif $snapshot.verdict == "stalled" and $signals["small-tail"] == true and $snapshot.accept_eligible == true then "accept"
      else {continue: "grant", unknown: "grant", enriching: "accept", quiet: "accept", stalled: "stop"}
           | .[$snapshot.verdict // "unknown"] // "grant" end'
}

# gaia_loop_pinned_question <branch> <nonce> <rounds_used> <unit_rounds>
# <accept_eligible:true|false> <cap:true|false> <trigger> [<context_reading>
# [<recommended> [<checkpoint_line>]]]: the whole pinned AskUserQuestion
# tool_input, compact JSON, one question. The only builder of these strings (the
# bound hook stores the result, and the recorder compares a payload against that
# stored copy). rc 2 and nothing printed on a bad input. The optional reading is
# a `gaia_context_read` line: the question and each grant option carry it because
# the statusline is hidden while a question shows and never visible over Remote
# Control, and the human reads the choices, not the text above them. A missing,
# stale, future, unparseable or absent reading, or a zero-size window, reads
# "context unavailable".
# Exactly one option leads and ends in " (Recommended)". A `context` trigger
# means the session is at or over the line, so "Continue audit in a new session" always leads and
# "Continue audit in this session" stays offered right after it as the opt-out. For any other
# trigger <recommended> is the gaia_loop_recommended value: accept leads when
# Accept is offered, stop leads on stop. Otherwise, with a grant on the table, a reading below the
# <checkpoint_line> (gaia_context_line) puts "Continue audit in this session" first and a reading at
# or above it, or no usable reading or line, puts "Continue audit in a new session" first. The rest
# keep their order.
gaia_loop_pinned_question() {
  local branch="${1-}" nonce="${2-}" used="${3-}" unit_rounds="${4-}" eligible="${5-}" cap="${6-}" trigger="${7-}" reading="${8-}"
  local recommended="${9-}" line="${10-}"
  local LC_ALL=C typed_grant_note typed_accept_note context_tokens context_window question_context=", context unavailable" option_context="Context unavailable" band=none lead
  command -v jq >/dev/null 2>&1 || return 6
  _gaia_loop_keyable "$branch" || return 2
  [[ "$nonce" =~ ^[0-9a-f]{16}$ ]] || return 2
  gaia_loop_is_uint "$used" || return 2
  gaia_loop_is_uint "$unit_rounds" || return 2
  [ "$unit_rounds" -ge 1 ] || return 2
  case "$eligible" in true | false) ;; *) return 2 ;; esac
  case "$cap" in true | false) ;; *) return 2 ;; esac
  [[ "$trigger" =~ ^(context|cap|fallback|rubric:[A-Za-z0-9_.-]+)$ ]] || return 2
  case "$recommended" in '' | grant | accept | stop) ;; *) return 2 ;; esac
  case "$line" in '') ;; *) gaia_loop_is_uint "$line" || return 2 ;; esac
  case "$reading" in
    '' | missing | stale | future | unparseable) ;;
    *)
      [[ "$reading" =~ ^fresh\ ([0-9]{1,12})\ ([0-9]{1,12})$ ]] || return 2
      context_tokens="${BASH_REMATCH[1]}"
      context_window="${BASH_REMATCH[2]}"
      if [ "$((10#$context_window))" -gt 0 ]; then
        question_context=", context $((10#$context_tokens * 100 / 10#$context_window))% ($((10#$context_tokens / 1000))k of $((10#$context_window / 1000))k)"
        option_context="Context $((10#$context_tokens * 100 / 10#$context_window))% ($((10#$context_tokens / 1000))k of $((10#$context_window / 1000))k)"
        if [ -n "$line" ]; then
          if [ "$((10#$context_tokens))" -lt "$((10#$line))" ]; then band=below; else band=above; fi
        fi
      fi
      ;;
  esac
  if [ "$trigger" = context ] && [ "$cap" = false ]; then
    lead=grant_new_session
  else
    case "$recommended" in
      accept) if [ "$eligible" = true ]; then lead=accept; fi ;;
      stop) lead=stop ;;
    esac
  fi
  if [ -z "${lead-}" ]; then
    if [ "$band" = below ]; then
      lead=grant_here
    else
      lead=grant_new_session
    fi
  fi
  typed_grant_note=""
  typed_accept_note=""
  if [ "$_GAIA_LOOP_ASK_RECORDER" = 0 ]; then
    typed_grant_note=" Selecting this records nothing; type \`audit-grant $unit_rounds\` as the whole prompt."
    typed_accept_note=" Selecting this records nothing; type \`audit-accept\` as the whole prompt."
  fi
  jq -n -c --arg branch "$branch" --arg nonce "$nonce" --arg used "$used" --arg unit_rounds "$unit_rounds" \
    --arg trigger "$trigger" --arg question_context "$question_context" --arg option_context "$option_context" --arg band "$band" --arg lead "$lead" \
    --argjson eligible "$eligible" --argjson cap "$cap" --arg typed_grant_note "$typed_grant_note" --arg typed_accept_note "$typed_accept_note" '
    ({below: " is below the checkpoint line, so this session has room: ",
      above: " is at or above the checkpoint line, so this session is short on room: ",
      none: ", so this session may be short on room: "}[$band]) as $here
    | ({below: " is below the checkpoint line: ",
        above: " is at or above the checkpoint line: ",
        none: ", so a new session is the safe choice: "}[$band]) as $fresh
    | [
        {key: "grant_here", label: "Continue audit in this session", description: ($option_context + $here + "records " + $unit_rounds + " more rounds and keeps working here." + $typed_grant_note)},
        {key: "grant_new_session", label: "Continue audit in a new session", description: ($option_context + $fresh + "records the same " + $unit_rounds + "-round grant, then prints a continuation prompt for a fresh session." + $typed_grant_note)},
        (if $eligible then
          {key: "accept", label: "Accept the remainder", description: ("One closing round, then the remainder is recorded as accepted residuals." + $typed_accept_note)}
        else empty end),
        (if $cap and ($eligible | not) then
          {key: "typed", label: "Type audit-accept instead", description: "Records nothing. The human may type `audit-accept` as the whole prompt, a deliberate override of the eligibility gate."}
        else empty end),
        {key: "stop", label: "Stop and file the remainder", description: "Records nothing, leaves the PR open, and files the remainder as tech debt."}
      ] as $all_options
    | ([$all_options[] | select(.key == $lead) | .label = .label + " (Recommended)"]
       + [$all_options[] | select(.key != $lead)] | map(del(.key))) as $options
    | {questions: [{
        question: ("Audit checkpoint " + $nonce + " on " + $branch + ": " + $used + " rounds used (" + $trigger + ")" + $question_context + ". How should the audit loop continue?"),
        header: "Audit loop",
        multiSelect: false,
        options: $options}]}'
}

# gaia_loop_pending_checkpoint <state-json>: the pending checkpoint object, or
# nothing. Pending is the LATEST checkpoint when no answer names its index;
# an older unanswered checkpoint behind a newer one is stale, never pending,
# so an answer can only ever reach the checkpoint the loop is stopped at.
gaia_loop_pending_checkpoint() {
  printf '%s' "${1-}" | jq -c '
    (.allowance.answers | map(.checkpoint)) as $answered_checkpoints
    | (.history.checkpoints | last) as $latest_checkpoint
    | if $latest_checkpoint != null and (any($answered_checkpoints[]; . == $latest_checkpoint.index) | not) then $latest_checkpoint else empty end' 2>/dev/null
  return 0
}

# gaia_loop_next_closing <state-json>: `true` when the next recorded round is
# the closing round an accept grants (the latest answer is an accept and the
# round after its checkpoint is not yet recorded), else `false`.
gaia_loop_next_closing() {
  local closing
  closing="$(printf '%s' "${1-}" | jq -r '
    (.allowance.answers | last) as $last_answer
    | if $last_answer == null or $last_answer.kind != "accept" then false
      else ([.history.checkpoints[] | select(.index == $last_answer.checkpoint)] | .[0].at_round) as $at_round
      | ($at_round != null and (.history.rounds | length) <= $at_round)
      end' 2>/dev/null)" || closing=false
  [ "$closing" = true ] && printf 'true\n' || printf 'false\n'
}

# _gaia_loop_hunks <git-directory> <a> <b>: one `diff -U0` of a..b, printed as
# `<path>\t<first>\t<last>` per new-side hunk. The prefixes and every option a
# user's config could flip (noprefix, mnemonicPrefix, external diff, relative,
# quotePath) are pinned on the command line. `+++ ` names a path only in a
# file header: with -U0 an added content line `++ x` prints as `+++ x`. A path
# git still quotes (a double quote, backslash or control byte in it) does not
# match any finding's path, so such a path's lines read as not authored; the
# path set from _gaia_loop_names is unaffected. rc 1 when git fails, so the
# caller fails closed rather than reading an empty hunk set as "none".
_gaia_loop_hunks() {
  local diff_output
  gaia_loop_is_oid "${2-}" && gaia_loop_is_oid "${3-}" || return 2
  diff_output="$(_gaia_loop_git -C "$1" -c core.quotePath=false diff -U0 -M --no-color --no-ext-diff \
    --no-relative --src-prefix=a/ --dst-prefix=b/ "$2" "$3" -- 2>/dev/null)" || return 1
  printf '%s\n' "$diff_output" |
    awk '
      /^diff --git / { in_header = 1; current_path = ""; next }
      in_header && /^\+\+\+ / {
        header_path = substr($0, 5); sub(/\t$/, "", header_path)
        if (header_path == "/dev/null") current_path = ""; else if (substr(header_path, 1, 2) == "b/") current_path = substr(header_path, 3); else current_path = header_path
        next
      }
      /^@@ / {
        in_header = 0
        if (current_path == "") next
        plus_offset = index($0, " +"); rest = substr($0, plus_offset + 2); space_offset = index(rest, " ")
        spec = substr(rest, 1, space_offset - 1); comma_offset = index(spec, ",")
        if (comma_offset) { start_line = substr(spec, 1, comma_offset - 1) + 0; line_count = substr(spec, comma_offset + 1) + 0 } else { start_line = spec + 0; line_count = 1 }
        if (line_count > 0) printf "%s\t%d\t%d\n", current_path, start_line, start_line + line_count - 1
      }'
}

# _gaia_loop_names <git-directory> <a> <b>: `diff --name-only -M` of a..b, one path
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

# _gaia_loop_hunks_json <git-directory> <a> <b>: new-side hunks as JSON, or `null`
# when the diff cannot be read.
_gaia_loop_hunks_json() {
  local hunks_output
  hunks_output="$(_gaia_loop_hunks "$@")" || { printf 'null\n'; return 0; }
  printf '%s' "$hunks_output" | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {p: .[0], s: (.[1] | tonumber), e: (.[2] | tonumber)})'
}

# _gaia_loop_merge_base <git-directory> <commit>: merge base with the default branch
# (origin's HEAD target, else origin/main, else local main, else master).
# Full ref names only, so no ref text can be read as an option.
_gaia_loop_merge_base() {
  local directory="$1" commit="$2" reference oid merge_base
  gaia_loop_is_oid "$commit" || return 1
  for reference in "$(_gaia_loop_git -C "$directory" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" \
    refs/remotes/origin/main refs/heads/main refs/heads/master; do
    case "$reference" in refs/*) ;; *) continue ;; esac
    oid="$(_gaia_loop_git -C "$directory" rev-parse -q --verify "$reference^{commit}" 2>/dev/null)" || continue
    gaia_loop_is_oid "$oid" || continue
    merge_base="$(_gaia_loop_git -C "$directory" merge-base "$oid" "$commit" 2>/dev/null)" || return 1
    gaia_loop_is_oid "$merge_base" || return 1
    printf '%s\n' "$merge_base"
    return 0
  done
  return 1
}

# _gaia_loop_disposed <main-root> <B> <r>: identity keys disposed non-fix in
# any dispositions-<k>.json, k < r. An unreadable file excludes nothing, so a
# lost file counts more findings, never fewer.
_gaia_loop_disposed() {
  local run k round_disposed accumulated="[]"
  run="$(gaia_loop_run_directory "$1" "$2")"
  k=1
  while [ "$k" -lt "$3" ]; do
    if [ -f "$run/dispositions-$k.json" ]; then
      round_disposed="$(jq -c '[.entries[] | select(.disposition == "accept-residual" or .disposition == "waive-out-of-scope" or .disposition == "file" or .disposition == "divert")
        | [.member, .finding_class, .path, .line]]' <"$run/dispositions-$k.json" 2>/dev/null)" || round_disposed=""
      [ -n "$round_disposed" ] && accumulated="$(jq -n -c --argjson accumulated "$accumulated" --argjson round_disposed "$round_disposed" '$accumulated + $round_disposed')"
    fi
    k=$((k + 1))
  done
  printf '%s\n' "$accumulated"
}
