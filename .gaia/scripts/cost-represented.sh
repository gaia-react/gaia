#!/usr/bin/env bash
# cost-represented.sh: value-aware, fail-closed representation gate.
#
# Public function (sourced by every forward-delete path and the one-time
# backlog migration):
#
#   cost_folder_represented <folder_abs> <attr_field> <attr_val> <ledger_path>
#
# It answers one question: is every cost.md phase section under <folder_abs>
# provably captured in <ledger_path> (cost.jsonl) with matching values? It is
# the guard that authorizes deleting a folder, so it is deliberately strict.
#
#   <folder_abs>   absolute path to the folder whose deletion is being gated.
#   <attr_field>   the identity field every row for this folder carries, one of
#                  spec_id | plan_id | plan_slug.
#   <attr_val>     the identity value (a spec id, or a plan id / slug).
#   <ledger_path>  absolute path to cost.jsonl. The caller resolves the
#                  main-checkout ledger; tests pass an isolated one.
#
# It scans every cost.md at the folder root and one level down (a colocated
# plan / plan-<N> subfolder), parses each `## SPEC` / `## Planning` /
# `## Execution` section (never `## Total`, a derived grand-sum), and classifies
# each discovered section:
#
#   REPRESENTED  the four buckets are present-and-numeric AND the ledger holds a
#                JSON-object row with the same identity, kind, and session, whose
#                four bucket values match or whose total equals the section sum.
#   BLOCKING     the section's buckets are missing / non-numeric (fail closed),
#                or no matching ledger row exists.
#
# Output: one manifest line per discovered section on stdout, tab-separated:
#
#   <kind>\t<REPRESENTED|BLOCKING>\t<reason>
#
# Diagnostics go to stderr. Return code: 0 iff every discovered section is
# REPRESENTED. A folder with no cost.md and no recognized section returns 0
# (nothing to lose; the caller owns the separate identity check). Returns 1 if
# any section is BLOCKING.
#
# Read-only and side-effect free: it never writes the ledger and never touches
# the folder, so a fail-open advisory caller can always call it safely. No
# `set -e`; each step is guarded. Sourced with no top-level side effects; also
# directly runnable for its test suite.

if ! declare -f cost_folder_represented >/dev/null 2>&1; then

  # _cost_repr_is_uint <s>: true iff <s> is a non-empty run of decimal digits.
  # POSIX case, so it fails correctly on every bash the callers run.
  _cost_repr_is_uint() {
    case "$1" in
      '' | *[!0-9]*) return 1 ;;
      *) return 0 ;;
    esac
  }

  # _cost_repr_parse <cost_md>: emit one tab line per discovered phase section:
  #   kind \t fresh \t cwrite \t cread \t output \t session
  # A missing bucket cell yields an empty field (the caller reads an empty or
  # non-numeric field as unparseable). `## Total` sets no kind, so it is never
  # emitted. Mirrors cost-backfill.sh's heading / bucket / Session parsing, but
  # emits every section (including incomplete ones) so the caller can fail closed
  # on an unparseable render instead of silently skipping it.
  _cost_repr_parse() {
    awk '
      function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
      function emit() {
        if (kind != "") {
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", kind, fresh, cwrite, cread, output, session
        }
        kind = ""; fresh = ""; cwrite = ""; cread = ""; output = ""; session = ""
      }
      /^## / {
        emit()
        heading = trim(substr($0, 4))
        if (heading == "SPEC") kind = "spec"
        else if (heading == "Planning") kind = "plan"
        else if (heading == "Execution") kind = "execute"
        else kind = ""
        next
      }
      kind == "" { next }
      /^\|/ {
        n = split($0, cells, "|")
        if (n >= 3) {
          label = trim(cells[2]); val = trim(cells[3])
          if (label == "Fresh input") fresh = val
          else if (label == "Cache write") cwrite = val
          else if (label == "Cache read") cread = val
          else if (label == "Output") output = val
        }
        next
      }
      index($0, "Session `") == 1 {
        rest = substr($0, length("Session `") + 1)
        bt = index(rest, "`")
        if (bt > 0) session = substr(rest, 1, bt - 1)
        next
      }
      END { emit() }
    ' "$1" 2>/dev/null
  }

  # _cost_repr_row_match <ledger> <field> <val> <kind> <session> \
  #                      <fresh> <cwrite> <cread> <output> <sum>
  # Prints "true"/"false": whether <ledger> carries a JSON-object row matching
  # identity + kind + session AND (four bucket values OR total). Corrupt-line
  # tolerant, like cost-backfill.sh's row_exists: a non-JSON ledger line is
  # skipped, never fatal.
  _cost_repr_row_match() {
    local ledger="$1" field="$2" val="$3" kind="$4" session="$5"
    local fresh="$6" cwrite="$7" cread="$8" output="$9" sum="${10}"
    jq -R -n \
      --arg field "$field" --arg val "$val" --arg kind "$kind" --arg sid "$session" \
      --argjson fresh "$fresh" --argjson cwrite "$cwrite" \
      --argjson cread "$cread" --argjson output "$output" --argjson sum "$sum" '
      def sid_match(f): if $sid == "" then f == null else f == $sid end;
      [ inputs
        | (try fromjson catch empty)
        | select(type == "object")
        | select(.kind == $kind)
        | select(.[$field] == $val)
        | select(sid_match(.session_id))
        | select(
            ( (.buckets.fresh_input == $fresh)
              and (.buckets.cache_write == $cwrite)
              and (.buckets.cache_read == $cread)
              and (.buckets.output == $output) )
            or (.total == $sum)
          )
      ] | length > 0
    ' "$ledger" 2>/dev/null
  }

  cost_folder_represented() {
    local folder_abs="$1" attr_field="$2" attr_val="$3" ledger_path="$4"

    if [ -z "$folder_abs" ] || [ -z "$attr_field" ] || [ -z "$attr_val" ] || [ -z "$ledger_path" ]; then
      printf 'cost-represented: usage: cost_folder_represented <folder_abs> <attr_field> <attr_val> <ledger_path>\n' >&2
      return 2
    fi

    # Nothing to gate if the folder is already gone.
    [ -d "$folder_abs" ] || return 0

    local blocking=0 saw_section=0
    local -a cost_files=()
    local cost_md
    while IFS= read -r -d '' cost_md; do
      cost_files+=("$cost_md")
    done < <(find "$folder_abs" -maxdepth 2 -type f -name cost.md -print0 2>/dev/null)

    [ "${#cost_files[@]}" -gt 0 ] || return 0

    local f kind fresh cwrite cread output session sum matched
    for f in "${cost_files[@]}"; do
      while IFS=$'\t' read -r kind fresh cwrite cread output session; do
        [ -n "$kind" ] || continue
        saw_section=1

        # Fail closed: any bucket that is missing or non-numeric blocks.
        if _cost_repr_is_uint "$fresh" \
          && _cost_repr_is_uint "$cwrite" \
          && _cost_repr_is_uint "$cread" \
          && _cost_repr_is_uint "$output"; then
          fresh=$((10#$fresh)); cwrite=$((10#$cwrite))
          cread=$((10#$cread)); output=$((10#$output))
          sum=$((fresh + cwrite + cread + output))
          matched="$(_cost_repr_row_match "$ledger_path" "$attr_field" "$attr_val" \
            "$kind" "$session" "$fresh" "$cwrite" "$cread" "$output" "$sum")"
          if [ "$matched" = "true" ]; then
            printf '%s\tREPRESENTED\tmatched ledger row for %s=%s\n' "$kind" "$attr_field" "$attr_val"
          else
            blocking=1
            printf '%s\tBLOCKING\tno matching ledger row for %s=%s\n' "$kind" "$attr_field" "$attr_val"
          fi
        else
          blocking=1
          printf '%s\tBLOCKING\tincomplete or non-numeric buckets\n' "$kind"
        fi
      done < <(_cost_repr_parse "$f")
    done

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
