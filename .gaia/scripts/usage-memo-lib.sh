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
# Sourced by usage.sh after usage-lib.sh and usage-resolve-lib.sh. Defines
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
GAIA_USAGE_MEMO_FNS="gaia_usage_branch_map gaia_usage_derive_map _gaia_usage_branch_parents _gaia_usage_pad3 _gaia_usage_capture _gaia_usage_set_branch_key _gaia_usage_hash16 gaia_usage_valid_ref _gaia_usage_load gaia_branch_normalize _gaia_branch_set_normalized gaia_branch_classify _gaia_branch_set_class _gaia_branch_is_members _gaia_branch_is_digits _gaia_branch_set_leading_digits gaia_branch_members _gaia_usage_memo_derive"

_GAIA_USAGE_MEMO_EMPTY='{"bmap":{},"derive":{},"models":[],"stores":{}}'

# The head hash covers at most this many bytes, so a store that grows past it
# keeps matching its recorded hash.
_GAIA_USAGE_MEMO_HEAD_MAX=4096

# shellcheck disable=SC2016  # jq source, no shell expansion
_GAIA_USAGE_MEMO_SHAPE_JQ='
def nn: type == "number" and . >= 0 and . == floor;
def store: type == "object" and (.path | type == "string") and (.off | nn) and (.hn | nn) and (.head | type == "string");
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
def usage_present($urows; $links; $cost):
  [$urows[] | select(.kind == "segment")] as $segs
  | {raws: ([$cost[] | select(.kind == "plan" or .kind == "execute") | .git_branch | strings] | unique),
     bkeys: ([($segs[] | .key), ($links[] | .child, .parent, .key)]
       | map(strings | select(startswith("branch:"))) | unique),
     models: (try ([$segs[] | (.by_model // {}) | keys[]] | unique) catch null)};

# The derive keys the readout needs: every present branch key plus the key of
# each present raw.
def usage_memo_need($present; $memo):
  (($present.bkeys + [$present.raws[] | $memo.bmap[.].key | strings]) | unique);

def usage_memo_gap($present; $memo):
  [$present.raws[] | select($memo.bmap[.] == null)] as $mr
  | [usage_memo_need($present; $memo)[] | select($memo.derive[.] == null)] as $mk
  | ($present.models - $memo.models) as $mm
  | ($memo.models - $present.models) as $mx
  | if ($mr | length) == 0 and ($mk | length) == 0 and ($mm | length) == 0 and ($mx | length) == 0 then null
    else {raws: $mr, bkeys: $mk, models: $mm, models_extra: $mx} end;

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
  local src dir text h
  _gaia_usage_memo_stamp=""
  _gaia_usage_memo_stamp_rc=1
  _gaia_usage_load gaia_branch_classify branch-name-lib.sh 2>/dev/null || return 1
  src="${BASH_SOURCE[0]:-}"
  [ -n "$src" ] || return 1
  case "$src" in */*) dir="${src%/*}" ;; *) dir=. ;; esac
  text="$(awk -v names="$GAIA_USAGE_MEMO_FNS" '
    BEGIN { n = split(names, order, " "); for (i = 1; i <= n; i++) want[order[i]] = 1 }
    cap != "" { body[cap] = body[cap] $0 "\n"; if ($0 == "}") cap = ""; next }
    {
      p = index($0, "() {")
      if (p < 2) next
      nm = substr($0, 1, p - 1)
      if (!(nm in want)) next
      body[nm] = body[nm] $0 "\n"
      if (substr($0, p + 4) == "" || substr($0, length($0)) != "}") cap = nm
    }
    END {
      for (i = 1; i <= n; i++) { nm = order[i]; if (body[nm] == "") bad = 1; printf "%s\n%s", nm, body[nm] }
      exit bad
    }' "$dir/usage-lib.sh" "$dir/usage-resolve-lib.sh" "$dir/branch-name-lib.sh" "$dir/usage-memo-lib.sh" 2>/dev/null)" || return 1
  h="$(_gaia_usage_hash16 "usage-branch-memo/1"$'\n'"$text" 2>/dev/null)" || return 1
  [ -n "$h" ] || return 1
  _gaia_usage_memo_stamp="$h"
  _gaia_usage_memo_stamp_rc=0
  return 0
}

# Reads the stamp a prior gaia_usage_memo_stamp call left; it never computes
# one, so a readout pays for the stamp once.
gaia_usage_memo_load() {
  local memo="$1" header="" body="" extra="" fields="" stamp_h sum_h reason="" us=$'\x1f'
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
    elif [ "${_gaia_usage_memo_stamp_rc:-1}" != 0 ] || [ -z "${_gaia_usage_memo_stamp:-}" ]; then
      reason=stamp-unavailable
    else
      stamp_h="${fields%%"$us"*}"
      sum_h="${fields#*"$us"}"
      if [ "$stamp_h" != "$_gaia_usage_memo_stamp" ]; then
        reason=stamp
      elif [ "$(_gaia_usage_hash16 "$body" 2>/dev/null)" != "$sum_h" ]; then
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
  local f n=0
  while IFS= read -r f; do
    if rm -f "$f" 2>/dev/null; then n=$((n + 1)); fi
  done < <(find "$1" -maxdepth 1 -name '.usage-branch-memo.tmp.*' -type f -mmin +1 2>/dev/null)
  if [ "$n" -gt 0 ]; then gaia_usage_memo_trace "reap=$n"; fi
  return 0
}

# Prints the first <n> bytes' hash. `wc -c` pads under BSD, so callers trim.
_gaia_usage_memo_head_hash() {
  { _gaia_usage_hash16 "$(head -c "$2" "$1")"; } 2>/dev/null
}

# Prints the byte length of the partial last line within the first <snap> bytes
# of <file> (0 when the snapshot ends on a newline). A torn line is left for
# the next read, so an offset is only ever a line boundary.
_gaia_usage_memo_torn_len() {
  local LC_ALL=C
  local f="$1" snap="$2" floor="$3" k chunk
  k=4096
  {
    while :; do
      if [ "$k" -gt "$((snap - floor))" ]; then k="$((snap - floor))"; fi
      [ "$k" -gt 0 ] || { printf '0'; return 0; }
      chunk="$(tail -c "+$((snap - k + 1))" "$f" | head -c "$k"; printf x)"
      chunk="${chunk%x}"
      case "$chunk" in
        *$'\n'*) chunk="${chunk##*$'\n'}"; printf '%s' "${#chunk}"; return 0 ;;
      esac
      if [ "$k" -ge "$((snap - floor))" ]; then printf '%s' "$((snap - floor))"; return 0; fi
      k="$((k * 4))"
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
  local f="$1" start="$2" end="$3" kind="$4" out=""
  case "$kind" in
    c)
      out="$({ _gaia_usage_memo_slice "$f" "$start" "$end"; } 2>/dev/null |
        LC_ALL=C grep -oE '"git_branch":"[^"\\]*"' |
        LC_ALL=C sort -u |
        LC_ALL=C sed 's/^"git_branch":"\(.*\)"$/\1/' |
        jq -Rnc '{k: [], m: [], r: [inputs]}' 2>/dev/null)" || true
      ;;
    l)
      out="$({ _gaia_usage_memo_slice "$f" "$start" "$end"; } 2>/dev/null |
        LC_ALL=C grep -oE '"(key|child|parent)":"branch:[^"\\]*"' |
        LC_ALL=C sort -u |
        LC_ALL=C sed -E 's/^"[a-z]+":"(branch:.*)"$/K\1/' |
        jq -Rnc '[inputs] | {k: [.[] | select(startswith("K")) | .[1:]], m: [], r: []}' 2>/dev/null)" || true
      ;;
    u)
      out="$({ _gaia_usage_memo_slice "$f" "$start" "$end"; } 2>/dev/null |
        LC_ALL=C grep -oE -e '"(key|child|parent)":"branch:[^"\\]*"' -e '("by_model":\{|\},)"[^"\\]*":\{"fresh_input":' |
        LC_ALL=C sort -u |
        LC_ALL=C sed -nE 's/^"(key|child|parent)":"(branch:.*)"$/K\2/p; s/^.*"([^"\\]*)":\{"fresh_input":$/M\1/p' |
        jq -Rnc '[inputs] | {k: [.[] | select(startswith("K")) | .[1:]], m: [.[] | select(startswith("M")) | .[1:]], r: []}' 2>/dev/null)" || true
      ;;
  esac
  case "$out" in '{'*) printf '%s' "$out" ;; *) return 1 ;; esac
}

# _gaia_usage_memo_derive <agg>: <agg> is {k: [branch keys], r: [raw branches]}.
# Derives what GAIA_USAGE_MEMO lacks and merges it in: new raws through
# gaia_usage_branch_map, then every key not yet in `derive` (the given keys plus
# each new raw's key) through gaia_usage_derive_map, recording [] for a key that
# implies no parent so it counts as processed. Lists cross to bash NUL-delimited
# because a raw can legitimately be the empty string.
_gaia_usage_memo_derive() {
  local agg="$1" x newbmap="{}" dm="{}" merged
  local -a ra=() ka=()
  while IFS= read -r -d '' x; do ra[${#ra[@]}]="$x"; done < <(
    printf '%s\n%s\n' "$GAIA_USAGE_MEMO" "$agg" |
      jq -j -n 'input as $m | input as $a | $a.r | unique | .[] | select($m.bmap[.] == null) | ., "\u0000"' 2>/dev/null)
  if [ "${#ra[@]}" -gt 0 ]; then
    newbmap="$(gaia_usage_branch_map ${ra[@]+"${ra[@]}"} 2>/dev/null)" || return 1
  fi
  while IFS= read -r -d '' x; do ka[${#ka[@]}]="$x"; done < <(
    printf '%s\n%s\n%s\n' "$GAIA_USAGE_MEMO" "$agg" "$newbmap" |
      jq -j -n 'input as $m | input as $a | input as $nb
        | ($a.k + [$nb[].key | strings]) | unique | .[] | select($m.derive[.] == null) | ., "\u0000"' 2>/dev/null)
  if [ "${#ka[@]}" -gt 0 ]; then
    dm="$(gaia_usage_derive_map ${ka[@]+"${ka[@]}"} 2>/dev/null)" || return 1
  fi
  merged="$(printf '%s\n%s\n%s\n%s\n' "$GAIA_USAGE_MEMO" "$agg" "$newbmap" "$dm" |
    jq -cS -n 'input as $m | input as $a | input as $nb | input as $dm
      | (($a.k + [$nb[].key | strings]) | unique | map(select($m.derive[.] == null))) as $nk
      | $m | .bmap += $nb | .derive += ($nk | map({key: ., value: ($dm[.] // [])}) | from_entries)' 2>/dev/null)" || return 1
  [ -n "$merged" ] || return 1
  GAIA_USAGE_MEMO="$merged"
}

# Warms GAIA_USAGE_MEMO from the bytes each store gained since the memo last
# looked. A store whose recorded path, size floor, or first bytes no longer
# match is scanned in full. A rewrite that keeps the size at or above the
# recorded offset and the first bytes unchanged goes undetected here on purpose:
# the readout's coverage check derives whatever the rewritten rows name.
gaia_usage_memo_warm() {
  local before t f rec rp ro rh rhead snap start newoff reason torn hn hhash scan
  local full_u=0 any=0 us=$'\x1f' recs="" agg models new
  [ -n "${GAIA_USAGE_MEMO:-}" ] || GAIA_USAGE_MEMO="$_GAIA_USAGE_MEMO_EMPTY"
  before="$GAIA_USAGE_MEMO"
  recs="$(jq -r '.stores as $s | ("u", "l", "c") | ($s[.] // null)
      | if . == null then "-" else "\(.path)\u001f\(.off)\u001f\(.hn)\u001f\(.head)" end' <<<"$GAIA_USAGE_MEMO" 2>/dev/null)" || recs=""
  local rec_u rec_l rec_c
  { IFS= read -r rec_u; IFS= read -r rec_l; IFS= read -r rec_c; } <<<"$recs" || true
  local scan_u="" scan_l="" scan_c="" upd_u="" upd_l="" upd_c=""
  for t in u l c; do
    case "$t" in
      u) f="$1"; rec="${rec_u:--}" ;;
      l) f="$2"; rec="${rec_l:--}" ;;
      c) f="$3"; rec="${rec_c:--}" ;;
    esac
    [ -f "$f" ] && [ -r "$f" ] || continue
    snap="$(wc -c <"$f" 2>/dev/null)" || continue
    snap="${snap//[[:space:]]/}"
    case "$snap" in '' | *[!0-9]*) continue ;; esac
    start=0
    reason=new
    rp="" ro=0 rh=0 rhead=""
    if [ "$rec" != "-" ]; then
      IFS="$us" read -r rp ro rh rhead <<<"$rec"
      case "$ro$rh" in '' | *[!0-9]*) rp="" ;; esac
      if [ "$rp" != "$f" ]; then
        reason=path
      elif [ "$snap" -lt "$ro" ]; then
        reason=shrunk
      elif [ "$(_gaia_usage_memo_head_hash "$f" "$rh")" != "$rhead" ]; then
        reason="head"
      else
        reason=""
        start="$ro"
      fi
    fi
    torn="$(_gaia_usage_memo_torn_len "$f" "$snap" "$start")" || torn=0
    case "$torn" in '' | *[!0-9]*) torn=0 ;; esac
    newoff="$((snap - torn))"
    if [ -z "$reason" ]; then
      [ "$newoff" -gt "$start" ] || continue
    else
      gaia_usage_memo_trace "scan=full store=$t reason=$reason"
    fi
    if [ "$newoff" -gt "$start" ]; then
      scan="$(_gaia_usage_memo_scan "$f" "$start" "$newoff" "$t")" || continue
    else
      scan='{"k":[],"m":[],"r":[]}'
    fi
    hn="$newoff"
    [ "$hn" -le "$_GAIA_USAGE_MEMO_HEAD_MAX" ] || hn="$_GAIA_USAGE_MEMO_HEAD_MAX"
    if [ -z "$reason" ] && [ "$rh" = "$hn" ]; then
      hhash="$rhead"
    else
      hhash="$(_gaia_usage_memo_head_hash "$f" "$hn")" || continue
    fi
    new="$(jq -nc --arg p "$f" --argjson o "$newoff" --argjson h "$hn" --arg d "$hhash" '{path: $p, off: $o, hn: $h, head: $d}' 2>/dev/null)" || continue
    case "$t" in
      u) scan_u="$scan"; upd_u="$new"; [ -n "$reason" ] && full_u=1 ;;
      l) scan_l="$scan"; upd_l="$new" ;;
      c) scan_c="$scan"; upd_c="$new" ;;
    esac
    any=1
  done
  [ "$any" = 1 ] || return 0
  agg="$(printf '%s\n%s\n%s\n' "$scan_u" "$scan_l" "$scan_c" |
    jq -cn '[inputs] | {k: (map(.k) | add // [] | unique), r: (map(.r) | add // [] | unique)}' 2>/dev/null)" || agg=""
  [ -n "$agg" ] || return 0
  if ! _gaia_usage_memo_derive "$agg"; then
    # Offsets stay where they were, so the next read scans these bytes again.
    GAIA_USAGE_MEMO="$before"
    return 0
  fi
  models="[]"
  if [ -n "$scan_u" ]; then models="$(jq -c '.m' <<<"$scan_u" 2>/dev/null)" || models="[]"; fi
  new="$(printf '%s\n%s\n%s\n%s\n' "$GAIA_USAGE_MEMO" "${upd_u:-null}" "${upd_l:-null}" "${upd_c:-null}" |
    jq -cS -n --argjson m "$models" --argjson full "$full_u" --argjson hasu "$([ -n "$scan_u" ] && echo true || echo false)" '
      input as $memo | input as $u | input as $l | input as $c
      | $memo
      | (if $u != null then .stores.u = $u else . end)
      | (if $l != null then .stores.l = $l else . end)
      | (if $c != null then .stores.c = $c else . end)
      | if $hasu then .models = (if $full == 1 then $m else (.models + $m) end | unique) else . end' 2>/dev/null)" || new=""
  [ -n "$new" ] && GAIA_USAGE_MEMO="$new"
  if [ "$GAIA_USAGE_MEMO" != "$before" ]; then GAIA_USAGE_MEMO_DIRTY=1; fi
  return 0
}

# Merges a coverage gap ({raws, bkeys, models, models_extra}) into the memo, so
# the memo ends covering exactly the present set.
gaia_usage_memo_merge_gap() {
  local gap="$1" before="${GAIA_USAGE_MEMO:-}" agg new
  [ -n "$before" ] || { GAIA_USAGE_MEMO="$_GAIA_USAGE_MEMO_EMPTY"; before="$GAIA_USAGE_MEMO"; }
  agg="$(jq -c '{k: (.bkeys // []), r: (.raws // [])}' <<<"$gap" 2>/dev/null)" || return 0
  [ -n "$agg" ] || return 0
  _gaia_usage_memo_derive "$agg" || GAIA_USAGE_MEMO="$before"
  new="$(printf '%s\n%s\n' "$GAIA_USAGE_MEMO" "$gap" |
    jq -cS -n 'input as $m | input as $g
      | $m | .models = (((.models - ($g.models_extra // [])) + ($g.models // [])) | unique)' 2>/dev/null)" || new=""
  [ -n "$new" ] && GAIA_USAGE_MEMO="$new"
  if [ "$GAIA_USAGE_MEMO" != "$before" ]; then GAIA_USAGE_MEMO_DIRTY=1; fi
  return 0
}

# Temp then rename, never in place and never under the ledger mutex: a reader
# sees the old memo or the new one, and a failed write leaves the readout on
# its in-memory memo.
gaia_usage_memo_save() {
  local memo="$1" dir tmp sum
  if [ "${_gaia_usage_memo_stamp_rc:-1}" != 0 ] || [ -z "${_gaia_usage_memo_stamp:-}" ]; then
    gaia_usage_memo_trace "write=skip"
    return 0
  fi
  case "$memo" in */*) dir="${memo%/*}" ;; *) dir=. ;; esac
  tmp="$(mktemp "$dir/.usage-branch-memo.tmp.XXXXXX" 2>/dev/null)" || tmp=""
  if [ -z "$tmp" ]; then gaia_usage_memo_trace "write=fail"; return 0; fi
  sum="$(_gaia_usage_hash16 "${GAIA_USAGE_MEMO:-}" 2>/dev/null)" || sum=""
  if [ -n "$sum" ] && [ -n "${GAIA_USAGE_MEMO:-}" ] &&
    printf '{"schema_version":1,"stamp":"%s","sum":"%s"}\n%s\n' "$_gaia_usage_memo_stamp" "$sum" "$GAIA_USAGE_MEMO" 2>/dev/null >"$tmp" &&
    mv -f "$tmp" "$memo" 2>/dev/null; then
    GAIA_USAGE_MEMO_DIRTY=0
    gaia_usage_memo_trace "write=ok"
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  gaia_usage_memo_trace "write=fail"
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
