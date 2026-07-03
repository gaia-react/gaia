#!/usr/bin/env bash
# GAIA token-accounting tally helper (SPEC-013).
#
# Reads the ground-truth token usage the API already recorded for a GAIA action
# (/gaia-spec, /gaia-plan, or a KICKOFF plan-execution run) and turns it into a
# per-action readout: four billing buckets plus a total, a wall-clock elapsed
# span, a durable machine-local ledger record, a human-readable tokens.md, and a
# printed tally block.
#
# It sums `.message.usage` across the session's MAIN transcript
# (<projects-root>/*/<session-id>.jsonl) AND every sub-agent sidecar
# (<projects-root>/*/<session-id>/subagents/agent-*.jsonl). A single assistant
# message is streamed across MULTIPLE JSONL lines that repeat the same
# `.message.id` and the same usage, so the tally DEDUPS by `.message.id`
# (fallback `.uuid`) before summing; without this it overcounts output ~3x.
#
# Alongside the tokens it reports wall-clock elapsed = max(.timestamp) -
# min(.timestamp) over the usage-bearing lines (first to last billed model turn),
# across main + sidecars. Bookkeeping lines (pr-link/system/attachment) and
# leading user think-time carry no usage and are excluded, so the span sits on
# real work. Epoch conversion is jq-only (`fromdateiso8601`, UTC on every
# platform); the `date` binary is NEVER used to parse transcript timestamps
# (`date -j -f` ignores the Z and halves a span across a DST boundary, and
# `date -j` is macOS-only, which breaks the Linux CI bats run).
#
# Behavior / contract (README C1-C5):
#   - Exit code is ALWAYS 0. The helper never blocks or fails its caller.
#     Every failure mode degrades to a partial/absent figure with a marker;
#     no number is ever fabricated.
#   - stdout carries ONLY the tally block; all diagnostics go to stderr.
#   - Side effects: append one ledger record; write <out-dir>/tokens.md.
#   - `partial` flips when the session id is empty, the main transcript matched
#     no file, or any matched file failed to parse. An empty sidecar set is NOT
#     partial. `duration_available` is a SEPARATE flag: tokens can be complete
#     while duration is unavailable (unparseable extremal timestamp), and the
#     reverse.
#
# CLI (README C1):
#   bash .gaia/scripts/token-tally.sh \
#     --action <spec|plan|execute> --spec-id <SPEC-NNN> [--plan-slug <slug>] \
#     --out-dir <dir> [--session-id <id>] [--projects-root <dir>] [--ledger <path>]
#
# DO NOT add `set -e`; each step is guarded independently so one failure cannot
# abort the never-block guarantee.

log() {
  printf '%s\n' "$*" >&2
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Pinned human duration format: <N>h<M>m<S>s, dropping any LEADING zero-valued
# unit (45s, 6m39s, 2h4m10s), second granularity, lossless vs duration_seconds.
human_duration() {
  local total="$1" h m s
  h=$(( total / 3600 ))
  m=$(( (total % 3600) / 60 ))
  s=$(( total % 60 ))
  if (( h > 0 )); then
    printf '%dh%dm%ds' "$h" "$m" "$s"
  elif (( m > 0 )); then
    printf '%dm%ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

# ---------- argument parsing (never crash on a bad/missing flag) ----------
ACTION=""
SPEC_ID=""
PLAN_SLUG=""
OUT_DIR=""
SESSION_ID_ARG=""
PROJECTS_ROOT_ARG=""
LEDGER_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case "$key" in
    --action|--spec-id|--plan-slug|--out-dir|--session-id|--projects-root|--ledger)
      val="${2:-}"
      case "$key" in
        --action)        ACTION="$val" ;;
        --spec-id)       SPEC_ID="$val" ;;
        --plan-slug)     PLAN_SLUG="$val" ;;
        --out-dir)       OUT_DIR="$val" ;;
        --session-id)    SESSION_ID_ARG="$val" ;;
        --projects-root) PROJECTS_ROOT_ARG="$val" ;;
        --ledger)        LEDGER_OVERRIDE="$val" ;;
      esac
      # `shift 2` fails (and does NOT shift) when a flag is the final arg with no
      # value, which would spin this loop forever; fall back to a single shift.
      shift 2 2>/dev/null || shift
      ;;
    *)
      log "token-tally: ignoring unknown argument: $key"
      shift
      ;;
  esac
done

SESSION_ID="${SESSION_ID_ARG:-${CLAUDE_CODE_SESSION_ID:-}}"
PROJECTS_ROOT="${PROJECTS_ROOT_ARG:-$HOME/.claude/projects}"

partial=0

# Missing required flags are belt-and-suspenders (callers pass well-formed args);
# degrade to partial rather than crash.
[[ -z "$ACTION" ]]  && { log "token-tally: missing --action"; partial=1; }
[[ -z "$SPEC_ID" ]] && { log "token-tally: missing --spec-id"; partial=1; }
[[ -z "$OUT_DIR" ]] && { log "token-tally: missing --out-dir"; partial=1; }
if [[ "$ACTION" == "plan" || "$ACTION" == "execute" ]] && [[ -z "$PLAN_SLUG" ]]; then
  log "token-tally: missing --plan-slug for action=$ACTION"
  partial=1
fi
[[ -z "$SESSION_ID" ]] && { log "token-tally: no session id (--session-id or CLAUDE_CODE_SESSION_ID)"; partial=1; }

# ---------- single-pass tally over main transcript + sidecars ----------
# Per file, ONE streaming read emits {usage:[{id,u}], tmin, tmax} where usage is
# deduped within the file (last-wins) and tmin/tmax range over EVERY usage line
# (not the deduped survivors). A file that fails to parse flips `partial` and
# contributes nothing, but never aborts the run or the other files.
tmp="$(mktemp 2>/dev/null)" || tmp=""
[[ -z "$tmp" ]] && { log "token-tally: mktemp failed; degrading to partial"; partial=1; }

emit_file() {
  jq -cn '
    reduce inputs as $x (
      {usage:{}, tmin:null, tmax:null};
      if $x.message.usage != null
      then .usage[($x.message.id // $x.uuid)] = $x.message.usage
         | (if ($x.timestamp | type) == "string"
            then .tmin = (if .tmin == null or $x.timestamp < .tmin then $x.timestamp else .tmin end)
               | .tmax = (if .tmax == null or $x.timestamp > .tmax then $x.timestamp else .tmax end)
            else . end)
      else . end)
    | {usage: (.usage | to_entries | map({id: .key, u: .value})), tmin, tmax}
  ' "$1" >>"$tmp" 2>/dev/null || partial=1
}

if [[ -n "$SESSION_ID" && -n "$tmp" ]]; then
  # Main transcript: first match of <projects-root>/*/<session-id>.jsonl.
  main_found=0
  for f in "$PROJECTS_ROOT"/*/"$SESSION_ID".jsonl; do
    if [[ -f "$f" ]]; then
      emit_file "$f"
      main_found=1
      break
    fi
  done
  [[ "$main_found" -eq 0 ]] && { log "token-tally: no main transcript for session $SESSION_ID"; partial=1; }

  # Sidecars: zero matches is fine (a session may fan out no sub-agents), NOT
  # partial. The agent-*.jsonl glob excludes the sibling agent-*.meta.json files.
  for f in "$PROJECTS_ROOT"/*/"$SESSION_ID"/subagents/agent-*.jsonl; do
    [[ -f "$f" ]] && emit_file "$f"
  done
fi

# ---------- aggregate: global dedup + bucket sums + global min/max ----------
FRESH=0
CWRITE=0
CREAD=0
OUT=0
TMIN=""
TMAX=""
if [[ -n "$tmp" && -s "$tmp" ]]; then
  IFS=$'\t' read -r FRESH CWRITE CREAD OUT TMIN TMAX < <(
    jq -rs '
      ((map(.usage) | add // []) | reduce .[] as $x ({}; .[$x.id] = $x.u) | [.[]]) as $u
      | [ ($u | map(.input_tokens // 0)                | add // 0),
          ($u | map(.cache_creation_input_tokens // 0) | add // 0),
          ($u | map(.cache_read_input_tokens // 0)     | add // 0),
          ($u | map(.output_tokens // 0)               | add // 0),
          (map(.tmin) | map(select(. != null)) | min // ""),
          (map(.tmax) | map(select(. != null)) | max // "") ]
      | @tsv
    ' "$tmp" 2>/dev/null || printf '0\t0\t0\t0\t\t\n'
  )
fi
[[ -n "$tmp" ]] && rm -f "$tmp" 2>/dev/null

is_uint "$FRESH"  || FRESH=0
is_uint "$CWRITE" || CWRITE=0
is_uint "$CREAD"  || CREAD=0
is_uint "$OUT"    || OUT=0
TOTAL=$(( FRESH + CWRITE + CREAD + OUT ))

# ---------- duration: convert ONLY the two extremes in jq (never `date`) ----------
# A malformed extremal timestamp -> unavailable (own flag), never a fabricated 0,
# never an abort. The subtraction stays inside jq so empty vars can't leak a 0.
DUR_SECONDS=""
DUR_AVAIL=false
if [[ -n "$TMIN" && -n "$TMAX" ]]; then
  DUR_SECONDS="$(jq -rn --arg a "$TMIN" --arg b "$TMAX" '
    def toe: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    (($b | toe) - ($a | toe))
  ' 2>/dev/null || true)"
  if is_uint "$DUR_SECONDS"; then
    DUR_AVAIL=true
  else
    DUR_SECONDS=""
  fi
fi

HUMAN=""
[[ "$DUR_AVAIL" == "true" ]] && HUMAN="$(human_duration "$DUR_SECONDS")"

# ---------- shared generation stamp (date -u here is fine; the ban is only on
#            parsing transcript timestamps to epoch, which stays jq-only) ----------
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Display titles: stdout uses `<spec_id>/<slug>`, tokens.md uses `<spec_id> / <slug>`.
if [[ "$ACTION" == "spec" ]]; then
  out_title="$ACTION $SPEC_ID"
  md_title="$ACTION $SPEC_ID"
else
  out_title="$ACTION $SPEC_ID/$PLAN_SLUG"
  md_title="$ACTION $SPEC_ID / $PLAN_SLUG"
fi

# ---------- ledger record (README C2), resolved to the main checkout ----------
# main_root = dirname(absolute(git rev-parse --git-common-dir)), so a KICKOFF run
# inside a linked worktree records to the surviving main ledger, not the
# worktree's discarded copy. --ledger overrides (test seam).
resolve_ledger() {
  if [[ -n "$LEDGER_OVERRIDE" ]]; then
    printf '%s' "$LEDGER_OVERRIDE"
    return 0
  fi
  local common_dir abs main_root
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
  [[ -z "$common_dir" ]] && return 1
  case "$common_dir" in
    /*) abs="$common_dir" ;;
    *)  abs="$PWD/$common_dir" ;;
  esac
  main_root="$(cd "$(dirname "$abs")" 2>/dev/null && pwd)"
  [[ -z "$main_root" ]] && return 1
  printf '%s' "$main_root/.gaia/local/telemetry/tokens.jsonl"
}

partial_bool=false
[[ "$partial" -ne 0 ]] && partial_bool=true

rec="$(jq -nc \
  --arg action "$ACTION" \
  --arg spec_id "$SPEC_ID" \
  --arg plan_slug "$PLAN_SLUG" \
  --arg session_id "$SESSION_ID" \
  --argjson fresh "$FRESH" \
  --argjson cwrite "$CWRITE" \
  --argjson cread "$CREAD" \
  --argjson out "$OUT" \
  --argjson total "$TOTAL" \
  --argjson partial "$partial_bool" \
  --arg started "$TMIN" \
  --arg ended "$TMAX" \
  --argjson dur "${DUR_SECONDS:-null}" \
  --argjson avail "$DUR_AVAIL" \
  --arg ts "$TS" \
  '
    {action: $action, spec_id: $spec_id}
    + (if $action == "spec" then {} else {plan_slug: $plan_slug} end)
    + {
        session_id: $session_id,
        buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $out},
        total: $total,
        partial: $partial,
        started_at: (if $avail then $started else null end),
        ended_at: (if $avail then $ended else null end),
        duration_seconds: (if $avail then $dur else null end),
        duration_available: $avail,
        ts: $ts
      }
  ' 2>/dev/null || true)"

if [[ -n "$rec" ]]; then
  if ledger="$(resolve_ledger)" && [[ -n "$ledger" ]]; then
    mkdir -p "$(dirname "$ledger")" 2>/dev/null
    printf '%s\n' "$rec" >>"$ledger" 2>/dev/null || log "token-tally: ledger write failed: $ledger"
  else
    log "token-tally: could not resolve ledger path; skipping ledger append"
  fi
else
  log "token-tally: failed to build ledger record; skipping ledger append"
fi

# ---------- tokens.md (README C3) ----------
if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR" 2>/dev/null
  {
    printf '# Token cost: %s\n\n' "$md_title"
    printf '| Bucket | Tokens |\n'
    printf '| --- | --- |\n'
    printf '| Fresh input | %s |\n' "$FRESH"
    printf '| Cache write | %s |\n' "$CWRITE"
    printf '| Cache read | %s |\n' "$CREAD"
    printf '| Output | %s |\n' "$OUT"
    printf '| **Total** | %s |\n\n' "$TOTAL"
    if [[ "$DUR_AVAIL" == "true" ]]; then
      printf '**Elapsed (first to last model turn):** %s (%s to %s)\n' "$HUMAN" "$TMIN" "$TMAX"
    else
      printf '_Elapsed: unavailable (no readable turn timestamps)._\n'
    fi
    if [[ "$partial" -ne 0 ]]; then
      printf '\n_Partial: one or more transcript inputs were missing or unparseable; figures are a lower bound._\n'
    fi
    # Backticks below are literal markdown (inline-code the session id), not a command sub.
    # shellcheck disable=SC2016
    printf '\nSession `%s` · generated %s\n' "$SESSION_ID" "$TS"
  } >"$OUT_DIR/tokens.md" 2>/dev/null || log "token-tally: tokens.md write failed: $OUT_DIR/tokens.md"
fi

# ---------- stdout tally block (README C4) ----------
printf 'Token cost (%s):\n' "$out_title"
printf '  Fresh input:  %s\n' "$FRESH"
printf '  Cache write:  %s\n' "$CWRITE"
printf '  Cache read:   %s\n' "$CREAD"
printf '  Output:       %s\n' "$OUT"
printf '  Total:        %s\n' "$TOTAL"
if [[ "$DUR_AVAIL" == "true" ]]; then
  printf '  Elapsed:      %s  (first to last model turn: %s to %s)\n' "$HUMAN" "$TMIN" "$TMAX"
else
  printf '  Elapsed:      unavailable (no readable turn timestamps)\n'
fi
if [[ "$partial" -ne 0 ]]; then
  printf '  (partial: figures are a lower bound; some inputs were unreadable)\n'
fi

exit 0
