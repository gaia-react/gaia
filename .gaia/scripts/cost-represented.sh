#!/usr/bin/env bash
# cost-represented.sh: value-aware, fail-closed representation gate.
#
# Public function (sourced by every forward-delete path and the one-time
# backlog migration):
#
#   cost_folder_represented <folder_absolute_path> <attribute_field> <attribute_value> <ledger_path>
#
# It answers one question: is every cost phase record under <folder_absolute_path>
# provably captured in <ledger_path> (cost.jsonl) with matching values? It is
# the guard that authorizes deleting a folder, so it is deliberately strict.
#
#   <folder_absolute_path>   absolute path to the folder whose deletion is being gated.
#   <attribute_field>   the identity field every row for this folder carries, one of
#                  spec_id | plan_id | plan_slug.
#   <attribute_value>     the identity value (a spec id, or a plan id / slug).
#   <ledger_path>  absolute path to cost.jsonl. The caller resolves the
#                  main-checkout ledger; tests pass an isolated one.
#
# Source precedence, per folder tree (`find -maxdepth 2`, folder root and one
# level down for a colocated plan / plan-<N> subfolder):
#
#   cost.json present   drive the gate from the sidecar(s). Each sidecar is a
#                        JSON object keyed by phase kind; a sidecar that fails
#                        to parse as an object is an unparseable sidecar and
#                        BLOCKS, never silently skipped.
#   cost.json absent     return 0 (nothing to lose).
#
# Whichever source wins, each discovered record classifies as:
#
#   REPRESENTED  the four buckets are present-and-numeric AND the ledger holds a
#                JSON-object row with the same identity, kind, and session, whose
#                four bucket values match or whose total equals the section sum.
#   BLOCKING     the record's buckets are missing / non-numeric (fail closed),
#                the sidecar itself is unparseable, or no matching ledger row
#                exists.
#
# Output: one manifest line per discovered section on stdout, tab-separated:
#
#   <kind>\t<REPRESENTED|BLOCKING>\t<reason>
#
# Diagnostics go to stderr. Return code: 0 iff every discovered section is
# REPRESENTED. A folder with neither source and no recognized section returns 0
# (nothing to lose; the caller owns the separate identity check). Returns 1 if
# any section is BLOCKING.
#
# Read-only and side-effect free: it never writes the ledger and never touches
# the folder, so a fail-open advisory caller can always call it safely. No
# `set -e`; each step is guarded. Sourced with no top-level side effects; also
# directly runnable for its test suite.

if ! declare -f cost_folder_represented >/dev/null 2>&1; then

  # _cost_represented_is_unsigned_integer <s>: true iff <s> is a non-empty run of decimal digits.
  # POSIX case, so it fails correctly on every bash the callers run.
  _cost_represented_is_unsigned_integer() {
    case "$1" in
      '' | *[!0-9]*) return 1 ;;
      *) return 0 ;;
    esac
  }

  # _cost_represented_parse_sidecar <cost.json>: emit one tab line per keyed record:
  #   kind \t fresh_input \t cache_write \t cache_read \t output \t session
  # A missing bucket yields an empty field, which _cost_represented_is_unsigned_integer reads as
  # non-numeric and blocks (fail closed). The caller validates the file is a
  # JSON object before calling this.
  _cost_represented_parse_sidecar() {
    jq -r '
      to_entries[]
      | [ (.value.kind // .key),
          (.value.buckets.fresh_input // "" | tostring),
          (.value.buckets.cache_write  // "" | tostring),
          (.value.buckets.cache_read   // "" | tostring),
          (.value.buckets.output       // "" | tostring),
          (.value.session_id // "") ]
      | @tsv
    ' "$1" 2>/dev/null
  }

  # _cost_represented_row_match <ledger> <field> <attribute_value> <kind> <session> \
  #                      <fresh_input> <cache_write> <cache_read> <output> <sum>
  # Prints "true"/"false": whether <ledger> carries a JSON-object row matching
  # identity + kind + session AND (four bucket values OR total). Corrupt-line
  # tolerant: a non-JSON ledger line is skipped, never fatal.
  _cost_represented_row_match() {
    local ledger="$1" field="$2" attribute_value="$3" kind="$4" session="$5"
    local fresh_input="$6" cache_write="$7" cache_read="$8" output="$9" sum="${10}"
    jq -R -n \
      --arg field "$field" --arg attribute_value "$attribute_value" --arg kind "$kind" --arg session_id "$session" \
      --argjson fresh_input "$fresh_input" --argjson cache_write "$cache_write" \
      --argjson cache_read "$cache_read" --argjson output "$output" --argjson sum "$sum" '
      def session_id_match(row_session_id): if $session_id == "" then row_session_id == null else row_session_id == $session_id end;
      [ inputs
        | (try fromjson catch empty)
        | select(type == "object")
        | select(.kind == $kind)
        | select(.[$field] == $attribute_value)
        | select(session_id_match(.session_id))
        | select(
            ( (.buckets.fresh_input == $fresh_input)
              and (.buckets.cache_write == $cache_write)
              and (.buckets.cache_read == $cache_read)
              and (.buckets.output == $output) )
            or (.total == $sum)
          )
      ] | length > 0
    ' "$ledger" 2>/dev/null
  }

  cost_folder_represented() {
    local folder_absolute_path="$1" attribute_field="$2" attribute_value="$3" ledger_path="$4"

    if [ -z "$folder_absolute_path" ] || [ -z "$attribute_field" ] || [ -z "$attribute_value" ] || [ -z "$ledger_path" ]; then
      printf 'cost-represented: usage: cost_folder_represented <folder_abs> <attr_field> <attr_val> <ledger_path>\n' >&2
      return 2
    fi

    # Nothing to gate if the folder is already gone.
    [ -d "$folder_absolute_path" ] || return 0

    local blocking=0 saw_section=0
    local -a sidecar_files=()
    local sidecar_file kind fresh_input cache_write cache_read output session sum matched

    while IFS= read -r -d '' sidecar_file; do
      sidecar_files+=("$sidecar_file")
    done < <(find "$folder_absolute_path" -maxdepth 2 -type f -name cost.json -print0 2>/dev/null)

    if [ "${#sidecar_files[@]}" -gt 0 ]; then
      for sidecar_file in "${sidecar_files[@]}"; do
        if ! jq -e 'type=="object"' "$sidecar_file" >/dev/null 2>&1; then
          saw_section=1
          blocking=1
          printf 'unparseable\tBLOCKING\tunparseable cost.json\n'
          continue
        fi
        while IFS=$'\t' read -r kind fresh_input cache_write cache_read output session; do
          [ -n "$kind" ] || continue
          saw_section=1

          # Fail closed: any bucket that is missing or non-numeric blocks.
          if _cost_represented_is_unsigned_integer "$fresh_input" \
            && _cost_represented_is_unsigned_integer "$cache_write" \
            && _cost_represented_is_unsigned_integer "$cache_read" \
            && _cost_represented_is_unsigned_integer "$output"; then
            fresh_input=$((10#$fresh_input)); cache_write=$((10#$cache_write))
            cache_read=$((10#$cache_read)); output=$((10#$output))
            sum=$((fresh_input + cache_write + cache_read + output))
            matched="$(_cost_represented_row_match "$ledger_path" "$attribute_field" "$attribute_value" \
              "$kind" "$session" "$fresh_input" "$cache_write" "$cache_read" "$output" "$sum")"
            if [ "$matched" = "true" ]; then
              printf '%s\tREPRESENTED\tmatched ledger row for %s=%s\n' "$kind" "$attribute_field" "$attribute_value"
            else
              blocking=1
              printf '%s\tBLOCKING\tno matching ledger row for %s=%s\n' "$kind" "$attribute_field" "$attribute_value"
            fi
          else
            blocking=1
            printf '%s\tBLOCKING\tincomplete or non-numeric buckets\n' "$kind"
          fi
        done < <(_cost_represented_parse_sidecar "$sidecar_file")
      done
    else
      return 0
    fi

    [ "$saw_section" -eq 1 ] || return 0
    [ "$blocking" -eq 0 ] || return 1
    return 0
  }

fi

# Direct invocation: the test suite can run this file as a script. When sourced,
# BASH_SOURCE[0] differs from $0 and this is skipped.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cost_folder_represented "$@"
fi
