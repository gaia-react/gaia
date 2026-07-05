#!/usr/bin/env bash
# cost-backfill.sh: one-off backfill of archived cost.md history into
# cost.jsonl.
#
# Every SPEC/plan folder under specs/archived and plans/archived that pre-dates
# cost.jsonl carries its cost tally ONLY in a rendered cost.md. This scans
# both archived trees, parses each cost.md's `## SPEC` / `## Planning` /
# `## Execution` sections (never `## Total`, a derived grand-sum, not a
# phase), and appends one dedup-checked cost.jsonl record per section,
# provenance-marked `source: "backfill"`. Idempotent: a row already present
# for the same (attribution key, kind, session_id) -- native or a prior
# backfill -- is skipped, so a second full run adds zero rows.
#
# Usage: cost-backfill.sh [<repo_root>] [--ledger <path>]
#
# Guarantees:
#   - Exit code is ALWAYS 0 (advisory / fail-open); never blocks a caller.
#   - stdout carries one summary line per emitted row; diagnostics go to
#     stderr only.
#   - Append-only: never rewrites or deletes an existing ledger row. No lock
#     -- this is a one-off run with no concurrent tally, so TOCTOU is moot,
#     matching token-tally.sh's own unlocked append.
set -uo pipefail

# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ledger-path-lib.sh" 2>/dev/null || true

log() {
  printf '%s\n' "$*" >&2
}

# ---------- args ----------
repo_root=""
ledger_override=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ledger)
      ledger_override="${2:-}"
      shift 2
      ;;
    *)
      if [ -z "$repo_root" ]; then
        repo_root="$1"
      else
        log "cost-backfill: ignoring unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$repo_root" ]; then
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$repo_root" ] || repo_root="$PWD"
fi
repo_root="${repo_root%/}"

ledger="$(gaia_resolve_ledger_path "$ledger_override" 2>/dev/null)"
if [ -z "$ledger" ]; then
  log "cost-backfill: could not resolve ledger path; nothing to do"
  exit 0
fi
mkdir -p "$(dirname "$ledger")" 2>/dev/null
touch "$ledger" 2>/dev/null

# ---------- per-cost.md section parser ----------
# Emits one tab-separated line per eligible phase section:
#   kind  fresh  cwrite  cread  output  session_id  ts  duration_seconds  dollars
# Missing optional fields are empty strings. `## Total` is never emitted
# (its heading never sets `kind`, so its table/session/elapsed lines are
# skipped by the `kind == "" { next }` guard below).
parse_cost_md() {
  awk '
    function trim(s) {
      gsub(/^[ \t]+/, "", s)
      gsub(/[ \t]+$/, "", s)
      return s
    }
    function parse_duration(token,    h, m, s, rest, idx) {
      h = 0; m = 0; s = -1
      rest = token
      idx = index(rest, "h")
      if (idx > 0) {
        h = substr(rest, 1, idx - 1) + 0
        rest = substr(rest, idx + 1)
      }
      idx = index(rest, "m")
      if (idx > 0) {
        m = substr(rest, 1, idx - 1) + 0
        rest = substr(rest, idx + 1)
      }
      idx = index(rest, "s")
      if (idx > 0) {
        s = substr(rest, 1, idx - 1) + 0
      }
      if (s < 0) return ""
      return h * 3600 + m * 60 + s
    }
    function emit() {
      if (kind != "" && fresh != "" && cwrite != "" && cread != "" && output != "") {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", kind, fresh, cwrite, cread, output, session, ts, dur, dollars
      } else if (kind != "") {
        printf "cost-backfill: skipping incomplete %s section in %s (missing bucket)\n", kind, FILENAME > "/dev/stderr"
      }
      kind = ""; fresh = ""; cwrite = ""; cread = ""; output = ""
      session = ""; ts = ""; dur = ""; dollars = ""
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
        label = trim(cells[2])
        val = trim(cells[3])
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
      gidx = index($0, "generated ")
      if (gidx > 0) ts = substr($0, gidx + length("generated "))
      next
    }
    {
      midx = index($0, "**Elapsed (first to last model turn):** ")
      if (midx > 0) {
        rest = substr($0, midx + length("**Elapsed (first to last model turn):** "))
        spidx = index(rest, " ")
        token = (spidx > 0) ? substr(rest, 1, spidx - 1) : rest
        dur = parse_duration(token)
        next
      }
      midx = index($0, "**Est. cost (USD):** $")
      if (midx > 0) {
        dollars = trim(substr($0, midx + length("**Est. cost (USD):** $")))
        next
      }
    }
    END { emit() }
  ' "$1"
}

# Returns "true"/"false": whether a row already exists in $ledger with the
# same (attribution field/value, kind, session_id) -- any source.
row_exists() {
  local attr_field="$1" attr_val="$2" kind="$3" session_id="$4"
  jq -R -n --arg field "$attr_field" --arg val "$attr_val" --arg kind "$kind" --arg sid "$session_id" '
    def sid_match(f): if $sid == "" then f == null else f == $sid end;
    [ inputs
      | (try fromjson catch empty)
      | select(type == "object")
      | select(.kind == $kind)
      | select(.[$field] == $val)
      | select(sid_match(.session_id))
    ] | length > 0
  ' "$ledger" 2>/dev/null
}

build_row() {
  local kind="$1" spec_id="$2" plan_id="$3" plan_slug="$4" session_id="$5"
  local fresh="$6" cwrite="$7" cread="$8" output="$9" ts="${10}" dur="${11}" dollars="${12}"
  jq -nc \
    --arg kind "$kind" \
    --arg spec_id "$spec_id" \
    --arg plan_id "$plan_id" \
    --arg plan_slug "$plan_slug" \
    --arg session_id "$session_id" \
    --argjson fresh "$fresh" \
    --argjson cwrite "$cwrite" \
    --argjson cread "$cread" \
    --argjson output "$output" \
    --arg ts "$ts" \
    --arg dur "$dur" \
    --arg dollars "$dollars" \
    '
    {
      schema_version: 1,
      kind: $kind,
      spec_id: (if $spec_id == "" then null else $spec_id end),
      plan_id: (if $plan_id == "" then null else $plan_id end),
      plan_slug: (if $plan_slug == "" then null else $plan_slug end),
      session_id: (if $session_id == "" then null else $session_id end),
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $output},
      total: ($fresh + $cwrite + $cread + $output),
      dollars: (if $dollars == "" then null else ($dollars | tonumber) end),
      started_at: null,
      ended_at: null,
      duration_seconds: (if $dur == "" then null else ($dur | tonumber) end),
      duration_available: ($dur != ""),
      ts: (if $ts == "" then null else $ts end),
      source: "backfill",
      seq: 0,
      final: true
    }
    '
}

emitted=0

process_cost_md() {
  local cost_md="$1" folder_base
  folder_base="$(basename "$(dirname "$cost_md")")"

  local spec_id="" plan_id="" plan_slug="" attr_field="" attr_val=""
  case "$folder_base" in
    SPEC-[0-9]*)
      spec_id="$folder_base"
      attr_field="spec_id"
      attr_val="$folder_base"
      ;;
    PLAN-[0-9]*)
      plan_id="$folder_base"
      attr_field="plan_id"
      attr_val="$folder_base"
      ;;
    *)
      plan_slug="$folder_base"
      attr_field="plan_slug"
      attr_val="$folder_base"
      ;;
  esac

  while IFS=$'\t' read -r kind fresh cwrite cread output session_id ts dur dollars; do
    [ -n "$kind" ] || continue
    if [ "$(row_exists "$attr_field" "$attr_val" "$kind" "$session_id")" = "true" ]; then
      continue
    fi
    local rec
    rec="$(build_row "$kind" "$spec_id" "$plan_id" "$plan_slug" "$session_id" \
      "$fresh" "$cwrite" "$cread" "$output" "$ts" "$dur" "$dollars")"
    if [ -n "$rec" ] && printf '%s\n' "$rec" >>"$ledger"; then
      emitted=$((emitted + 1))
      printf 'backfilled %s row: %s=%s session=%s\n' "$kind" "$attr_field" "$attr_val" "${session_id:-<none>}"
    else
      log "cost-backfill: failed to append $kind row for $attr_field=$attr_val"
    fi
  done < <(parse_cost_md "$cost_md")
}

while IFS= read -r -d '' cost_md; do
  process_cost_md "$cost_md"
done < <(
  find "$repo_root/.gaia/local/specs/archived" -mindepth 2 -maxdepth 2 -type f -name cost.md -print0 2>/dev/null
  find "$repo_root/.gaia/local/plans/archived" -mindepth 2 -maxdepth 2 -type f -name cost.md -print0 2>/dev/null
)

log "cost-backfill: emitted $emitted row(s) to $ledger"
exit 0
