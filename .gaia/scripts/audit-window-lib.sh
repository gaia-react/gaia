# shellcheck shell=bash
# GAIA shared audit-window lib (SPEC-032 FC-5, single-sourced).
#
# Sourced by token-tally.sh to bracket adversarial-audit and code-review-audit
# spend by TIME WINDOW rather than by agentType: a Deep spec audit spans
# lenses + refuters + completeness + applier (all `general-purpose`), and a
# code-review-audit run spawns other-typed sub-agents, so a single-agentType
# filter would under-count both. Windows are computed over token-tally's
# per-file record stream: one JSON object per line, each
#   { usage: [ {id, u, m} ], tmin, tmax, file_agent, file_id }
# where `file_agent` is "main" for the main transcript or the sidecar's
# agentType, and `file_id` is the sidecar basename (agent-<hash>) or "" for
# main. No side effects at source time; defines functions only. The read/query
# functions return 0 and degrade to empty / {} / [] on any failure -- never
# blocking the caller, never fabricating a figure. The one writer,
# gaia_audit_window_write, instead PROPAGATES failure (non-zero when it wrote
# nothing) so a lost breadcrumb is detectable; its callers guard with `|| true`
# so that too never blocks.
#
# Timestamp precision (COV-003): a breadcrumb's started_at/ended_at are
# written at SECOND precision (date -u +%Y-%m-%dT%H:%M:%SZ) while sidecar
# tmin/tmax carry FRACTIONAL seconds. A raw string compare sorts
# "HH:MM:SS.fffZ" BEFORE "HH:MM:SSZ" ("." (0x2E) < "Z" (0x5A)), wrongly
# excluding a sidecar that started in the same second as the window start.
# Every containment compare below strips `\.[0-9]+Z$` -> `Z` on BOTH sides
# first (the same normalization the elapsed_seconds computation already
# applies), so a lexical ...Z string compare is chronologically correct. Each
# jq program below defines its own local `norm` filter (never string-
# interpolated across functions) so a bash-side interpolation mistake can
# never silently corrupt the jq program text.
#
# Sidecar-only lower bound (DP-003 / COV-005): gaia_window_subset sums
# DISPATCHED sidecars only (file_agent != "main"). An audit sub-agent that
# runs main-inline (an applier / refuter / completeness fold in the main
# transcript, the documented inline_fallback path) lands its tokens under
# file_agent == "main" and is intentionally excluded, so the recorded
# subtotal is a LOWER BOUND of the audited unit on that path. This is by
# design (inline != dispatched); it is not a bug to fix.

# gaia_audit_window_read <breadcrumb_path>
# Echoes the breadcrumb JSON (single compact line) iff the file exists and
# parses as a JSON object carrying string started_at and string ended_at;
# otherwise echoes nothing. Never errors, always returns 0.
gaia_audit_window_read() {
  local path="${1:-}"
  [[ -n "$path" && -f "$path" ]] || return 0
  local content
  content="$(cat "$path" 2>/dev/null)" || return 0
  [[ -z "$content" ]] && return 0
  if jq -e 'type == "object" and (.started_at | type) == "string" and (.ended_at | type) == "string"' \
      >/dev/null 2>&1 <<<"$content"; then
    jq -c '.' 2>/dev/null <<<"$content"
  fi
  return 0
}

# gaia_window_subset <records_file> <started_at> <ended_at>
# Selects sidecar records (file_agent != "main") whose tmin/tmax both fall
# within [started_at, ended_at] (inclusive, precision-normalized), dedupes
# their usage entries by .id (last-wins, same as token-tally's aggregate),
# and echoes one JSON object:
#   { count, buckets: {fresh_input,cache_write,cache_read,output},
#     by_model: {...}, elapsed_seconds }
# count is the number of selected sidecar FILES (0 when none in window).
# elapsed_seconds = max(tmax) - min(tmin) over selected files, jq-only
# (fromdateiso8601, never the `date` binary). Degrades to a zero-filled
# object on any malformed/empty input or unparseable timestamp.
gaia_window_subset() {
  local records_file="${1:-}" started_at="${2:-}" ended_at="${3:-}"
  local zero='{"count":0,"buckets":{"fresh_input":0,"cache_write":0,"cache_read":0,"output":0},"by_model":{},"elapsed_seconds":0}'
  if [[ -z "$records_file" || ! -f "$records_file" ]]; then
    printf '%s' "$zero"
    return 0
  fi
  local out
  out="$(jq -cs --arg ws "$started_at" --arg we "$ended_at" '
    def norm: if type=="string" then sub("\\.[0-9]+Z$"; "Z") else . end;
    ($ws | norm) as $s
    | ($we | norm) as $e
    | ( map(select((.file_agent // "main") != "main"))
        | map(select(.tmin != null and .tmax != null))
        | map(. + {ntmin: (.tmin | norm), ntmax: (.tmax | norm)})
        | map(select(.ntmin >= $s and .ntmax <= $e))
      ) as $sel
    | ($sel | length) as $count
    | ($sel | map(.usage // []) | add // []) as $allusage
    | ($allusage | reduce .[] as $x ({}; .[$x.id] = {u: $x.u, m: $x.m}) | [.[]]) as $u
    | {
        count: $count,
        buckets: {
          fresh_input: ($u | map(.u.input_tokens // 0) | add // 0),
          cache_write: ($u | map(
              (.u.cache_creation.ephemeral_5m_input_tokens // 0)
              + (.u.cache_creation.ephemeral_1h_input_tokens // (.u.cache_creation_input_tokens // 0))
            ) | add // 0),
          cache_read: ($u | map(.u.cache_read_input_tokens // 0) | add // 0),
          output: ($u | map(.u.output_tokens // 0) | add // 0)
        },
        by_model: (
          ($u | map(select(.m != null and .m != "")))
          | group_by(.m)
          | map({
              key: .[0].m,
              value: (reduce .[] as $r (
                {fresh_input: 0, cache_write_5m: 0, cache_write_1h: 0, cache_read: 0, output: 0};
                .fresh_input      += ($r.u.input_tokens // 0)
                | .cache_write_5m += ($r.u.cache_creation.ephemeral_5m_input_tokens // 0)
                | .cache_write_1h += ($r.u.cache_creation.ephemeral_1h_input_tokens // ($r.u.cache_creation_input_tokens // 0))
                | .cache_read     += ($r.u.cache_read_input_tokens // 0)
                | .output         += ($r.u.output_tokens // 0)
              ))
            })
          | map(select(([.value[]] | add) > 0))
          | from_entries
        ),
        elapsed_seconds: (
          if $count == 0 then 0
          else
            ( try (
                ($sel | map(.ntmax | fromdateiso8601) | max)
                - ($sel | map(.ntmin | fromdateiso8601) | min)
              ) catch 0 )
          end
        )
      }
  ' "$records_file" 2>/dev/null)"
  if [[ -n "$out" ]] && jq -e 'type == "object" and has("count")' >/dev/null 2>&1 <<<"$out"; then
    printf '%s' "$out"
  else
    printf '%s' "$zero"
  fi
  return 0
}

# gaia_audit_window_write <breadcrumb_path> <session_id> <started_at> <ended_at> <lenses_json> [intensity]
# The single breadcrumb writer (DP-001). Writes the FC-1 breadcrumb JSON to
# <breadcrumb_path> via `jq -n` (never string-concatenated), omitting the
# `intensity` key entirely when the 6th arg is empty/absent (plan audits).
# The JSON is built in a variable first (nothing touches disk until it
# validates), so an invalid <lenses_json> or a jq failure leaves no partial
# file; an unwritable target path likewise writes nothing.
#
# Unlike the read/query helpers above, this writer PROPAGATES failure: it
# returns 0 only when a valid breadcrumb reached disk, and non-zero (with a
# diagnostic on stderr) when it wrote nothing -- an empty target path, jq
# absent from PATH, a jq failure / empty or non-object JSON, or an unwritable
# target. jq's stderr flows through rather than being discarded, so the real
# cause surfaces. This makes a lost breadcrumb detectable and unit-testable
# rather than silently swallowed. Callers guard the call with `|| true`, so a
# non-zero return still
# never blocks them; it just stops converting a recoverable error into silent
# data loss.
gaia_audit_window_write() {
  local path="${1:-}" session_id="${2:-}" started_at="${3:-}" ended_at="${4:-}" lenses_json="${5:-}" intensity="${6:-}"
  if [[ -z "$path" ]]; then
    printf 'gaia_audit_window_write: no breadcrumb path given; nothing written\n' >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'gaia_audit_window_write: jq not found on PATH; breadcrumb %s not written\n' "$path" >&2
    return 1
  fi
  local json
  if [[ -z "$intensity" ]]; then
    json="$(jq -n --arg sid "$session_id" --arg st "$started_at" --arg en "$ended_at" --argjson lenses "$lenses_json" '
      {session_id: $sid, started_at: $st, ended_at: $en, lenses: $lenses}
    ')" || json=""
  else
    json="$(jq -n --arg sid "$session_id" --arg st "$started_at" --arg en "$ended_at" --argjson lenses "$lenses_json" --arg it "$intensity" '
      {session_id: $sid, started_at: $st, ended_at: $en, lenses: $lenses, intensity: $it}
    ')" || json=""
  fi
  if [[ -z "$json" ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json"; then
    printf 'gaia_audit_window_write: could not build a valid breadcrumb for %s; nothing written\n' "$path" >&2
    return 1
  fi
  if ! printf '%s\n' "$json" >"$path" 2>/dev/null; then
    printf 'gaia_audit_window_write: cannot write breadcrumb to %s\n' "$path" >&2
    return 1
  fi
  return 0
}

# gaia_review_windows <records_file>
# Echoes a JSON array, one entry per record with file_agent ==
# "code-review-audit": [ { review_id, started_at, ended_at }, ... ].
# review_id is the record's file_id. Echoes "[]" when none, and on any
# malformed/empty/missing input.
gaia_review_windows() {
  local records_file="${1:-}"
  local empty='[]'
  if [[ -z "$records_file" || ! -f "$records_file" ]]; then
    printf '%s' "$empty"
    return 0
  fi
  local out
  out="$(jq -cs '
    map(select((.file_agent // "") == "code-review-audit"))
    | map({review_id: (.file_id // ""), started_at: .tmin, ended_at: .tmax})
  ' "$records_file" 2>/dev/null)"
  if [[ -n "$out" ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out"; then
    printf '%s' "$out"
  else
    printf '%s' "$empty"
  fi
  return 0
}

# gaia_exclude_review_windows <records_file>
# Echoes the record stream (JSON lines) with every record whose [tmin, tmax]
# is a subset of ANY code-review-audit window removed (including the
# code-review-audit records themselves). Used by a phase tally to strip a
# review run's spend out of the phase buckets before aggregating (double-
# count guard). A byte no-op when no code-review-audit record is present
# (the file is `cat`, never re-serialized through jq). Degrades to the raw
# input on any parse failure -- never blocks, never drops the stream.
gaia_exclude_review_windows() {
  local records_file="${1:-}"
  [[ -z "$records_file" || ! -f "$records_file" ]] && return 0
  local review_count
  review_count="$(jq -sc '[.[] | select((.file_agent // "") == "code-review-audit")] | length' "$records_file" 2>/dev/null)"
  if ! [[ "$review_count" =~ ^[1-9][0-9]*$ ]]; then
    cat "$records_file" 2>/dev/null
    return 0
  fi
  jq -rs '
    def norm: if type=="string" then sub("\\.[0-9]+Z$"; "Z") else . end;
    def contained($s; $e; $windows): $windows | any(.s <= $s and $e <= .e);
    . as $all
    | ( [ $all[]
          | select((.file_agent // "") == "code-review-audit" and .tmin != null and .tmax != null)
          | {s: (.tmin | norm), e: (.tmax | norm)}
        ] ) as $windows
    | $all
    | map(select((.file_agent // "") != "code-review-audit"))
    | map(select(
        (.tmin == null or .tmax == null)
        or ( (.tmin | norm) as $s | (.tmax | norm) as $e | (contained($s; $e; $windows) | not) )
      ))
    | .[]
    | tojson
  ' "$records_file" 2>/dev/null || cat "$records_file" 2>/dev/null
  return 0
}
