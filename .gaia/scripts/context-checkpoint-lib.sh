# shellcheck shell=bash
#
# Shared context threshold lib. The ONE tracked place the context checkpoint
# line, the statusline bands and the unit round count are defined; the
# statusline and the audit-loop bound hook / evaluator both source it, so the
# bar color and the checkpoint can never disagree.
#
# Owns: the checkpoint line (tokens capped by percent of the window), the
# yellow/red/fire/skull bands, K (rounds per unit), the freshness window for a
# context reading, and the per-session context file (path, write, read).
# Does not own: the round count, the grant size or the rubric defaults; those
# stay in audit-loop-eval.sh.
#
# Override rule. An optional machine-local file, <main>/.gaia/local/settings.json,
# may LOWER the line (ask_tokens, ask_window_pct). It can never raise it: an
# absent, invalid, out-of-range or raised value reads as the shipped default.
# The file is machine-local and writable by whoever runs the session, so a
# raise would let a session widen its own bound.
#
# Low confidence: the shipped defaults are tunable estimates, not measured
# facts. Their evidence lives in research notes, not here.
#
# Sourcing defines constants and functions only and runs no external command,
# so it is safe in the statusline's hot path, under `set -u`, and with PATH
# empty. Bash 3.2 compatible, integer arithmetic only, never `cd`s, and has no
# `set -e`. Double-sourcing is a no-op.

[ -n "${_GAIA_CTX_LIB_LOADED:-}" ] && return 0
_GAIA_CTX_LIB_LOADED=1

GAIA_CTX_ASK_TOKENS_DEFAULT=300000
GAIA_CTX_ASK_WINDOW_PCT_DEFAULT=50
# shellcheck disable=SC2034 # read by the bound hook and the evaluator that source this lib
GAIA_CTX_UNIT_ROUNDS=3
GAIA_CTX_YELLOW_TOKENS=200000
GAIA_CTX_YELLOW_WINDOW_PCT=30
GAIA_CTX_FIRE_NUM=5
GAIA_CTX_FIRE_DEN=4
GAIA_CTX_SKULL_NUM=3
GAIA_CTX_SKULL_DEN=2
GAIA_CTX_FRESH_SECONDS=1800
GAIA_CTX_FILE_VERSION=1

# A reader treats a reading written this many seconds in the future as still
# plausible: the writer (statusline) and the reader (hook) are separate
# processes and their clocks may differ slightly.
_GAIA_CTX_SKEW_SECONDS=60

# gaia_ctx_is_session_id <s>: rc 0 for a UUID-shaped id. Builtins only.
gaia_ctx_is_session_id() {
  local re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
  [[ ${1:-} =~ $re ]]
}

# gaia_ctx_file <main-root> <session_id>: print the context file path.
gaia_ctx_file() {
  gaia_ctx_is_session_id "${2:-}" || return 1
  printf '%s/.gaia/local/cache/shared/context/%s.json\n' "${1:-}" "$2"
}

# gaia_ctx_override <main-root>: print "<ask_tokens> <ask_window_pct>". Each
# field is honoured only as a JSON integer in 1..default; version must be 1.
gaia_ctx_override() {
  local file="${1:-}/.gaia/local/settings.json" out
  local dt="$GAIA_CTX_ASK_TOKENS_DEFAULT" dp="$GAIA_CTX_ASK_WINDOW_PCT_DEFAULT"
  if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
    out=$(jq -r --argjson dt "$dt" --argjson dp "$dp" '
      def lowered($d): type == "number" and . == floor and . >= 1 and . <= $d;
      if type == "object" and .version == 1 then
        (.context_checkpoint | if type == "object" then . else {} end) as $c
        | "\(if ($c.ask_tokens | lowered($dt)) then $c.ask_tokens else $dt end) \(if ($c.ask_window_pct | lowered($dp)) then $c.ask_window_pct else $dp end)"
      else empty end' "$file" 2>/dev/null) || out=""
    if [[ $out =~ ^[0-9]{1,12}\ [0-9]{1,12}$ ]]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  printf '%s %s\n' "$dt" "$dp"
}

# gaia_ctx_line <window_size> <ask_tokens> <ask_window_pct>
gaia_ctx_line() {
  local re='^[0-9]{1,12}$' cap
  [[ ${1:-} =~ $re && ${2:-} =~ $re && ${3:-} =~ $re ]] || return 2
  cap=$(($1 * $3 / 100))
  if [ "$2" -lt "$cap" ]; then printf '%s\n' "$2"; else printf '%s\n' "$cap"; fi
}

# gaia_ctx_bands <window_size> <line>: print "<yellow> <red> <fire> <skull>".
gaia_ctx_bands() {
  local re='^[0-9]{1,12}$' yellow pct_anchor
  [[ ${1:-} =~ $re && ${2:-} =~ $re ]] || return 2
  yellow=$GAIA_CTX_YELLOW_TOKENS
  pct_anchor=$(($1 * GAIA_CTX_YELLOW_WINDOW_PCT / 100))
  [ "$pct_anchor" -lt "$yellow" ] && yellow=$pct_anchor
  [ "$2" -lt "$yellow" ] && yellow=$2
  printf '%s %s %s %s\n' "$yellow" "$2" \
    $(($2 * GAIA_CTX_FIRE_NUM / GAIA_CTX_FIRE_DEN)) \
    $(($2 * GAIA_CTX_SKULL_NUM / GAIA_CTX_SKULL_DEN))
}

# gaia_ctx_write <main-root> <session_id> <used_percentage> <used_tokens> <window_size> <epoch>
# Atomic: write <file>.tmp.$$ beside the target, then mv -f. The `.tmp.<pid>`
# pattern is what the state housekeeping sweep removes when orphaned.
gaia_ctx_write() {
  local root="${1:-}" sid="${2:-}" pct="${3:-}" tokens="${4:-}" window="${5:-}" epoch="${6:-}"
  local int='^[0-9]{1,12}$' num='^[0-9]{1,3}(\.[0-9]{1,6})?$' file dir tmp
  [[ $tokens =~ $int && $window =~ $int && $epoch =~ $int && $pct =~ $num ]] || return 1
  file=$(gaia_ctx_file "$root" "$sid") || return 1
  dir="${file%/*}"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$file.tmp.$$"
  printf '{"version":%s,"session_id":"%s","used_percentage":%s,"used_tokens":%s,"context_window_size":%s,"written_at":%s}\n' \
    "$GAIA_CTX_FILE_VERSION" "$sid" "$pct" "$tokens" "$window" "$epoch" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# gaia_ctx_read <main-root> <session_id> <now-epoch>: one line, either
# "fresh <used_tokens> <window_size>" (rc 0) or missing|stale|future|unparseable (rc 1).
gaia_ctx_read() {
  local file out used window written int='^[0-9]{1,12}$'
  file=$(gaia_ctx_file "${1:-}" "${2:-}") || { printf 'missing\n'; return 1; }
  [[ ${3:-} =~ $int ]] || { printf 'unparseable\n'; return 1; }
  [ -f "$file" ] || { printf 'missing\n'; return 1; }
  command -v jq >/dev/null 2>&1 || { printf 'unparseable\n'; return 1; }
  out=$(jq -r --argjson v "$GAIA_CTX_FILE_VERSION" '
    def whole: type == "number" and . == floor and . >= 0;
    if type == "object" and .version == $v and (.used_tokens | whole) and (.context_window_size | whole) and (.written_at | whole)
    then "\(.used_tokens) \(.context_window_size) \(.written_at)" else empty end' "$file" 2>/dev/null) || out=""
  if ! [[ $out =~ ^[0-9]{1,12}\ [0-9]{1,12}\ [0-9]{1,12}$ ]]; then
    printf 'unparseable\n'
    return 1
  fi
  read -r used window written <<<"$out"
  if [ "$written" -gt $(($3 + _GAIA_CTX_SKEW_SECONDS)) ]; then
    printf 'future\n'
    return 1
  fi
  if [ $(($3 - written)) -gt "$GAIA_CTX_FRESH_SECONDS" ]; then
    printf 'stale\n'
    return 1
  fi
  printf 'fresh %s %s\n' "$used" "$window"
}
