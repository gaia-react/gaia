# shellcheck shell=bash
# GAIA shared audit-window lib (single-sourced).
#
# Sourced by token-tally.sh to bracket adversarial-audit and Code Audit Team
# spend by TIME WINDOW rather than by agentType: a Deep spec audit spans
# lenses + refuters + completeness + applier (all `general-purpose`), and a
# Code Audit Team member can spawn other-typed sub-agents, so a single-agentType
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
# jq program below defines its own local `normalize` filter (never string-
# interpolated across functions) so a bash-side interpolation mistake can
# never silently corrupt the jq program text.
#
# Sidecar-only lower bound (DP-003 / COV-005): gaia_window_subset sums
# DISPATCHED sidecars only (file_agent != "main"). An audit sub-agent that
# runs main-inline (an applier / refuter / completeness fold in the main
# transcript) lands its tokens under file_agent == "main" and is
# intentionally excluded, so the recorded subtotal is a LOWER BOUND of the
# audited unit on that path. This is by design (inline != dispatched); it is
# not a bug to fix.

# gaia_audit_window_read <breadcrumb_path>
# Echoes the breadcrumb JSON (single compact line) iff the file exists and
# parses as a JSON object carrying string started_at and string ended_at;
# otherwise echoes nothing. Never errors, always returns 0.
gaia_audit_window_read() {
  local breadcrumb_path="${1:-}"
  [[ -n "$breadcrumb_path" && -f "$breadcrumb_path" ]] || return 0
  local content
  content="$(cat "$breadcrumb_path" 2>/dev/null)" || return 0
  [[ -z "$content" ]] && return 0
  if jq -e 'type == "object" and (.started_at | type) == "string" and (.ended_at | type) == "string"' \
      >/dev/null 2>&1 <<<"$content"; then
    jq -c '.' 2>/dev/null <<<"$content"
  fi
  return 0
}

# gaia_window_subset <records_file> <started_at> <ended_at> [file_ids_json]
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
  local records_file="${1:-}" started_at="${2:-}" ended_at="${3:-}" file_ids="${4:-}"
  local zero='{"count":0,"buckets":{"fresh_input":0,"cache_write":0,"cache_read":0,"output":0},"by_model":{},"elapsed_seconds":0}'
  if [[ -z "$records_file" || ! -f "$records_file" ]]; then
    printf '%s' "$zero"
    return 0
  fi
  # The optional 4th arg, a JSON array of file_ids (gaia_review_windows'
  # partition), narrows the time-range selection to exactly those sidecars.
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$file_ids" || file_ids="null"
  local subset_output
  subset_output="$(jq -cs --arg started_at "$started_at" --arg ended_at "$ended_at" --argjson file_ids "$file_ids" '
    def normalize: if type=="string" then sub("\\.[0-9]+Z$"; "Z") else . end;
    ($started_at | normalize) as $normalized_start
    | ($ended_at | normalize) as $normalized_end
    | ( map(select((.file_agent // "main") != "main"))
        | map(select(.tmin != null and .tmax != null))
        | map(. + {normalized_tmin: (.tmin | normalize), normalized_tmax: (.tmax | normalize)})
        | map(select(.normalized_tmin >= $normalized_start and .normalized_tmax <= $normalized_end))
        | if $file_ids == null then . else map(select((.file_id // "") as $record_file_id | any($file_ids[]; . == $record_file_id))) end
      ) as $selected
    | ($selected | length) as $count
    | ($selected | map(.usage // []) | add // []) as $all_usage
    | ($all_usage | reduce .[] as $usage_entry ({}; .[$usage_entry.id] = {u: $usage_entry.u, m: $usage_entry.m}) | [.[]]) as $usage_entries
    | {
        count: $count,
        buckets: {
          fresh_input: ($usage_entries | map(.u.input_tokens // 0) | add // 0),
          cache_write: ($usage_entries | map(
              (.u.cache_creation.ephemeral_5m_input_tokens // 0)
              + (.u.cache_creation.ephemeral_1h_input_tokens // (.u.cache_creation_input_tokens // 0))
            ) | add // 0),
          cache_read: ($usage_entries | map(.u.cache_read_input_tokens // 0) | add // 0),
          output: ($usage_entries | map(.u.output_tokens // 0) | add // 0)
        },
        by_model: (
          ($usage_entries | map(select(.m != null and .m != "")))
          | group_by(.m)
          | map({
              key: .[0].m,
              value: (reduce .[] as $model_entry (
                {fresh_input: 0, cache_write_5m: 0, cache_write_1h: 0, cache_read: 0, output: 0};
                .fresh_input      += ($model_entry.u.input_tokens // 0)
                | .cache_write_5m += ($model_entry.u.cache_creation.ephemeral_5m_input_tokens // 0)
                | .cache_write_1h += ($model_entry.u.cache_creation.ephemeral_1h_input_tokens // ($model_entry.u.cache_creation_input_tokens // 0))
                | .cache_read     += ($model_entry.u.cache_read_input_tokens // 0)
                | .output         += ($model_entry.u.output_tokens // 0)
              ))
            })
          | map(select(([.value[]] | add) > 0))
          | from_entries
        ),
        elapsed_seconds: (
          if $count == 0 then 0
          else
            ( try (
                ($selected | map(.normalized_tmax | fromdateiso8601) | max)
                - ($selected | map(.normalized_tmin | fromdateiso8601) | min)
              ) catch 0 )
          end
        )
      }
  ' "$records_file" 2>/dev/null)"
  if [[ -n "$subset_output" ]] && jq -e 'type == "object" and has("count")' >/dev/null 2>&1 <<<"$subset_output"; then
    printf '%s' "$subset_output"
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
  local breadcrumb_path="${1:-}" session_id="${2:-}" started_at="${3:-}" ended_at="${4:-}" lenses_json="${5:-}" intensity="${6:-}"
  if [[ -z "$breadcrumb_path" ]]; then
    printf 'gaia_audit_window_write: no breadcrumb path given; nothing written\n' >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf 'gaia_audit_window_write: jq not found on PATH; breadcrumb %s not written\n' "$breadcrumb_path" >&2
    return 1
  fi
  local json
  if [[ -z "$intensity" ]]; then
    json="$(jq -n --arg session_id "$session_id" --arg started_at "$started_at" --arg ended_at "$ended_at" --argjson lenses "$lenses_json" '
      {session_id: $session_id, started_at: $started_at, ended_at: $ended_at, lenses: $lenses}
    ')" || json=""
  else
    json="$(jq -n --arg session_id "$session_id" --arg started_at "$started_at" --arg ended_at "$ended_at" --argjson lenses "$lenses_json" --arg intensity "$intensity" '
      {session_id: $session_id, started_at: $started_at, ended_at: $ended_at, lenses: $lenses, intensity: $intensity}
    ')" || json=""
  fi
  if [[ -z "$json" ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json"; then
    printf 'gaia_audit_window_write: could not build a valid breadcrumb for %s; nothing written\n' "$breadcrumb_path" >&2
    return 1
  fi
  if ! printf '%s\n' "$json" >"$breadcrumb_path" 2>/dev/null; then
    printf 'gaia_audit_window_write: cannot write breadcrumb to %s\n' "$breadcrumb_path" >&2
    return 1
  fi
  return 0
}

# _gaia_review_agents_json
# Echoes a JSON array of the agentTypes that count as a code-review-audit run:
# every member on this checkout's .gaia/audit-ci.yml roster, since the merge
# gate can dispatch any of them without the default member. Rooted at this
# file rather than the working directory, so a tally run from a sibling tree
# reads the roster that shipped with this lib. An unreadable roster degrades to
# the default member's name alone, the member the gate falls back to spawning.
_gaia_review_agents_json() {
  local library_directory names=""
  library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || library_directory=""
  if [[ -n "$library_directory" ]] && . "$library_directory/../../.claude/hooks/lib/audit-scope.sh" 2>/dev/null; then
    names="$(audit_roster_member_names "$library_directory/../audit-ci.yml" 2>/dev/null)" || names=""
  fi
  [[ -n "$names" ]] || names="code-audit-frontend"
  jq -Rnc '[inputs | select(length > 0)]' <<<"$names" 2>/dev/null || printf '%s' '["code-audit-frontend"]'
}

# gaia_review_windows <records_file>
# Echoes a JSON array, one entry per record whose file_agent is a Code Audit
# Team member (_gaia_review_agents_json):
#   [ { review_id, started_at, ended_at, file_ids }, ... ]
# review_id is the record's file_id. file_ids PARTITIONS the non-main sidecars
# across the windows: a member's own record goes to its own window, and any
# other sidecar contained in one or more windows goes to the tightest of them
# (earliest in record order on a tie). The merge gate dispatches its members
# as one parallel wave, so their windows nest; pricing each window by time
# range alone would count a nested member's spend in its own row and again in
# every sibling row containing it. The tightest-window rule can attribute a
# sub-agent to the wrong member when windows nest, but never to two, so the
# rows always sum to the wave's real spend.
# Echoes "[]" when none, and on any malformed/empty/missing input.
gaia_review_windows() {
  local records_file="${1:-}"
  local empty='[]'
  if [[ -z "$records_file" || ! -f "$records_file" ]]; then
    printf '%s' "$empty"
    return 0
  fi
  local windows_output agents
  agents="$(_gaia_review_agents_json)"
  windows_output="$(jq -cs --argjson agents "$agents" '
    def normalize: if type=="string" then sub("\\.[0-9]+Z$"; "Z") else . end;
    def span: try ((.normalized_end | fromdateiso8601) - (.normalized_start | fromdateiso8601)) catch 0;
    . as $all
    | [ $all[]
        | select((.file_agent // "") as $agent | any($agents[]; . == $agent))
        | {review_id: (.file_id // ""), started_at: .tmin, ended_at: .tmax,
           normalized_start: (.tmin | normalize), normalized_end: (.tmax | normalize)}
      ] as $review_windows
    | [ $all[]
        | select((.file_agent // "main") != "main" and .tmin != null and .tmax != null)
        | (.file_id // "") as $file_id
        | (.tmin | normalize) as $normalized_start
        | (.tmax | normalize) as $normalized_end
        | ( [ $review_windows[] | select(.normalized_start != null and .normalized_end != null and .normalized_start <= $normalized_start and $normalized_end <= .normalized_end) ]
            | if length == 0 then empty
              elif any(.[]; .review_id == $file_id) then $file_id
              else (sort_by(span) | .[0].review_id)
              end
          ) as $assigned_review_id
        | {file_id: $file_id, assigned_review_id: $assigned_review_id}
      ] as $assign
    | $review_windows
    | map(.review_id as $review_id
          | {review_id, started_at, ended_at,
             file_ids: [ $assign[] | select(.assigned_review_id == $review_id) | .file_id ]})
  ' "$records_file" 2>/dev/null)"
  if [[ -n "$windows_output" ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$windows_output"; then
    printf '%s' "$windows_output"
  else
    printf '%s' "$empty"
  fi
  return 0
}

# gaia_exclude_review_windows <records_file>
# Echoes the record stream (JSON lines) with every record whose [tmin, tmax]
# is a subset of ANY Code Audit Team member's window removed (including the
# member records themselves). Used by a phase tally to strip a review run's
# spend out of the phase buckets before aggregating (double-count guard). A
# byte no-op when no member record is present (the file is `cat`, never
# re-serialized through jq). Degrades to the raw input on any parse failure --
# never blocks, never drops the stream.
gaia_exclude_review_windows() {
  local records_file="${1:-}"
  [[ -z "$records_file" || ! -f "$records_file" ]] && return 0
  local review_count agents
  agents="$(_gaia_review_agents_json)"
  review_count="$(jq -sc --argjson agents "$agents" '[.[] | select((.file_agent // "") as $agent | any($agents[]; . == $agent))] | length' "$records_file" 2>/dev/null)"
  if ! [[ "$review_count" =~ ^[1-9][0-9]*$ ]]; then
    cat "$records_file" 2>/dev/null
    return 0
  fi
  jq -rs --argjson agents "$agents" '
    def normalize: if type=="string" then sub("\\.[0-9]+Z$"; "Z") else . end;
    def contained($normalized_start; $normalized_end; $windows): $windows | any(.normalized_start <= $normalized_start and $normalized_end <= .normalized_end);
    def member: (.file_agent // "") as $agent | any($agents[]; . == $agent);
    . as $all
    | ( [ $all[]
          | select(member and .tmin != null and .tmax != null)
          | {normalized_start: (.tmin | normalize), normalized_end: (.tmax | normalize)}
        ] ) as $windows
    | $all
    | map(select(member | not))
    | map(select(
        (.tmin == null or .tmax == null)
        or ( (.tmin | normalize) as $normalized_start | (.tmax | normalize) as $normalized_end | (contained($normalized_start; $normalized_end; $windows) | not) )
      ))
    | .[]
    | tojson
  ' "$records_file" 2>/dev/null || cat "$records_file" 2>/dev/null
  return 0
}
