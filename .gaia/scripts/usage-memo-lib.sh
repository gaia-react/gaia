# shellcheck shell=bash
# GAIA_USAGE_MEMO, _STATE and _DIRTY are the library's output, read by the
# sourcing script, never by this file.
# shellcheck disable=SC2034
#
# GAIA usage-ledger branch-derivation memo: a regenerable cache in the
# telemetry dir of what the branch-name derivation answers for each raw git
# branch and each branch key, so a readout derives only the names the stores
# gained since the last one instead of every name every time.
#
# Sourced by usage.sh after usage-lib.sh, usage-resolve-lib.sh and
# usage-render-lib.sh (gaia_usage_memo_view reads their jq defs). Defines
# functions and variables only; sourcing runs no external command. bash 3.2
# safe, and every function discards its own stderr so a memo failure can never
# add a line to a readout.
#
# The invariant that spans the file: the memo can cost speed, never
# correctness. A memo that is missing, unreadable, stamped by other derivation
# code, or fails its checksum or shape check is cold, and a cold memo is
# rebuilt from the stores. An entry the memo lacks is found by the readout's
# coverage check (usage_memo_gap), which restricts the memo to the keys the
# stores present and derives the rest before the view runs. The limit: a
# deliberate edit that also recomputes the checksum is not detected. The memo
# is local, regenerable, and never shipped, so that is out of scope.
#
# The memo stores branch-name derivations (inputs) and model names, never an
# attribution decision. Bindings, links and merges still resolve at read time.

# Every function a derivation can reach, so the version stamp changes whenever
# derivation code does. A guard test recomputes the closure and fails when a
# reachable name is missing.
GAIA_USAGE_MEMO_FUNCTIONS="gaia_usage_branch_map gaia_usage_derive_map _gaia_usage_branch_parents _gaia_usage_pad3 _gaia_usage_capture _gaia_usage_set_branch_key _gaia_usage_hash16 gaia_usage_valid_reference _gaia_usage_load gaia_branch_normalize _gaia_branch_set_normalized gaia_branch_classify _gaia_branch_set_class _gaia_branch_is_members _gaia_branch_is_digits _gaia_branch_set_leading_digits gaia_branch_members _gaia_usage_memo_derive"

_GAIA_USAGE_MEMO_EMPTY='{"bmap":{},"derive":{},"models":[],"stores":{}}'

# The head hash covers at most this many bytes, so a store that grows past it
# keeps matching its recorded hash.
_GAIA_USAGE_MEMO_HEAD_MAXIMUM=4096

# shellcheck disable=SC2016  # jq source, no shell expansion
_GAIA_USAGE_MEMO_SHAPE_JQ='
def non_negative_integer: type == "number" and . >= 0 and . == floor;
def store: type == "object" and (.path | type == "string") and (.off | non_negative_integer) and (.hn | non_negative_integer) and (.head | type == "string");
type == "object"
and (.bmap | type == "object"
  and all(.[]; type == "object" and (.norm | type == "string") and has("key") and (.key == null or (.key | type == "string"))))
and (.derive | type == "object" and all(.[]; type == "array" and all(.[]; type == "string")))
and (.models | type == "array" and all(.[]; type == "string"))
and (.stores | type == "object" and all(.[]; store))
'

# Coverage defs. Expect GAIA_USAGE_JQ_DEFS and GAIA_USAGE_RESOLVE_JQ ahead of
# them. usage_present reproduces the scan gaia_usage_keys_json runs today, field
# for field, so a memo-restricted $keys is equivalent for every consumer.
# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts; jq source, no shell expansion
GAIA_USAGE_MEMO_JQ='
def usage_present($usage_records; $links; $cost):
  [$usage_records[] | select(.kind == "segment")] as $segments
  | {raws: ([$cost[] | select(.kind == "plan" or .kind == "execute") | .git_branch | strings] | unique),
     bkeys: ([($segments[] | .key), ($links[] | .child, .parent, .key)]
       | map(strings | select(startswith("branch:"))) | unique),
     models: (try ([$segments[] | (.by_model // {}) | keys[]] | unique) catch null)};

# The derive keys the readout needs: every present branch key plus the key of
# each present raw.
def usage_memo_need($present; $memo):
  (($present.bkeys + [$present.raws[] | $memo.bmap[.].key | strings]) | unique);

def usage_memo_gap($present; $memo):
  [$present.raws[] | select($memo.bmap[.] == null)] as $missing_raws
  | [usage_memo_need($present; $memo)[] | select($memo.derive[.] == null)] as $missing_keys
  | ($present.models - $memo.models) as $missing_models
  | ($memo.models - $present.models) as $extra_models
  | if ($missing_raws | length) == 0 and ($missing_keys | length) == 0 and ($missing_models | length) == 0 and ($extra_models | length) == 0 then null
    else {raws: $missing_raws, bkeys: $missing_keys, models: $missing_models, models_extra: $extra_models} end;

def usage_memo_keys($present; $memo; $default):
  {bmap: ($present.raws | map({key: ., value: $memo.bmap[.]}) | from_entries),
   derive: (usage_memo_need($present; $memo) | map({key: ., value: $memo.derive[.]})
     | map(select(.value | length > 0)) | from_entries),
   default: $default,
   models: $present.models};
'

gaia_usage_memo_path() { printf '%s\n' "${1%/}/usage-branch-memo.json"; }

gaia_usage_memo_trace() {
  [ -n "${GAIA_USAGE_MEMO_TRACE:-}" ] || return 0
  printf '%s\n' "$1" 2>/dev/null >>"$GAIA_USAGE_MEMO_TRACE" || true
  return 0
}

# The stamp hashes the source text of each stamped function, extracted by name,
# never `declare -f` output: that prints differently under bash 3.2 and bash 5,
# and one memo has to stay warm when one clone is read by both. A name that
# extracts nothing makes the stamp unavailable, so a rename cannot silently hash
# nothing. The awk reads a block function from its column-0 `name() {` to the
# next column-0 `}`, and a one-liner as its single line.
# shellcheck disable=SC2016  # awk source, no shell expansion
gaia_usage_memo_stamp() {
  local source_file library_directory text stamp_hash
  _gaia_usage_memo_stamp=""
  _gaia_usage_memo_stamp_exit_status=1
  _gaia_usage_load gaia_branch_classify branch-name-lib.sh 2>/dev/null || return 1
  source_file="${BASH_SOURCE[0]:-}"
  [ -n "$source_file" ] || return 1
  case "$source_file" in */*) library_directory="${source_file%/*}" ;; *) library_directory=. ;; esac
  text="$(awk -v names="$GAIA_USAGE_MEMO_FUNCTIONS" '
    BEGIN { name_count = split(names, order, " "); for (i = 1; i <= name_count; i++) want[order[i]] = 1 }
    capturing_name != "" { body[capturing_name] = body[capturing_name] $0 "\n"; if ($0 == "}") capturing_name = ""; next }
    {
      marker_position = index($0, "() {")
      if (marker_position < 2) next
      function_name = substr($0, 1, marker_position - 1)
      if (!(function_name in want)) next
      body[function_name] = body[function_name] $0 "\n"
      if (substr($0, marker_position + 4) == "" || substr($0, length($0)) != "}") capturing_name = function_name
    }
    END {
      for (i = 1; i <= name_count; i++) { function_name = order[i]; if (body[function_name] == "") bad = 1; printf "%s\n%s", function_name, body[function_name] }
      exit bad
    }' "$library_directory/usage-lib.sh" "$library_directory/usage-resolve-lib.sh" "$library_directory/branch-name-lib.sh" "$library_directory/usage-memo-lib.sh" 2>/dev/null)" || return 1
  stamp_hash="$(_gaia_usage_hash16 "usage-branch-memo/1"$'\n'"$text" 2>/dev/null)" || return 1
  [ -n "$stamp_hash" ] || return 1
  _gaia_usage_memo_stamp="$stamp_hash"
  _gaia_usage_memo_stamp_exit_status=0
  return 0
}

# Reads the stamp a prior gaia_usage_memo_stamp call left; it never computes
# one, so a readout pays for the stamp once.
gaia_usage_memo_load() {
  local memo="$1" header="" body="" extra="" fields="" stamp_hash sum_hash reason="" unit_separator=$'\x1f'
  GAIA_USAGE_MEMO="$_GAIA_USAGE_MEMO_EMPTY"
  GAIA_USAGE_MEMO_STATE=cold
  GAIA_USAGE_MEMO_DIRTY=1
  if [ ! -e "$memo" ]; then
    reason=missing
  elif ! { IFS= read -r header && IFS= read -r body && ! IFS= read -r extra && [ -z "$extra" ]; } 2>/dev/null <"$memo"; then
    reason=unreadable
  else
    # shellcheck disable=SC2016  # jq source, no shell expansion
    fields="$(jq -r 'if type == "object" and .schema_version == 1 then "\(.stamp // "")\u001f\(.sum // "")" else empty end' <<<"$header" 2>/dev/null)" || fields=""
    if [ -z "$fields" ]; then
      reason=schema
    elif [ "${_gaia_usage_memo_stamp_exit_status:-1}" != 0 ] || [ -z "${_gaia_usage_memo_stamp:-}" ]; then
      reason=stamp-unavailable
    else
      stamp_hash="${fields%%"$unit_separator"*}"
      sum_hash="${fields#*"$unit_separator"}"
      if [ "$stamp_hash" != "$_gaia_usage_memo_stamp" ]; then
        reason=stamp
      elif [ "$(_gaia_usage_hash16 "$body" 2>/dev/null)" != "$sum_hash" ]; then
        reason=sum
      elif ! jq -e "$_GAIA_USAGE_MEMO_SHAPE_JQ" <<<"$body" >/dev/null 2>&1; then
        reason=shape
      fi
    fi
  fi
  if [ -n "$reason" ]; then
    gaia_usage_memo_trace "path=cold reason=$reason"
    return 0
  fi
  GAIA_USAGE_MEMO="$body"
  GAIA_USAGE_MEMO_STATE=warm
  GAIA_USAGE_MEMO_DIRTY=0
  gaia_usage_memo_trace "path=warm"
  return 0
}

# Removes temp files an interrupted save left behind. 60 s because a readout
# killed at its cap gets TERM then KILL, so a trap alone would miss the KILL.
gaia_usage_memo_reap() {
  local temporary_file reaped_count=0
  while IFS= read -r temporary_file; do
    if rm -f "$temporary_file" 2>/dev/null; then reaped_count=$((reaped_count + 1)); fi
  done < <(find "$1" -maxdepth 1 -name '.usage-branch-memo.tmp.*' -type f -mmin +1 2>/dev/null)
  if [ "$reaped_count" -gt 0 ]; then gaia_usage_memo_trace "reap=$reaped_count"; fi
  return 0
}

# Prints the first <n> bytes' hash. `wc -c` pads under BSD, so callers trim.
_gaia_usage_memo_head_hash() {
  { _gaia_usage_hash16 "$(head -c "$2" "$1")"; } 2>/dev/null
}

# Prints the byte length of the partial last line within the first <snapshot_size> bytes
# of <file> (0 when the snapshot ends on a newline). A torn line is left for
# the next read, so an offset is only ever a line boundary.
_gaia_usage_memo_torn_length() {
  local LC_ALL=C
  local file="$1" snapshot_size="$2" floor="$3" read_length chunk
  read_length=4096
  {
    while :; do
      if [ "$read_length" -gt "$((snapshot_size - floor))" ]; then read_length="$((snapshot_size - floor))"; fi
      [ "$read_length" -gt 0 ] || { printf '0'; return 0; }
      chunk="$(tail -c "+$((snapshot_size - read_length + 1))" "$file" | head -c "$read_length"; printf x)"
      chunk="${chunk%x}"
      case "$chunk" in
        *$'\n'*) chunk="${chunk##*$'\n'}"; printf '%s' "${#chunk}"; return 0 ;;
      esac
      if [ "$read_length" -ge "$((snapshot_size - floor))" ]; then printf '%s' "$((snapshot_size - floor))"; return 0; fi
      read_length="$((read_length * 4))"
    done
  } 2>/dev/null
}

# _gaia_usage_memo_slice <file> <start> <end>: bytes [start, end) of <file>.
# From offset 0 it is `head -c` alone, because BSD `tail -c +1` copies byte by
# byte and takes seconds over a store of tens of megabytes.
_gaia_usage_memo_slice() {
  if [ "$2" -eq 0 ]; then
    head -c "$3" "$1"
  else
    tail -c "+$(($2 + 1))" "$1" | head -c "$(($3 - $2))"
  fi
}

# _gaia_usage_memo_scan <file> <start> <end> <kind>: one JSON object
# {k: branch keys, m: models, r: raw branches} from bytes [start, end). Both
# patterns are escape-blind on purpose: a value spelled with a JSON escape is
# not matched, so the memo lacks it and the readout's coverage check derives it
# on a miss. The model pattern assumes the flusher's key order (fresh_input
# first in each by_model entry, entries separated by `},`); a row in another
# order is caught the same way. It opens on `by_model` or `},` because BSD grep
# takes four times as long over a pattern that opens with a character class.
_gaia_usage_memo_scan() {
  local file="$1" start="$2" end="$3" kind="$4" scan_json=""
  case "$kind" in
    c)
      scan_json="$({ _gaia_usage_memo_slice "$file" "$start" "$end"; } 2>/dev/null |
        LC_ALL=C grep -oE '"git_branch":"[^"\\]*"' |
        LC_ALL=C sort -u |
        LC_ALL=C sed 's/^"git_branch":"\(.*\)"$/\1/' |
        jq -Rnc '{k: [], m: [], r: [inputs]}' 2>/dev/null)" || true
      ;;
    l)
      scan_json="$({ _gaia_usage_memo_slice "$file" "$start" "$end"; } 2>/dev/null |
        LC_ALL=C grep -oE '"(key|child|parent)":"branch:[^"\\]*"' |
        LC_ALL=C sort -u |
        LC_ALL=C sed -E 's/^"[a-z]+":"(branch:.*)"$/K\1/' |
        jq -Rnc '[inputs] | {k: [.[] | select(startswith("K")) | .[1:]], m: [], r: []}' 2>/dev/null)" || true
      ;;
    u)
      scan_json="$({ _gaia_usage_memo_slice "$file" "$start" "$end"; } 2>/dev/null |
        LC_ALL=C grep -oE -e '"(key|child|parent)":"branch:[^"\\]*"' -e '("by_model":\{|\},)"[^"\\]*":\{"fresh_input":' |
        LC_ALL=C sort -u |
        LC_ALL=C sed -nE 's/^"(key|child|parent)":"(branch:.*)"$/K\2/p; s/^.*"([^"\\]*)":\{"fresh_input":$/M\1/p' |
        jq -Rnc '[inputs] | {k: [.[] | select(startswith("K")) | .[1:]], m: [.[] | select(startswith("M")) | .[1:]], r: []}' 2>/dev/null)" || true
      ;;
  esac
  case "$scan_json" in '{'*) printf '%s' "$scan_json" ;; *) return 1 ;; esac
}

# _gaia_usage_memo_derive <aggregate>: <aggregate> is {k: [branch keys], r: [raw branches]}.
# Derives what GAIA_USAGE_MEMO lacks and merges it in: new raws through
# gaia_usage_branch_map, then every key not yet in `derive` (the given keys plus
# each new raw's key) through gaia_usage_derive_map, recording [] for a key that
# implies no parent so it counts as processed. Lists cross to bash NUL-delimited
# because a raw can legitimately be the empty string.
_gaia_usage_memo_derive() {
  local aggregate="$1" item new_branch_map="{}" derive_map="{}" merged
  local -a new_raws=() new_keys=()
  while IFS= read -r -d '' item; do new_raws[${#new_raws[@]}]="$item"; done < <(
    printf '%s\n%s\n' "$GAIA_USAGE_MEMO" "$aggregate" |
      jq -j -n 'input as $memo | input as $aggregate | $aggregate.r | unique | .[] | select($memo.bmap[.] == null) | ., "\u0000"' 2>/dev/null)
  if [ "${#new_raws[@]}" -gt 0 ]; then
    new_branch_map="$(gaia_usage_branch_map ${new_raws[@]+"${new_raws[@]}"} 2>/dev/null)" || return 1
  fi
  while IFS= read -r -d '' item; do new_keys[${#new_keys[@]}]="$item"; done < <(
    printf '%s\n%s\n%s\n' "$GAIA_USAGE_MEMO" "$aggregate" "$new_branch_map" |
      jq -j -n 'input as $memo | input as $aggregate | input as $new_branch_map
        | ($aggregate.k + [$new_branch_map[].key | strings]) | unique | .[] | select($memo.derive[.] == null) | ., "\u0000"' 2>/dev/null)
  if [ "${#new_keys[@]}" -gt 0 ]; then
    derive_map="$(gaia_usage_derive_map ${new_keys[@]+"${new_keys[@]}"} 2>/dev/null)" || return 1
  fi
  merged="$(printf '%s\n%s\n%s\n%s\n' "$GAIA_USAGE_MEMO" "$aggregate" "$new_branch_map" "$derive_map" |
    jq -cS -n 'input as $memo | input as $aggregate | input as $new_branch_map | input as $derive_map
      | (($aggregate.k + [$new_branch_map[].key | strings]) | unique | map(select($memo.derive[.] == null))) as $new_derive_keys
      | $memo | .bmap += $new_branch_map | .derive += ($new_derive_keys | map({key: ., value: ($derive_map[.] // [])}) | from_entries)' 2>/dev/null)" || return 1
  [ -n "$merged" ] || return 1
  GAIA_USAGE_MEMO="$merged"
}

# Warms GAIA_USAGE_MEMO from the bytes each store gained since the memo last
# looked. A store whose recorded path, size floor, or first bytes no longer
# match is scanned in full. A rewrite that keeps the size at or above the
# recorded offset and the first bytes unchanged goes undetected here on purpose:
# the readout's coverage check derives whatever the rewritten rows name.
gaia_usage_memo_warm() {
  local before store_tag store_file stored_record recorded_path recorded_offset recorded_head_length recorded_head_hash snapshot_size start new_offset reason torn head_length head_hash scan
  local usage_full_scan=0 any=0 unit_separator=$'\x1f' store_records="" aggregate models new
  [ -n "${GAIA_USAGE_MEMO:-}" ] || GAIA_USAGE_MEMO="$_GAIA_USAGE_MEMO_EMPTY"
  before="$GAIA_USAGE_MEMO"
  store_records="$(jq -r '.stores as $stores | ("u", "l", "c") | ($stores[.] // null)
      | if . == null then "-" else "\(.path)\u001f\(.off)\u001f\(.hn)\u001f\(.head)" end' <<<"$GAIA_USAGE_MEMO" 2>/dev/null)" || store_records=""
  local stored_usage_record stored_links_record stored_cost_record
  { IFS= read -r stored_usage_record; IFS= read -r stored_links_record; IFS= read -r stored_cost_record; } <<<"$store_records" || true
  local usage_scan="" links_scan="" cost_scan="" usage_update="" links_update="" cost_update=""
  for store_tag in u l c; do
    case "$store_tag" in
      u) store_file="$1"; stored_record="${stored_usage_record:--}" ;;
      l) store_file="$2"; stored_record="${stored_links_record:--}" ;;
      c) store_file="$3"; stored_record="${stored_cost_record:--}" ;;
    esac
    [ -f "$store_file" ] && [ -r "$store_file" ] || continue
    snapshot_size="$(wc -c <"$store_file" 2>/dev/null)" || continue
    snapshot_size="${snapshot_size//[[:space:]]/}"
    case "$snapshot_size" in '' | *[!0-9]*) continue ;; esac
    start=0
    reason=new
    recorded_path="" recorded_offset=0 recorded_head_length=0 recorded_head_hash=""
    if [ "$stored_record" != "-" ]; then
      IFS="$unit_separator" read -r recorded_path recorded_offset recorded_head_length recorded_head_hash <<<"$stored_record"
      case "$recorded_offset$recorded_head_length" in '' | *[!0-9]*) recorded_path="" ;; esac
      if [ "$recorded_path" != "$store_file" ]; then
        reason=path
      elif [ "$snapshot_size" -lt "$recorded_offset" ]; then
        reason=shrunk
      elif [ "$(_gaia_usage_memo_head_hash "$store_file" "$recorded_head_length")" != "$recorded_head_hash" ]; then
        reason="head"
      else
        reason=""
        start="$recorded_offset"
      fi
    fi
    torn="$(_gaia_usage_memo_torn_length "$store_file" "$snapshot_size" "$start")" || torn=0
    case "$torn" in '' | *[!0-9]*) torn=0 ;; esac
    new_offset="$((snapshot_size - torn))"
    if [ -z "$reason" ]; then
      [ "$new_offset" -gt "$start" ] || continue
    else
      gaia_usage_memo_trace "scan=full store=$store_tag reason=$reason"
    fi
    if [ "$new_offset" -gt "$start" ]; then
      scan="$(_gaia_usage_memo_scan "$store_file" "$start" "$new_offset" "$store_tag")" || continue
    else
      scan='{"k":[],"m":[],"r":[]}'
    fi
    head_length="$new_offset"
    [ "$head_length" -le "$_GAIA_USAGE_MEMO_HEAD_MAXIMUM" ] || head_length="$_GAIA_USAGE_MEMO_HEAD_MAXIMUM"
    if [ -z "$reason" ] && [ "$recorded_head_length" = "$head_length" ]; then
      head_hash="$recorded_head_hash"
    else
      head_hash="$(_gaia_usage_memo_head_hash "$store_file" "$head_length")" || continue
    fi
    new="$(jq -nc --arg path "$store_file" --argjson offset "$new_offset" --argjson head_length "$head_length" --arg head_hash "$head_hash" '{path: $path, off: $offset, hn: $head_length, head: $head_hash}' 2>/dev/null)" || continue
    case "$store_tag" in
      u) usage_scan="$scan"; usage_update="$new"; [ -n "$reason" ] && usage_full_scan=1 ;;
      l) links_scan="$scan"; links_update="$new" ;;
      c) cost_scan="$scan"; cost_update="$new" ;;
    esac
    any=1
  done
  [ "$any" = 1 ] || return 0
  aggregate="$(printf '%s\n%s\n%s\n' "$usage_scan" "$links_scan" "$cost_scan" |
    jq -cn '[inputs] | {k: (map(.k) | add // [] | unique), r: (map(.r) | add // [] | unique)}' 2>/dev/null)" || aggregate=""
  [ -n "$aggregate" ] || return 0
  if ! _gaia_usage_memo_derive "$aggregate"; then
    # Offsets stay where they were, so the next read scans these bytes again.
    GAIA_USAGE_MEMO="$before"
    return 0
  fi
  models="[]"
  if [ -n "$usage_scan" ]; then models="$(jq -c '.m' <<<"$usage_scan" 2>/dev/null)" || models="[]"; fi
  new="$(printf '%s\n%s\n%s\n%s\n' "$GAIA_USAGE_MEMO" "${usage_update:-null}" "${links_update:-null}" "${cost_update:-null}" |
    jq -cS -n --argjson scanned_models "$models" --argjson full "$usage_full_scan" --argjson has_usage_scan "$([ -n "$usage_scan" ] && echo true || echo false)" '
      input as $memo | input as $usage_update | input as $links_update | input as $cost_update
      | $memo
      | (if $usage_update != null then .stores.u = $usage_update else . end)
      | (if $links_update != null then .stores.l = $links_update else . end)
      | (if $cost_update != null then .stores.c = $cost_update else . end)
      | if $has_usage_scan then .models = (if $full == 1 then $scanned_models else (.models + $scanned_models) end | unique) else . end' 2>/dev/null)" || new=""
  [ -n "$new" ] && GAIA_USAGE_MEMO="$new"
  if [ "$GAIA_USAGE_MEMO" != "$before" ]; then GAIA_USAGE_MEMO_DIRTY=1; fi
  return 0
}

# Merges a coverage gap ({raws, bkeys, models, models_extra}) into the memo, so
# the memo ends covering exactly the present set.
gaia_usage_memo_merge_gap() {
  local gap="$1" before="${GAIA_USAGE_MEMO:-}" aggregate new
  [ -n "$before" ] || { GAIA_USAGE_MEMO="$_GAIA_USAGE_MEMO_EMPTY"; before="$GAIA_USAGE_MEMO"; }
  aggregate="$(jq -c '{k: (.bkeys // []), r: (.raws // [])}' <<<"$gap" 2>/dev/null)" || return 0
  [ -n "$aggregate" ] || return 0
  _gaia_usage_memo_derive "$aggregate" || GAIA_USAGE_MEMO="$before"
  new="$(printf '%s\n%s\n' "$GAIA_USAGE_MEMO" "$gap" |
    jq -cS -n 'input as $memo | input as $gap
      | $memo | .models = (((.models - ($gap.models_extra // [])) + ($gap.models // [])) | unique)' 2>/dev/null)" || new=""
  [ -n "$new" ] && GAIA_USAGE_MEMO="$new"
  if [ "$GAIA_USAGE_MEMO" != "$before" ]; then GAIA_USAGE_MEMO_DIRTY=1; fi
  return 0
}

# Temp then rename, never in place and never under the ledger mutex: a reader
# sees the old memo or the new one, and a failed write leaves the readout on
# its in-memory memo.
gaia_usage_memo_save() {
  local memo="$1" memo_directory temporary_file sum
  if [ "${_gaia_usage_memo_stamp_exit_status:-1}" != 0 ] || [ -z "${_gaia_usage_memo_stamp:-}" ]; then
    gaia_usage_memo_trace "write=skip"
    return 0
  fi
  case "$memo" in */*) memo_directory="${memo%/*}" ;; *) memo_directory=. ;; esac
  temporary_file="$(mktemp "$memo_directory/.usage-branch-memo.tmp.XXXXXX" 2>/dev/null)" || temporary_file=""
  if [ -z "$temporary_file" ]; then gaia_usage_memo_trace "write=fail"; return 0; fi
  sum="$(_gaia_usage_hash16 "${GAIA_USAGE_MEMO:-}" 2>/dev/null)" || sum=""
  if [ -n "$sum" ] && [ -n "${GAIA_USAGE_MEMO:-}" ] &&
    printf '{"schema_version":1,"stamp":"%s","sum":"%s"}\n%s\n' "$_gaia_usage_memo_stamp" "$sum" "$GAIA_USAGE_MEMO" 2>/dev/null >"$temporary_file" &&
    mv -f "$temporary_file" "$memo" 2>/dev/null; then
    GAIA_USAGE_MEMO_DIRTY=0
    gaia_usage_memo_trace "write=ok"
    return 0
  fi
  rm -f "$temporary_file" 2>/dev/null
  gaia_usage_memo_trace "write=fail"
  return 0
}

# The single parse's prelude. It binds the rows once, then answers in one of
# three shapes: {"legacy":true} when the models cannot be listed (the
# pre-change readout handles that case its own way), {"miss":<gap>} when the
# memo lacks a name the stores present, or the view itself. The view takes the
# restricted memo as an explicit argument because a def body's $keys always
# names the global, so a binding made here could never reach it.
# shellcheck disable=SC2016  # jq source, no shell expansion
_GAIA_USAGE_MEMO_PRELUDE_JQ='
[inputs | (try fromjson catch null) | select(type == "object" and .schema_version == 1)] as $usage_records
| usage_rows($_links_raw) as $links | usage_rows($_cost_raw) as $cost
| usage_present($usage_records; $links; $cost) as $present
| if $present.models == null then {legacy: true}
  else ($_memo_raw | fromjson) as $_memo | usage_memo_gap($present; $_memo) as $gap
  | if $gap != null then {miss: $gap}
    else usage_memo_keys($present; $_memo; $_default) as $memo_keys | '

# gaia_usage_memo_view <usage> <links> <cost> <default-branch> <filter> [jq args...]:
# runs <filter> (a view over $usage_records, $links, $cost and $memo_keys) in one jq process
# over the stores and GAIA_USAGE_MEMO, printing the view, {"miss":...} or
# {"legacy":true}. rc 1 when a store cannot be read or jq fails. Cursor rows are
# dropped before jq, since no view reads them; only the flusher's own spelling
# is dropped, so any other line reaches jq and is kept or skipped as before.
# The globals the defs name are bound empty: no view the filter calls reads them.
# The memo reaches jq on fd 3, never argv: Linux refuses any one argument over
# 128 KiB (MAX_ARG_STRLEN), which a year of memo passes, so --argjson would fail
# every readout over to the legacy path. A here-string costs no fork, and
# stderr is redirected ahead of it so a here-string temp that cannot be made
# stays silent too.
# shellcheck disable=SC2016  # jq source, no shell expansion
gaia_usage_memo_view() {
  local usage_store="$1" links_store="$2" cost_store="$3" default_branch="$4" filter="$5" pricing="${GAIA_PRICING_JQ_DEFS-}" pipe_statuses
  shift 5
  [ -f "$usage_store" ] || usage_store=/dev/null
  [ -f "$links_store" ] || links_store=/dev/null
  [ -f "$cost_store" ] || cost_store=/dev/null
  [ -n "$pricing" ] || pricing='def priced_row($row): {dollars: 0, unpriced: []};'
  LC_ALL=C grep -v '^{"schema_version":1,"kind":"cursor",' "$usage_store" 2>/dev/null |
    jq -nRc --rawfile _links_raw "$links_store" --rawfile _cost_raw "$cost_store" --rawfile _memo_raw /dev/fd/3 \
      --arg _default "$default_branch" --arg usage_store "" --arg links_store "" --arg cost_store "" --argjson keys '{}' "$@" \
      "$GAIA_USAGE_JQ_DEFS$pricing$GAIA_USAGE_RESOLVE_JQ$GAIA_USAGE_MODEL_JQ$GAIA_USAGE_VIEW_JQ$GAIA_USAGE_MEMO_JQ$_GAIA_USAGE_MEMO_PRELUDE_JQ$filter end end" \
      2>/dev/null 3<<<"${GAIA_USAGE_MEMO:-null}"
  pipe_statuses="${PIPESTATUS[0]} ${PIPESTATUS[1]}"
  # grep exits 1 when it selects no line (an empty store, or only cursor rows).
  case "$pipe_statuses" in "0 0" | "1 0") return 0 ;; *) return 1 ;; esac
}

# gaia_usage_memo_readout <library-directory> <telemetry-directory> <cost> <main-root> <rate-override>
# <view> [jq args...]: the memo-path readout. Prints the view JSON, or rc 1 when
# the caller must run the pre-change sequence instead (a jq or read failure, a
# model list that cannot be built, or a second coverage miss). The memo is
# saved before the view runs, so a readout killed at the render cap still
# leaves the next one warm. Every step discards its stderr.
gaia_usage_memo_readout() {
  local library_directory="$1" telemetry_directory="$2" cost="$3" main="$4" table="$5" view="$6" memo default_branch models rates view_output miss_count=0
  shift 6
  memo="$(gaia_usage_memo_path "$telemetry_directory")"
  default_branch="$(gaia_usage_default_branch "${main:-.}" 2>/dev/null)"
  gaia_usage_memo_stamp 2>/dev/null
  gaia_usage_memo_reap "$telemetry_directory"
  gaia_usage_memo_load "$memo"
  gaia_usage_memo_warm "$telemetry_directory/usage.jsonl" "$telemetry_directory/links.jsonl" "$cost"
  if [ "$GAIA_USAGE_MEMO_DIRTY" = 1 ]; then gaia_usage_memo_save "$memo"; fi
  models="$(gaia_usage_memo_models)" || return 1
  usage_rates_load "$table" "$main" "$models" 2>/dev/null
  rates="$USAGE_RATES"
  gaia_usage_memo_seam
  while :; do
    view_output="$(gaia_usage_memo_view "$telemetry_directory/usage.jsonl" "$telemetry_directory/links.jsonl" "$cost" "$default_branch" "$view" \
      --argjson rates "$rates" "$@")" || return 1
    case "$view_output" in
      '{"miss":'*) [ "$miss_count" = 0 ] || return 1 ;;
      '' | '{"legacy":true}') return 1 ;;
      *) printf '%s\n' "$view_output"; return 0 ;;
    esac
    miss_count=1
    gaia_usage_memo_take_gap "$telemetry_directory" "$view_output" || return 1
  done
}

# Prints the memo's models as compact JSON, the spelling usage_models_of
# prints, so the model list matches what a pre-change readout passes.
gaia_usage_memo_models() { jq -er '.models | tojson' <<<"${GAIA_USAGE_MEMO:-}" 2>/dev/null; }

# gaia_usage_memo_take_gap <telemetry-directory> <view-output>: traces, merges and saves the
# {"miss": gap} a view printed. rc 0 when done, 1 when the output carries no
# readable gap.
gaia_usage_memo_take_gap() {
  local gap counts
  gap="$(jq -c '.miss | objects' <<<"$2" 2>/dev/null)" || return 1
  counts="$(jq -r '"raws=\(.raws | length) bkeys=\(.bkeys | length) models=\((.models | length) + (.models_extra | length))"' \
    <<<"$gap" 2>/dev/null)" || return 1
  [ -n "$counts" ] || return 1
  gaia_usage_memo_trace "rerun=miss $counts"
  gaia_usage_memo_merge_gap "$gap"
  if [ "$GAIA_USAGE_MEMO_DIRTY" = 1 ]; then gaia_usage_memo_save "$(gaia_usage_memo_path "$1")"; fi
  return 0
}

# Test observability for the window between the memo being saved and the view
# running. Inert unless a bats run asks for it.
gaia_usage_memo_seam() {
  if [ -n "${GAIA_USAGE_MEMO_SEAM:-}" ] && [ -n "${BATS_TEST_TMPDIR:-}" ]; then
    bash "$GAIA_USAGE_MEMO_SEAM" </dev/null >/dev/null 2>&1 || true
  fi
  return 0
}
