#!/usr/bin/env bash
# GAIA cost-accounting tally helper.
#
# Reads the ground-truth token usage the API already recorded for a GAIA action
# (/gaia-spec, /gaia-plan, or a KICKOFF plan-execution run) and turns it into a
# per-action readout: four billing buckets plus a total, a wall-clock elapsed
# span, a durable machine-local ledger record (cost.jsonl), a human-readable
# cost.md, and a printed tally block.
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
# The ledger stores the raw UTC endpoints (C2, the durable machine record); the
# HUMAN surfaces (stdout, cost.md) render those two endpoints in the machine's
# LOCAL zone (jq for the clock, `date +%Z` for the zone label — jq's own %z/%Z
# misreport the offset across a DST boundary on some builds, while `date +%Z`
# reads the effective system zone, is identical on macOS and Linux, and parses
# no timestamp, so it is outside the epoch-parsing ban above).
#
# Behavior / contract (README C1-C5):
#   - Exit code is ALWAYS 0. The helper never blocks or fails its caller.
#     Every failure mode degrades to a partial/absent figure with a marker;
#     no number is ever fabricated.
#   - stdout carries ONLY the tally block; all diagnostics go to stderr.
#   - Side effects: append one ledger record; write <out-dir>/cost.md. For
#     action=plan|execute the cost.md carries independent `## Planning` and
#     `## Execution` sections; each run replaces ONLY its own section and copies
#     the sibling through untouched, so the plan-authoring cost (written by
#     /gaia-plan) and the plan-execution cost (written by the KICKOFF git-op
#     hook on each commit) never overwrite or sum. action=spec writes a sectioned
#     `## SPEC` doc into the SPEC folder, a separate file that is unaffected.
#   - `partial` flips when the session id is empty, the main transcript matched
#     no file, or any matched file failed to parse. An empty sidecar set is NOT
#     partial. `duration_available` is a SEPARATE flag: tokens can be complete
#     while duration is unavailable (unparseable extremal timestamp), and the
#     reverse.
#
# CLI (README C1):
#   bash .gaia/scripts/token-tally.sh \
#     --action <spec|plan|execute> [--spec-id <SPEC-NNN>] [--plan-id <PLAN-NNN>] \
#     [--plan-slug <slug>] --out-dir <dir> [--session-id <id>] \
#     [--projects-root <dir>] [--ledger <path>] [--rate-table <path>]
#
# Exactly one of --spec-id / --plan-id carries the feature identity: a SPEC-*
# key routes to the record's `spec_id`, a PLAN-* key to `plan_id`, and the two
# are never both set. An unclassifiable or absent key degrades to a partial row
# with both ids null, never a mistyped id.
#
# DO NOT add `set -e`; each step is guarded independently so one failure cannot
# abort the never-block guarantee.

# shellcheck source=.gaia/scripts/token-pricing-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/token-pricing-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ledger-path-lib.sh" 2>/dev/null || true
# shellcheck source=.specify/extensions/gaia/lib/with-ledger-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../.specify/extensions/gaia/lib/with-ledger-lock.sh" 2>/dev/null || true

log() {
  printf '%s\n' "$*" >&2
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Reads stdin, echoes the first 16 hex of its sha256. `shasum -a 256` is present
# on macOS and most Linux; `sha256sum` is the coreutils fallback. Returns 1 when
# neither tool is available, so the caller degrades to null (never fabricates).
hash16() {
  local out
  if out="$(shasum -a 256 2>/dev/null)"; then :;
  elif out="$(sha256sum 2>/dev/null)"; then :;
  else return 1; fi
  out="${out%% *}"
  [[ -z "$out" ]] && return 1
  printf '%s' "${out:0:16}"
}

# Echoes `sha256:<first-16-hex>` for a readable file, else returns 1.
rate_table_id() {
  local path="$1" h
  [[ -f "$path" ]] || return 1
  h="$(hash16 <"$path")" || return 1
  [[ -z "$h" ]] && return 1
  printf 'sha256:%s' "$h"
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

# Render a raw UTC transcript timestamp (…Z) in the machine's LOCAL zone, for the
# human surfaces only. jq renders the local clock (DST-correct for H:M:S); the
# zone LABEL is $ZONE_LABEL (resolved once via `date +%Z`). Falls back to the raw
# input if jq cannot parse it (never fabricates, never blocks).
ZONE_LABEL=""
to_local() {
  local iso="$1" clock
  clock="$(jq -rn --arg t "$iso" '
    $t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M:%S")
  ' 2>/dev/null || true)"
  if [[ -n "$clock" ]]; then
    printf '%s%s' "$clock" "${ZONE_LABEL:+ $ZONE_LABEL}"
  else
    printf '%s' "$iso"
  fi
}

# ---------- argument parsing (never crash on a bad/missing flag) ----------
ACTION=""
SPEC_ID=""
PLAN_ID=""
PLAN_SLUG=""
OUT_DIR=""
SESSION_ID_ARG=""
PROJECTS_ROOT_ARG=""
LEDGER_OVERRIDE=""
RATE_TABLE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case "$key" in
    --action|--spec-id|--plan-id|--plan-slug|--out-dir|--session-id|--projects-root|--ledger|--rate-table)
      val="${2:-}"
      case "$key" in
        --action)        ACTION="$val" ;;
        --spec-id)       SPEC_ID="$val" ;;
        --plan-id)       PLAN_ID="$val" ;;
        --plan-slug)     PLAN_SLUG="$val" ;;
        --out-dir)       OUT_DIR="$val" ;;
        --session-id)    SESSION_ID_ARG="$val" ;;
        --projects-root) PROJECTS_ROOT_ARG="$val" ;;
        --ledger)        LEDGER_OVERRIDE="$val" ;;
        --rate-table)    RATE_TABLE_OVERRIDE="$val" ;;
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
# Live $PWD, not --out-dir/--ledger: those resolve to the main checkout even in a
# worktree, which would defeat transcript-dir resolution for the worktree path.
SESSION_CWD="${PWD:-}"

partial=0

# ---------- classify the feature identity (spec_id XOR plan_id) ----------
# A SPEC-* key routes to spec_id, a PLAN-* key to plan_id. The two are never both
# set: a spec identity wins the tiebreak (callers pass exactly one). An
# unclassifiable or absent key degrades to partial with both ids null -- never a
# mistyped id. Prefix-validating here (not just trusting the flag) keeps the
# record type-safe regardless of how a caller labels the key.
SPEC_ID_OUT=""
PLAN_ID_OUT=""
case "$SPEC_ID" in SPEC-*) SPEC_ID_OUT="$SPEC_ID" ;; esac
case "$PLAN_ID" in PLAN-*) PLAN_ID_OUT="$PLAN_ID" ;; esac
if [[ -n "$SPEC_ID_OUT" ]]; then
  PLAN_ID_OUT=""   # spec identity wins; the record never carries both
fi
# The single feature key used for cost.md titles and the seq/final match.
FEATURE="${SPEC_ID_OUT:-$PLAN_ID_OUT}"

# Missing required flags are belt-and-suspenders (callers pass well-formed args);
# degrade to partial rather than crash.
[[ -z "$ACTION" ]]  && { log "token-tally: missing --action"; partial=1; }
[[ -z "$FEATURE" ]] && { log "token-tally: no feature identity (--spec-id SPEC-* or --plan-id PLAN-*)"; partial=1; }
[[ -z "$OUT_DIR" ]] && { log "token-tally: missing --out-dir"; partial=1; }
if [[ "$ACTION" == "plan" || "$ACTION" == "execute" ]] && [[ -z "$PLAN_SLUG" ]]; then
  log "token-tally: missing --plan-slug for action=$ACTION"
  partial=1
fi
[[ -z "$SESSION_ID" ]] && { log "token-tally: no session id (--session-id or CLAUDE_CODE_SESSION_ID)"; partial=1; }

# ---------- single-pass tally over main transcript + sidecars ----------
# Per file, ONE streaming read emits {usage:[{id,u,m}], tmin, tmax} where usage is
# deduped within the file (last-wins) and tmin/tmax range over EVERY usage line
# (not the deduped survivors). `m` carries `.message.model` (null when absent),
# threaded through alongside the usage object so the aggregate step can attribute
# buckets per model AFTER the same dedup (see FC-1 in the SPEC-019 plan). A file
# that fails to parse flips `partial` and contributes nothing, but never aborts
# the run or the other files.
tmp="$(mktemp 2>/dev/null)" || tmp=""
[[ -z "$tmp" ]] && { log "token-tally: mktemp failed; degrading to partial"; partial=1; }

# Each usage entry is tagged with `b`, the agent-type bucket it belongs to
# (`main` for the main transcript, the sub-agent's own `agentType` for a sidecar,
# `auto-compaction` for a compaction-summary line regardless of source). The tag
# rides the same global dedup as the buckets, so grouping the deduped survivors
# by `b` reconciles by equality to the aggregate buckets (see by_agent_type).
#
# Auto-compaction marker: a line is compaction usage when `isCompactSummary` is
# true at the top level or under `.message`. No such marker appears in the
# transcripts available at authoring time (Claude Code / Supacode current
# format), so this branch is present-when-detected: absent otherwise, and all
# main-transcript usage routes to `main`. The DOCS task describes this marker.
emit_file() {
  jq -cn --arg bkt "$2" '
    reduce inputs as $x (
      {usage:{}, tmin:null, tmax:null};
      if $x.message.usage != null
      then .usage[($x.message.id // $x.uuid)] = {
             u: $x.message.usage,
             m: ($x.message.model // null),
             b: (if ($x.isCompactSummary == true) or ($x.message.isCompactSummary == true)
                 then "auto-compaction" else $bkt end)
           }
         | (if ($x.timestamp | type) == "string"
            then .tmin = (if .tmin == null or $x.timestamp < .tmin then $x.timestamp else .tmin end)
               | .tmax = (if .tmax == null or $x.timestamp > .tmax then $x.timestamp else .tmax end)
            else . end)
      else . end)
    | {usage: (.usage | to_entries | map({id: .key, u: .value.u, m: .value.m, b: .value.b})), tmin, tmax}
  ' "$1" >>"$tmp" 2>/dev/null || partial=1
}

# The agent-type bucket for a sidecar is its own sidecar attribution: read the
# sibling agent-<hash>.meta.json and take `.agentType` (shape:
# {"agentType":"general-purpose","description":"…","toolUseId":"…"}). A missing/
# unreadable meta or absent agentType degrades to `unknown`, so every sidecar
# line still lands in exactly one bucket (reconcile-by-equality holds).
sidecar_agent_type() {
  local meta atype
  meta="${1%.jsonl}.meta.json"
  atype="$(jq -r '.agentType // empty' "$meta" 2>/dev/null || true)"
  [[ -n "$atype" ]] && printf '%s' "$atype" || printf 'unknown'
}

if [[ -n "$SESSION_ID" && -n "$tmp" ]]; then
  # Main transcript: first match of <projects-root>/*/<session-id>.jsonl.
  main_found=0
  for f in "$PROJECTS_ROOT"/*/"$SESSION_ID".jsonl; do
    if [[ -f "$f" ]]; then
      emit_file "$f" "main"
      main_found=1
      break
    fi
  done
  [[ "$main_found" -eq 0 ]] && { log "token-tally: no main transcript for session $SESSION_ID"; partial=1; }

  # Sidecars: zero matches is fine (a session may fan out no sub-agents), NOT
  # partial. The agent-*.jsonl glob excludes the sibling agent-*.meta.json files.
  for f in "$PROJECTS_ROOT"/*/"$SESSION_ID"/subagents/agent-*.jsonl; do
    [[ -f "$f" ]] && emit_file "$f" "$(sidecar_agent_type "$f")"
  done
fi

# ---------- aggregate: global dedup + bucket sums + global min/max ----------
FRESH=0
CWRITE=0
CREAD=0
OUT=0
TMIN=""
TMAX=""
BY_MODEL='{}'
BY_AGENT_TYPE='{}'
if [[ -n "$tmp" && -s "$tmp" ]]; then
  IFS=$'\t' read -r FRESH CWRITE CREAD OUT TMIN TMAX < <(
    jq -rs '
      ((map(.usage) | add // []) | reduce .[] as $x ({}; .[$x.id] = {u: $x.u, m: $x.m}) | [.[]]) as $u
      | [ ($u | map(.u.input_tokens // 0)                | add // 0),
          ($u | map(.u.cache_creation_input_tokens // 0) | add // 0),
          ($u | map(.u.cache_read_input_tokens // 0)     | add // 0),
          ($u | map(.u.output_tokens // 0)               | add // 0),
          (map(.tmin) | map(select(. != null)) | min // ""),
          (map(.tmax) | map(select(. != null)) | max // "") ]
      | @tsv
    ' "$tmp" 2>/dev/null || printf '0\t0\t0\t0\t\t\n'
  )

  # ---------- per-model attribution (FC-1): same dedup-by-id, grouped by model ----------
  # Reuses the identical global dedup so per-model sums reconcile exactly to the
  # aggregate above (AUDIT directive 3: dedup THEN group). A model key is dropped
  # when `.m` is null/empty (line not attributable) or its five-bucket sum is
  # zero (drops `<synthetic>` and other zero-usage sentinels). Never blocks: any
  # failure here degrades BY_MODEL to `{}`, so `by_model` is simply omitted below.
  BY_MODEL="$(jq -cs '
    ((map(.usage) | add // []) | reduce .[] as $x ({}; .[$x.id] = {u: $x.u, m: $x.m}) | [.[]]) as $u
    | ($u | map(select(.m != null and .m != "")))
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
  ' "$tmp" 2>/dev/null)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$BY_MODEL" || BY_MODEL='{}'

  # ---------- per-agent-type attribution: same dedup-by-id, grouped by bucket ----------
  # Groups the SAME deduped survivors by their agent-type tag `.b` (main /
  # <agentType> / auto-compaction / unknown), so every usage line lands in
  # exactly one bucket. Reconcile-by-equality: collapsing 5m+1h -> cache_write
  # and summing the buckets reproduces the aggregate `buckets` above. Unlike
  # by_model this NEVER drops a line by attribution (a null model is dropped from
  # by_model but its tokens still belong to some agent-type bucket); only a
  # zero-sum bucket is pruned, which cannot break the equality. Any failure
  # degrades BY_AGENT_TYPE to `{}` so `by_agent_type` is omitted below.
  BY_AGENT_TYPE="$(jq -cs '
    ((map(.usage) | add // []) | reduce .[] as $x ({}; .[$x.id] = {u: $x.u, b: $x.b}) | [.[]]) as $u
    | ($u | map(select(.b != null and .b != "")))
    | group_by(.b)
    | map({
        key: .[0].b,
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
  ' "$tmp" 2>/dev/null)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$BY_AGENT_TYPE" || BY_AGENT_TYPE='{}'
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

# Human-facing duration + LOCAL-zone endpoint strings (the ledger keeps raw UTC).
# Resolve the zone label once; both endpoints share it.
HUMAN=""
LOCAL_START=""
LOCAL_END=""
if [[ "$DUR_AVAIL" == "true" ]]; then
  HUMAN="$(human_duration "$DUR_SECONDS")"
  ZONE_LABEL="$(date +%Z 2>/dev/null || true)"
  LOCAL_START="$(to_local "$TMIN")"
  LOCAL_END="$(to_local "$TMAX")"
fi

# ---------- shared generation stamp (date -u here is fine; the ban is only on
#            parsing transcript timestamps to epoch, which stays jq-only) ----------
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- dollar pricing of this section's own by_model (SPEC-022) ----------
# Each cost.md section prices its OWN in-process BY_MODEL at the rate whose
# effective window covers TS (this run's generation stamp) -- a frozen
# snapshot, deliberately distinct from token-rollup.sh's read-time reprice.
# Never guesses, never blocks: empty attribution or an unreadable rate table
# degrade to a marked "unavailable" line rather than a fabricated figure.
#
# The ledger persists the RAW numeric `dollars` (not the `$%.2f` string) so a
# downstream reader reproduces this exact historical figure, plus `rate_table_id`
# (the identity of the rate table that priced it) so it can re-price the raw
# by_model under a different card. Both are null off the priced path.
COST_STATE="no_attribution"   # one of: priced | no_attribution | rate_unreadable
COST_DOLLARS_FMT=""
COST_UNPRICED=""
COST_DOLLARS_RAW="null"       # JSON number on the priced path, else null
RATE_TABLE_ID=""              # sha256:<16hex> on the priced path, else empty -> null

if jq -e 'length > 0' >/dev/null 2>&1 <<<"$BY_MODEL"; then
  cost_rates="null"
  cost_ok=false
  if cost_rt="$(gaia_resolve_rate_table "$RATE_TABLE_OVERRIDE")" && [[ -n "$cost_rt" ]]; then
    if cost_rates="$(gaia_load_rate_table "$cost_rt")"; then
      cost_ok=true
    else
      log "token-tally: rate table unreadable: $cost_rt"
    fi
  else
    log "token-tally: could not resolve rate table path"
  fi

  if [[ "$cost_ok" == "true" ]]; then
    priced="$(jq -cn --argjson rates "$cost_rates" --arg ts "$TS" --argjson bm "$BY_MODEL" \
      "$GAIA_PRICING_JQ_DEFS"'
        priced_row({ts: $ts, by_model: $bm})
      ' 2>/dev/null || true)"
    if [[ -n "$priced" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$priced"; then
      dollars="$(jq -r '.dollars' <<<"$priced" 2>/dev/null)"
      COST_DOLLARS_FMT="$(printf '$%.2f' "$dollars" 2>/dev/null)"
      # Literal fallback string, not a command sub.
      # shellcheck disable=SC2016
      [[ -z "$COST_DOLLARS_FMT" ]] && COST_DOLLARS_FMT='$0.00'
      COST_UNPRICED="$(jq -r '.unpriced | join(", ")' <<<"$priced" 2>/dev/null)"
      COST_STATE="priced"
      # Persist the raw numeric dollars only when it is a valid JSON number.
      if printf '%s' "$dollars" | jq -e 'type=="number"' >/dev/null 2>&1; then
        COST_DOLLARS_RAW="$dollars"
      fi
      # rate_table_id identifies the exact table that priced this row.
      RATE_TABLE_ID="$(rate_table_id "$cost_rt" 2>/dev/null || true)"
    else
      # pricing failed unexpectedly -> treat as unreadable, never fabricate
      COST_STATE="rate_unreadable"
    fi
  else
    COST_STATE="rate_unreadable"
  fi
fi

# Display titles: stdout uses `<feature>/<slug>`, cost.md uses `<feature> / <slug>`.
if [[ "$ACTION" == "spec" ]]; then
  out_title="$ACTION $FEATURE"
else
  out_title="$ACTION $FEATURE/$PLAN_SLUG"
fi

# ---------- ledger record (README C2), resolved to the main checkout ----------
# The main-checkout ledger path (…/cost.jsonl) comes from the shared lib, so the
# ledger filename lives in one place. A KICKOFF run inside a linked worktree
# records to the surviving main ledger. --ledger overrides (test seam).
resolve_ledger() {
  gaia_resolve_ledger_path "$LEDGER_OVERRIDE"
}

# Collision-resistant repo identity from the origin remote: normalize the URL
# (lowercase; strip a leading scheme://; strip a leading user@; ":" -> "/"; drop
# a trailing .git and slash) then sha256:<first16hex>. Two checkouts of one repo
# (https and ssh forms) normalize to the same value; two repos sharing only a
# leaf-dir name do not. No origin -> path:<first16hex(main_root)>. Echoes nothing
# (caller nulls it) when nothing resolves.
compute_project_id() {
  local url norm h common_dir abs main_root
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    norm="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
    norm="${norm#*://}"          # strip a leading scheme://
    norm="${norm#*@}"            # strip a leading user@
    norm="${norm//:/\/}"         # ":" -> "/"
    norm="${norm%.git}"          # drop a trailing .git
    norm="${norm%/}"             # drop a trailing slash
    h="$(printf '%s' "$norm" | hash16)" || return 0
    [[ -n "$h" ]] && printf 'sha256:%s' "$h"
    return 0
  fi
  # Path fallback: hash the main-checkout absolute path (same derivation the lib
  # uses for the ledger, here for the directory rather than the file).
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
  [[ -z "$common_dir" ]] && return 0
  case "$common_dir" in /*) abs="$common_dir" ;; *) abs="$PWD/$common_dir" ;; esac
  main_root="$(cd "$(dirname "$abs")" 2>/dev/null && pwd)"
  [[ -z "$main_root" ]] && return 0
  h="$(printf '%s' "$main_root" | hash16)" || return 0
  [[ -n "$h" ]] && printf 'path:%s' "$h"
}

# Best-effort: clear `final` on every PRIOR same-(feature,session) execute row so
# only the terminal (just-appended, seq==$5) row keeps final:true. Rewrites the
# whole ledger through a temp file, preserving non-matching rows AND unparseable
# lines verbatim; a corrupt line is never dropped. On any failure the ledger is
# left as-is (prior finals stay set) -- the reader's documented fallback is
# max-seq, so a failed rewrite never loses correctness. Never aborts the run.
clear_prior_finals() {
  local ledger="$1" sid="$2" spec="$3" plan="$4" newseq="$5" tmpl ledger_dir
  # mktemp into the ledger's own directory so the `mv` below is a same-filesystem
  # rename(2) (atomic), never a cross-fs copy+unlink that could expose a
  # partially written ledger. Fail-open is unchanged: an unwritable dir degrades
  # to leaving prior finals as-is (the reader's max-seq fallback stays correct).
  ledger_dir="$(dirname "$ledger")"
  tmpl="$(mktemp "$ledger_dir/.cost.jsonl.XXXXXX" 2>/dev/null)" || { log "token-tally: mktemp failed; leaving prior finals as-is"; return 0; }
  if jq -R -r -n --arg sid "$sid" --arg spec "$spec" --arg plan "$plan" --argjson newseq "$newseq" '
        inputs as $line
        | ($line | try fromjson catch null) as $o
        | if ($o | type) == "object" then
            ( if ($o.kind == "execute") and ($o.session_id == $sid)
                 and ( ($spec != "" and $o.spec_id == $spec) or ($plan != "" and $o.plan_id == $plan) )
                 and ($o.seq != $newseq)
              then $o + {final: false}
              else $o end
            ) | tojson
          else
            $line
          end
      ' "$ledger" >"$tmpl" 2>/dev/null && [[ -s "$tmpl" ]]; then
    mv "$tmpl" "$ledger" 2>/dev/null || { log "token-tally: could not replace ledger; prior finals left as-is"; rm -f "$tmpl" 2>/dev/null; }
  else
    log "token-tally: could not clear prior finals; reader falls back to max seq"
    rm -f "$tmpl" 2>/dev/null
  fi
}

ledger=""
if lp="$(resolve_ledger)" && [[ -n "$lp" ]]; then
  ledger="$lp"
else
  log "token-tally: could not resolve ledger path; skipping ledger append"
fi

# ---------- cutover (UAT-014): start a fresh cost.jsonl, move the old ledger aside
# Fires only when the resolved ledger basename is cost.jsonl, a sibling
# tokens.jsonl exists, and cost.jsonl does not yet exist -- so it is idempotent
# (never re-fires once cost.jsonl exists) and leaves non-cost.jsonl --ledger test
# runs untouched. The old ledger is moved to a .bak the contract never reads,
# never deleted, so the fresh cost.jsonl begins empty at schema_version 1 with no
# mixed-vintage rows.
if [[ -n "$ledger" && "$(basename "$ledger")" == "cost.jsonl" ]]; then
  ledger_dir="$(dirname "$ledger")"
  if [[ -f "$ledger_dir/tokens.jsonl" && ! -f "$ledger" ]]; then
    mv "$ledger_dir/tokens.jsonl" "$ledger_dir/tokens.jsonl.bak" 2>/dev/null \
      || log "token-tally: cutover move-aside failed: $ledger_dir/tokens.jsonl"
  fi
fi

# ---------- git_branch + project identity (UAT-008) ----------
GIT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
PROJECT_ID="$(compute_project_id 2>/dev/null || true)"

# ---------- seq (UAT-009) ----------
# spec/plan: one row per session -> seq 0. execute: one cumulative row per commit
# -> seq = count of PRIOR same-(feature,session) execute rows already on the
# ledger; the new row is always final:true and clears prior finals after append.
SEQ=0
if [[ "$ACTION" == "execute" && -n "$ledger" && -f "$ledger" ]]; then
  prior_count="$(jq -R -n --arg sid "$SESSION_ID" --arg spec "$SPEC_ID_OUT" --arg plan "$PLAN_ID_OUT" '
    [ inputs
      | (try fromjson catch empty)
      | select(type == "object")
      | select(.kind == "execute" and .session_id == $sid)
      | select( ($spec != "" and .spec_id == $spec) or ($plan != "" and .plan_id == $plan) )
    ] | length
  ' "$ledger" 2>/dev/null || printf '0')"
  is_uint "$prior_count" && SEQ="$prior_count"
fi

partial_bool=false
[[ "$partial" -ne 0 ]] && partial_bool=true

rec="$(jq -nc \
  --arg kind "$ACTION" \
  --arg spec_id "$SPEC_ID_OUT" \
  --arg plan_id "$PLAN_ID_OUT" \
  --arg plan_slug "$PLAN_SLUG" \
  --arg session_id "$SESSION_ID" \
  --argjson fresh "$FRESH" \
  --argjson cwrite "$CWRITE" \
  --argjson cread "$CREAD" \
  --argjson out "$OUT" \
  --argjson total "$TOTAL" \
  --argjson by_model "$BY_MODEL" \
  --argjson by_agent_type "$BY_AGENT_TYPE" \
  --argjson dollars "$COST_DOLLARS_RAW" \
  --arg rate_table_id "$RATE_TABLE_ID" \
  --argjson partial "$partial_bool" \
  --arg started "$TMIN" \
  --arg ended "$TMAX" \
  --argjson dur "${DUR_SECONDS:-null}" \
  --argjson avail "$DUR_AVAIL" \
  --arg git_branch "$GIT_BRANCH" \
  --arg project "$PROJECT_ID" \
  --argjson seq "$SEQ" \
  --arg ts "$TS" \
  --arg session_cwd "$SESSION_CWD" \
  '
    {
      schema_version: 1,
      kind: $kind,
      spec_id: (if $spec_id == "" then null else $spec_id end),
      plan_id: (if $plan_id == "" then null else $plan_id end),
      plan_slug: (if $plan_slug == "" then null else $plan_slug end),
      session_id: $session_id,
      buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $out},
      total: $total
    }
    + (if ($by_model | type) == "object" and ($by_model | length) > 0 then {by_model: $by_model} else {} end)
    + (if ($by_agent_type | type) == "object" and ($by_agent_type | length) > 0 then {by_agent_type: $by_agent_type} else {} end)
    + {
        dollars: $dollars,
        rate_table_id: (if $rate_table_id == "" then null else $rate_table_id end),
        partial: $partial,
        started_at: (if $avail then $started else null end),
        ended_at: (if $avail then $ended else null end),
        duration_seconds: (if $avail then $dur else null end),
        duration_available: $avail,
        git_branch: (if $git_branch == "" then null else $git_branch end),
        project: (if $project == "" then null else $project end),
        seq: $seq,
        final: true,
        ts: $ts,
        session_cwd: (if $session_cwd == "" then null else $session_cwd end)
      }
  ' 2>/dev/null || true)"

# cost.jsonl resolves to the main checkout, so every parallel-worktree session
# appends to one shared file. The append plus (execute only) clear_prior_finals
# is a read-modify-write hazard, so it runs inside the shared cost mutex keyed on
# the main-checkout telemetry dir; all worktrees serialize on that one lock and no
# row is lost. Nothing else moves under the lock: seq, the cutover, and cost.md
# rendering keep their pre-existing, correct behavior outside it.
#
# _cost_ledger_write holds the locked body. It reads the run globals and ALWAYS
# returns 0: a non-execute append otherwise leaves the trailing execute test false
# and the function would report failure, which with_ledger_lock passes through and
# the degrade branch (keyed strictly on the lock-timeout code) could misread.
_cost_ledger_write() {
  if printf '%s\n' "$rec" >>"$ledger" 2>/dev/null; then
    # execute: only the terminal row stays final:true (best-effort, fail-open).
    [[ "$ACTION" == "execute" ]] && clear_prior_finals "$ledger" "$SESSION_ID" "$SPEC_ID_OUT" "$PLAN_ID_OUT" "$SEQ"
  else
    log "token-tally: ledger write failed: $ledger"
  fi
  return 0
}

if [[ -n "$rec" && -n "$ledger" ]]; then
  telemetry_dir="$(dirname "$ledger")"
  mkdir -p "$telemetry_dir" 2>/dev/null   # the lock dir must exist before acquisition
  if declare -f with_ledger_lock >/dev/null 2>&1; then
    lock_rc=0
    with_ledger_lock "$telemetry_dir" _cost_ledger_write || lock_rc=$?
    if [[ "$lock_rc" -eq 75 ]]; then
      # Lock-acquisition timeout: degrade to the append WITHOUT clear_prior_finals.
      # Never skip the append; never run the rewrite unlocked. The reader's max-seq
      # fallback copes with the un-cleared prior final, so a timeout never drops a row.
      log "token-tally: cost lock timed out; appending without clear_prior_finals"
      printf '%s\n' "$rec" >>"$ledger" 2>/dev/null || log "token-tally: degraded append failed: $ledger"
    fi
  else
    # Mutex helper unavailable (source failed): preserve the never-block contract
    # with a direct, unguarded append + clear_prior_finals.
    _cost_ledger_write
  fi
elif [[ -z "$rec" ]]; then
  log "token-tally: failed to build ledger record; skipping ledger append"
fi

# ---------- cost.md rendering helpers ----------
# render_tally_body emits this run's tally as a self-contained markdown block
# (bucket table + elapsed line + optional partial marker + session/generated
# footer). It is used verbatim under a `## <phase>` heading (`## SPEC` for spec,
# `## Planning`/`## Execution` for plan/execute). It reads the aggregate globals
# computed above, all set before any call.
render_tally_body() {
  printf '| Bucket | Tokens |\n'
  printf '| --- | --- |\n'
  printf '| Fresh input | %s |\n' "$FRESH"
  printf '| Cache write | %s |\n' "$CWRITE"
  printf '| Cache read | %s |\n' "$CREAD"
  printf '| Output | %s |\n' "$OUT"
  printf '| **Total** | %s |\n\n' "$TOTAL"
  if [[ "$DUR_AVAIL" == "true" ]]; then
    printf '**Elapsed (first to last model turn):** %s (%s to %s)\n' "$HUMAN" "$LOCAL_START" "$LOCAL_END"
  else
    printf '_Elapsed: unavailable (no readable turn timestamps)._\n'
  fi
  if [[ "$partial" -ne 0 ]]; then
    printf '\n_Partial: one or more transcript inputs were missing or unparseable; figures are a lower bound._\n'
  fi
  # ---------- estimated dollar cost (SPEC-022; additive, never begins with "## ") ----------
  case "$COST_STATE" in
    rate_unreadable)
      printf '\n_Est. cost (USD): unavailable (rate table unreadable)._\n'
      ;;
    no_attribution)
      printf '\n_Est. cost (USD): unavailable (per-model attribution unavailable)._\n'
      ;;
    priced)
      printf '\n**Est. cost (USD):** %s\n' "$COST_DOLLARS_FMT"
      [[ -n "$COST_UNPRICED" ]] && printf '_Lower bound: unpriced model(s) %s._\n' "$COST_UNPRICED"
      [[ "$partial" -ne 0 ]] && printf '_Lower bound: some transcript inputs were unreadable; cost is a floor._\n'
      ;;
  esac
  # Backticks below are literal markdown (inline-code the session id), not a command sub.
  # shellcheck disable=SC2016
  printf '\nSession `%s` · generated %s\n' "$SESSION_ID" "$TS"
}

# extract_section prints a `## <title>` block from an existing cost.md: the
# heading line through the line before the next `## ` heading (or EOF), trailing
# blank lines trimmed. Absent section -> empty output. This is how a plan/execute
# write copies the SIBLING phase's section through verbatim while replacing only
# its own, so the two costs never overwrite each other. Idempotent: re-extracting
# a block this script wrote reproduces it byte-for-byte.
extract_section() {
  awk -v hdr="## $2" '
    $0 == hdr { inb = 1 }
    inb && $0 != hdr && /^## / { inb = 0 }
    inb { buf = buf $0 "\n" }
    END { sub(/\n+$/, "", buf); if (length(buf)) print buf }
  ' "$1" 2>/dev/null
}

# ---------- cost.md (README C3) ----------
# spec writes a sectioned `## SPEC` doc into the SPEC folder. plan and execute
# BOTH target the plan folder's cost.md, so they must not clobber each other:
# /gaia-plan records the `## Planning` section, the KICKOFF git-op hook records
# the `## Execution` section (rewritten on every orchestrator commit). Each write
# replaces ONLY its own section and copies the sibling through untouched, so the
# plan-authoring and plan-execution costs are tracked independently and never
# overwrite or sum. Every doc's sections are uniform `## <heading>` blocks so the
# archive consolidation can splice them.
if [[ -n "$OUT_DIR" ]]; then
  mkdir -p "$OUT_DIR" 2>/dev/null
  md_file="$OUT_DIR/cost.md"

  if [[ "$ACTION" == "plan" || "$ACTION" == "execute" ]]; then
    if [[ "$ACTION" == "plan" ]]; then section="Planning"; else section="Execution"; fi

    # Copy through whatever the sibling phase already recorded (empty on the
    # first write of either phase), then overwrite only this run's section.
    prev_planning=""
    prev_execution=""
    if [[ -f "$md_file" ]]; then
      prev_planning="$(extract_section "$md_file" "Planning")"
      prev_execution="$(extract_section "$md_file" "Execution")"
    fi
    cur_block="$(printf '## %s\n\n%s' "$section" "$(render_tally_body)")"
    if [[ "$section" == "Planning" ]]; then
      prev_planning="$cur_block"
    else
      prev_execution="$cur_block"
    fi

    # Always emit Planning before Execution, independent of which ran first. The
    # trailing `:` keeps the group's exit status tied to the redirect (could the
    # file be opened?), not to the last `[[ ]]` test, which is false whenever the
    # sibling section is absent -- so a plan-only write no longer logs a spurious
    # write failure.
    {
      printf '# Cost: %s / %s\n\n' "$FEATURE" "$PLAN_SLUG"
      [[ -n "$prev_planning" ]] && printf '%s\n\n' "$prev_planning"
      [[ -n "$prev_execution" ]] && printf '%s\n' "$prev_execution"
      :
    } >"$md_file" 2>/dev/null || log "token-tally: cost.md write failed: $md_file"
  else
    # spec: a sectioned SPEC-root doc (`# Cost: <feature>` + `## SPEC` body) so
    # the archive consolidation splices it uniformly with plan/execute sections.
    {
      printf '# Cost: %s\n\n' "$FEATURE"
      printf '## SPEC\n\n'
      render_tally_body
    } >"$md_file" 2>/dev/null || log "token-tally: cost.md write failed: $md_file"
  fi
fi

# ---------- stdout tally block (README C4) ----------
printf 'Cost (%s):\n' "$out_title"
printf '  Fresh input:  %s\n' "$FRESH"
printf '  Cache write:  %s\n' "$CWRITE"
printf '  Cache read:   %s\n' "$CREAD"
printf '  Output:       %s\n' "$OUT"
printf '  Total:        %s\n' "$TOTAL"
if [[ "$DUR_AVAIL" == "true" ]]; then
  printf '  Elapsed:      %s  (first to last model turn: %s to %s)\n' "$HUMAN" "$LOCAL_START" "$LOCAL_END"
else
  printf '  Elapsed:      unavailable (no readable turn timestamps)\n'
fi
if [[ "$partial" -ne 0 ]]; then
  printf '  (partial: figures are a lower bound; some inputs were unreadable)\n'
fi

exit 0
