#!/usr/bin/env bash
# GAIA cost-accounting tally helper.
#
# Reads the ground-truth token usage the API already recorded for a GAIA action
# (/gaia-spec, /gaia-plan, or a KICKOFF plan-execution run) and turns it into a
# per-action readout: four billing buckets plus a total, an elapsed
# span, a durable machine-local ledger record (cost.jsonl), a per-folder
# cost.json sidecar keyed by phase kind, and a printed tally block.
#
# It sums `.message.usage` across the session's MAIN transcript
# (<projects-root>/*/<session-id>.jsonl) AND every sub-agent sidecar
# (<projects-root>/*/<session-id>/subagents/agent-*.jsonl). A single assistant
# message is streamed across MULTIPLE JSONL lines that repeat the same
# `.message.id` and the same usage, so the tally DEDUPS by `.message.id`
# (fallback `.uuid`) before summing; without this it overcounts output ~3x.
#
# Alongside the tokens it reports elapsed time = max(.timestamp) -
# min(.timestamp) over the usage-bearing lines (first to last billed model turn),
# across main + sidecars. Bookkeeping lines (pr-link/system/attachment) and
# leading user think-time carry no usage and are excluded, so the span sits on
# real work. Epoch conversion is jq-only (`fromdateiso8601`, UTC on every
# platform); the `date` binary is NEVER used to parse transcript timestamps
# (`date -j -f` ignores the Z and halves a span across a DST boundary, and
# `date -j` is macOS-only, which breaks the Linux CI bats run).
#
# The ledger stores the raw UTC endpoints (C2, the durable machine record); the
# HUMAN surface (stdout) renders those two endpoints in the machine's
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
#   - Side effects: append one ledger record; write <out-dir>/cost.json. For
#     action=plan|execute the sidecar carries independent `plan` and `execute`
#     keys; each run replaces ONLY its own key and copies the sibling through
#     byte-unchanged, so the plan-authoring cost (written by /gaia-plan) and
#     the plan-execution cost (written by the KICKOFF git-op hook on each
#     commit) never overwrite or sum. action=spec writes a `spec`-keyed
#     sidecar into the SPEC folder, a separate file that is unaffected.
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
# A second CLI shape, one standalone unattributed row per maintenance-command
# run, carrying the GitHub artifact (if any) that run produced:
#   bash .gaia/scripts/token-tally.sh --action command --command <name> \
#     [--run-id <id>] \
#     [--github-type pr|issue] [--github-number <int>] [--github-repo <owner>/<name>] \
#     [--session-id <id>] [--projects-root <dir>] [--ledger <path>] \
#     [--rate-table <path>] [--cache-dir <dir>]
#
# `--command` is validated against a closed set of the maintenance commands; an
# unrecognized or absent value degrades to a partial row rather than a crash or
# a fabricated name. `--run-id` is a test seam (production callers omit it and
# get a generated id). The three `--github-*` flags are the ONLY source of the
# `github` object on a command record, no breadcrumb is ever read for this
# action; an incomplete or invalid set just omits `github`, never marks
# partial. `--action execute` additionally reads (and never deletes) the
# gh-artifact breadcrumb .claude/hooks/capture-gh-artifact.sh writes, so its
# `github` object comes from that breadcrumb instead.
#
# DO NOT add `set -e`; each step is guarded independently so one failure cannot
# abort the never-block guarantee.

# shellcheck source=.gaia/scripts/token-pricing-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/token-pricing-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/ledger-path-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/ledger-path-lib.sh" 2>/dev/null || true
# shellcheck source=.specify/extensions/gaia/lib/with-ledger-lock.sh
. "$(dirname "${BASH_SOURCE[0]}")/../../.specify/extensions/gaia/lib/with-ledger-lock.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/audit-window-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/audit-window-lib.sh" 2>/dev/null || true
# shellcheck source=.gaia/scripts/gh-artifact-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/gh-artifact-lib.sh" 2>/dev/null || true

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

# Collision-resistant repo identity from the origin remote: normalize the URL
# (lowercase; strip a leading scheme://; strip a leading user@; ":" -> "/"; drop
# a trailing .git and slash) then sha256:<first16hex>. Two checkouts of one repo
# (https and ssh forms) normalize to the same value; two repos sharing only a
# leaf-dir name do not. No origin -> path:<first16hex(main_root)>. Echoes nothing
# (caller nulls it) when nothing resolves.
#
# Defined here (rather than near its call site further down) so both the
# --action review branch and the phase-action path below can call it before
# either is textually reached.
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
CACHE_DIR_ARG=""
COMMAND_ARG=""
RUN_ID_ARG=""
GITHUB_TYPE_ARG=""
GITHUB_NUMBER_ARG=""
GITHUB_REPO_ARG=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case "$key" in
    --action|--spec-id|--plan-id|--plan-slug|--out-dir|--session-id|--projects-root|--ledger|--rate-table|--cache-dir|--command|--run-id|--github-type|--github-number|--github-repo)
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
        --cache-dir)     CACHE_DIR_ARG="$val" ;;
        --command)       COMMAND_ARG="$val" ;;
        --run-id)        RUN_ID_ARG="$val" ;;
        --github-type)   GITHUB_TYPE_ARG="$val" ;;
        --github-number) GITHUB_NUMBER_ARG="$val" ;;
        --github-repo)   GITHUB_REPO_ARG="$val" ;;
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
# The single feature key used for the stdout title and the seq/final match.
FEATURE="${SPEC_ID_OUT:-$PLAN_ID_OUT}"

# Missing required flags are belt-and-suspenders (callers pass well-formed args);
# degrade to partial rather than crash. --action review/command are exempt from
# the feature-identity and --out-dir checks (COV-001): both kinds are
# legitimately unattributed (both ids null is valid, not a defect) and write no
# cost.json sidecar, so neither absence may mark them partial (UAT-007, the
# SPEC's never-mark-partial clause).
if [[ "$ACTION" != "review" && "$ACTION" != "command" ]]; then
  [[ -z "$FEATURE" ]] && { log "token-tally: no feature identity (--spec-id SPEC-* or --plan-id PLAN-*)"; partial=1; }
  [[ -z "$OUT_DIR" ]] && { log "token-tally: missing --out-dir"; partial=1; }
fi
[[ -z "$ACTION" ]]  && { log "token-tally: missing --action"; partial=1; }
if [[ "$ACTION" == "plan" || "$ACTION" == "execute" ]] && [[ -z "$PLAN_SLUG" ]]; then
  log "token-tally: missing --plan-slug for action=$ACTION"
  partial=1
fi
[[ -z "$SESSION_ID" ]] && { log "token-tally: no session id (--session-id or CLAUDE_CODE_SESSION_ID)"; partial=1; }

# ---------- --command validation + run_id generation (--action command only) ----------
# Closed set: an unrecognized value is carried through verbatim into `command`
# and sets partial; an absent value writes command:null and sets partial.
# Never crashes, never fabricates a name (mirrors the SPEC-*/PLAN-* prefix
# degrade above).
COMMAND_OUT=""
RUN_ID_OUT=""
if [[ "$ACTION" == "command" ]]; then
  case "$COMMAND_ARG" in
    gaia-audit|gaia-debt|gaia-fitness|gaia-forensics|gaia-harden|gaia-wiki)
      COMMAND_OUT="$COMMAND_ARG"
      ;;
    "")
      log "token-tally: missing --command for action=command"
      partial=1
      ;;
    *)
      log "token-tally: unrecognized --command value: $COMMAND_ARG"
      COMMAND_OUT="$COMMAND_ARG"
      partial=1
      ;;
  esac

  # run_id: <slug>-<YYYYMMDDTHHMMSSZ>-<4 lowercase hex>. --run-id overrides
  # verbatim (a test seam; production callers omit it). The hex suffix is not
  # a uniqueness guarantee, only what keeps two same-second runs distinct.
  if [[ -n "$RUN_ID_ARG" ]]; then
    RUN_ID_OUT="$RUN_ID_ARG"
  else
    run_slug="$(printf '%s' "$COMMAND_ARG" | tr -dc 'A-Za-z0-9._-')"
    [[ -z "$run_slug" ]] && run_slug="unknown"
    run_hex="$(printf '%04x' "$((RANDOM % 65536))")"
    RUN_ID_OUT="${run_slug}-$(date -u +%Y%m%dT%H%M%SZ)-${run_hex}"
  fi
fi

# ---------- github pass-through for --action command (FC-4/FC-5; no breadcrumb read) ----------
# Built ONLY from --github-* flags: never looked up, never reused across runs,
# never guessed. Any missing/invalid flag omits the key entirely and logs to
# stderr; the artifact's absence never marks the record partial. The repo
# slug's character class is validated in bash BEFORE it ever reaches jq, and
# only ever through --arg/--argjson, never string interpolation.
GITHUB_JSON=""
if [[ "$ACTION" == "command" ]]; then
  if [[ "$GITHUB_TYPE_ARG" == "pr" || "$GITHUB_TYPE_ARG" == "issue" ]] \
     && [[ "$GITHUB_NUMBER_ARG" =~ ^[1-9][0-9]*$ ]] \
     && [[ "$GITHUB_REPO_ARG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    GITHUB_JSON="$(jq -nc --arg type "$GITHUB_TYPE_ARG" --argjson number "$GITHUB_NUMBER_ARG" --arg repo "$GITHUB_REPO_ARG" \
      '{type: $type, number: $number, repo: $repo}' 2>/dev/null || true)"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$GITHUB_JSON" || GITHUB_JSON=""
  elif [[ -n "$GITHUB_TYPE_ARG$GITHUB_NUMBER_ARG$GITHUB_REPO_ARG" ]]; then
    log "token-tally: incomplete/invalid --github-* flags for action=command; omitting github"
  fi
fi

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
# emit_file <path> <bkt> <file_id>: <file_id> stamps the FILE's own identity
# ("" for the main transcript, the sidecar basename sans .jsonl for a sidecar)
# alongside <bkt> (the FILE's agent type: "main" or the sidecar's agentType),
# so the audit-window-lib (SPEC-032 FC-5) can select records by sidecar
# identity/window. The per-usage-entry `b` tag (compaction override included)
# is untouched -- only two new FILE-level keys are added to the emitted line.
emit_file() {
  jq -cn --arg bkt "$2" --arg fid "$3" '
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
    | {usage: (.usage | to_entries | map({id: .key, u: .value.u, m: .value.m, b: .value.b})),
       tmin, tmax, file_agent: $bkt, file_id: $fid}
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
      emit_file "$f" "main" ""
      main_found=1
      break
    fi
  done
  [[ "$main_found" -eq 0 ]] && { log "token-tally: no main transcript for session $SESSION_ID"; partial=1; }

  # Sidecars: zero matches is fine (a session may fan out no sub-agents), NOT
  # partial. The agent-*.jsonl glob excludes the sibling agent-*.meta.json files.
  for f in "$PROJECTS_ROOT"/*/"$SESSION_ID"/subagents/agent-*.jsonl; do
    if [[ -f "$f" ]]; then
      sidecar_file_id="$(basename "$f")"
      sidecar_file_id="${sidecar_file_id%.jsonl}"
      emit_file "$f" "$(sidecar_agent_type "$f")" "$sidecar_file_id"
    fi
  done
fi

# ---------- --action review: standalone FC-3 records, no phase record ----------
# A distinct path, branched early (before the phase aggregate/pricing/rec
# machinery below): scans this session's sidecars for code-review-audit runs
# and appends one standalone kind:"review" ledger row per run not already
# recorded, then exits. It never builds a phase aggregate, never nests an
# audit annotation, and never writes a cost.json sidecar (a review is not
# phase-keyed). --spec-id/--plan-id/--out-dir are all optional here; the
# feature-identity and --out-dir partial checks above are already skipped for
# this action (COV-001).
if [[ "$ACTION" == "review" ]]; then
  windows="$(gaia_review_windows "$tmp")"
  win_count="$(jq -r 'length' <<<"$windows" 2>/dev/null)"
  is_uint "$win_count" || win_count=0

  if [[ "$win_count" -eq 0 ]]; then
    log "token-tally: no code-review-audit run in session"
    [[ -n "$tmp" ]] && rm -f "$tmp" 2>/dev/null
    exit 0
  fi

  ledger=""
  if lp="$(gaia_resolve_ledger_path "$LEDGER_OVERRIDE")" && [[ -n "$lp" ]]; then
    ledger="$lp"
  else
    log "token-tally: could not resolve ledger path; skipping review append"
    [[ -n "$tmp" ]] && rm -f "$tmp" 2>/dev/null
    exit 0
  fi

  # Cutover (mirrors the phase path below): the first cost.jsonl append moves a
  # legacy tokens.jsonl sibling aside, exactly once, idempotent thereafter.
  if [[ "$(basename "$ledger")" == "cost.jsonl" ]]; then
    ledger_dir="$(dirname "$ledger")"
    if [[ -f "$ledger_dir/tokens.jsonl" && ! -f "$ledger" ]]; then
      mv "$ledger_dir/tokens.jsonl" "$ledger_dir/tokens.jsonl.bak" 2>/dev/null \
        || log "token-tally: cutover move-aside failed: $ledger_dir/tokens.jsonl"
    fi
  fi

  GIT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
  PROJECT_ID="$(compute_project_id 2>/dev/null || true)"
  TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  partial_bool=false
  [[ "$partial" -ne 0 ]] && partial_bool=true

  # Resolve the rate table ONCE for every review record this run produces
  # (never re-resolved per window).
  review_cost_ok=false
  review_rt=""
  review_rates="null"
  if review_rt="$(gaia_resolve_rate_table "$RATE_TABLE_OVERRIDE")" && [[ -n "$review_rt" ]]; then
    if review_rates="$(gaia_load_rate_table "$review_rt")"; then
      review_cost_ok=true
    else
      log "token-tally: rate table unreadable: $review_rt"
    fi
  else
    log "token-tally: could not resolve rate table path"
  fi

  telemetry_dir="$(dirname "$ledger")"
  mkdir -p "$telemetry_dir" 2>/dev/null   # the lock dir must exist before acquisition

  _review_ledger_write() {
    printf '%s\n' "$r_rec" >>"$ledger" 2>/dev/null || log "token-tally: ledger write failed: $ledger"
    return 0
  }

  while IFS= read -r w; do
    [[ -z "$w" ]] && continue
    review_id="$(jq -r '.review_id // empty' <<<"$w")"
    w_started="$(jq -r '.started_at // empty' <<<"$w")"
    w_ended="$(jq -r '.ended_at // empty' <<<"$w")"
    [[ -z "$review_id" ]] && continue

    # Dedup: skip a review_id already on the ledger (idempotent across both the
    # Stop-hook and the gh-pr-merge triggers, and across repeat runs).
    dup_count="$(jq -R -n --arg rid "$review_id" '
      [ inputs
        | (try fromjson catch empty)
        | select(type == "object")
        | select(.kind == "review" and .review_id == $rid)
      ] | length
    ' "$ledger" 2>/dev/null || printf '0')"
    is_uint "$dup_count" || dup_count=0
    if [[ "$dup_count" -gt 0 ]]; then
      log "token-tally: review $review_id already recorded; skipping"
      continue
    fi

    # Unfiltered $tmp: this IS the review's own window (never tmp_phase, which
    # excludes code-review-audit windows for the PHASE path only).
    subset="$(gaia_window_subset "$tmp" "$w_started" "$w_ended")"

    r_fresh="$(jq -r '.buckets.fresh_input' <<<"$subset" 2>/dev/null)"
    r_cwrite="$(jq -r '.buckets.cache_write' <<<"$subset" 2>/dev/null)"
    r_cread="$(jq -r '.buckets.cache_read' <<<"$subset" 2>/dev/null)"
    r_output="$(jq -r '.buckets.output' <<<"$subset" 2>/dev/null)"
    is_uint "$r_fresh"  || r_fresh=0
    is_uint "$r_cwrite" || r_cwrite=0
    is_uint "$r_cread"  || r_cread=0
    is_uint "$r_output" || r_output=0
    r_total=$(( r_fresh + r_cwrite + r_cread + r_output ))

    r_count="$(jq -r '.count' <<<"$subset" 2>/dev/null)"
    is_uint "$r_count" || r_count=0
    r_dur="$(jq -r '.elapsed_seconds' <<<"$subset" 2>/dev/null)"
    r_avail=false
    if [[ "$r_count" -gt 0 ]] && is_uint "$r_dur"; then
      r_avail=true
    else
      r_dur=""
    fi

    r_by_model="$(jq -c '.by_model' <<<"$subset" 2>/dev/null)"
    jq -e 'type=="object"' >/dev/null 2>&1 <<<"$r_by_model" || r_by_model='{}'
    r_dollars="null"
    r_rtid=""
    if [[ "$review_cost_ok" == "true" ]] && jq -e 'length > 0' >/dev/null 2>&1 <<<"$r_by_model"; then
      r_priced="$(jq -cn --argjson rates "$review_rates" --arg ts "$TS" --argjson bm "$r_by_model" \
        "$GAIA_PRICING_JQ_DEFS"'
          priced_row({ts: $ts, by_model: $bm})
        ' 2>/dev/null || true)"
      if [[ -n "$r_priced" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$r_priced"; then
        r_d="$(jq -r '.dollars' <<<"$r_priced" 2>/dev/null)"
        if printf '%s' "$r_d" | jq -e 'type=="number"' >/dev/null 2>&1; then
          r_dollars="$r_d"
        fi
        r_rtid="$(rate_table_id "$review_rt" 2>/dev/null || true)"
      fi
    fi

    r_rec="$(jq -nc \
      --arg session_id "$SESSION_ID" \
      --argjson fresh "$r_fresh" \
      --argjson cwrite "$r_cwrite" \
      --argjson cread "$r_cread" \
      --argjson out "$r_output" \
      --argjson total "$r_total" \
      --argjson by_model "$r_by_model" \
      --argjson dollars "$r_dollars" \
      --arg rate_table_id "$r_rtid" \
      --argjson partial "$partial_bool" \
      --arg started "$w_started" \
      --arg ended "$w_ended" \
      --argjson dur "${r_dur:-null}" \
      --argjson avail "$r_avail" \
      --arg git_branch "$GIT_BRANCH" \
      --arg project "$PROJECT_ID" \
      --arg ts "$TS" \
      --arg session_cwd "$SESSION_CWD" \
      --arg spec_id "$SPEC_ID_OUT" \
      --arg plan_id "$PLAN_ID_OUT" \
      --arg review_id "$review_id" \
      '
        {
          schema_version: 1,
          kind: "review",
          spec_id: (if $spec_id == "" then null else $spec_id end),
          plan_id: (if $plan_id == "" then null else $plan_id end),
          plan_slug: null,
          session_id: $session_id,
          buckets: {fresh_input: $fresh, cache_write: $cwrite, cache_read: $cread, output: $out},
          total: $total
        }
        + (if ($by_model | type) == "object" and ($by_model | length) > 0 then {by_model: $by_model} else {} end)
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
            seq: 0,
            final: true,
            ts: $ts,
            session_cwd: (if $session_cwd == "" then null else $session_cwd end),
            source: "code-review-audit",
            review_id: $review_id
          }
      ' 2>/dev/null || true)"

    if [[ -n "$r_rec" ]]; then
      if declare -f with_ledger_lock >/dev/null 2>&1; then
        lock_rc=0
        with_ledger_lock "$telemetry_dir" _review_ledger_write || lock_rc=$?
        if [[ "$lock_rc" -eq 75 ]]; then
          log "token-tally: review lock timed out; appending without lock"
          printf '%s\n' "$r_rec" >>"$ledger" 2>/dev/null || log "token-tally: degraded review append failed: $ledger"
        fi
      else
        _review_ledger_write
      fi
      log "token-tally: recorded review $review_id"
    else
      log "token-tally: failed to build review record for $review_id"
    fi
  done < <(jq -c '.[]' <<<"$windows" 2>/dev/null)

  [[ -n "$tmp" ]] && rm -f "$tmp" 2>/dev/null
  exit 0
fi

# ---------- exclude any code-review-audit window from a phase tally ----------
# Double-count guard (AUDIT directive #3): a review run's spend must land ONLY
# in its own standalone kind:"review" row, never also folded into a phase
# total. $tmp stays intact (unused by phase actions past this point); the
# aggregate + BY_MODEL + BY_AGENT_TYPE + duration below all read $tmp_phase.
# In an authoring session with no code-review-audit sidecars this is a byte
# no-op (tmp_phase == tmp; the lib's own degrade guarantees this).
tmp_phase="$tmp"
# Guard on function existence only: a missing/unsourced audit-window-lib.sh
# (e.g. a partial /update-gaia mid-upgrade) must degrade to NO exclusion, not
# an empty stream that would zero out $tmp_phase and fabricate a 0 total.
if [[ -n "$tmp" && -s "$tmp" ]] && declare -F gaia_exclude_review_windows >/dev/null 2>&1; then
  tmp_phase_candidate="$(mktemp 2>/dev/null)" || tmp_phase_candidate=""
  if [[ -n "$tmp_phase_candidate" ]]; then
    gaia_exclude_review_windows "$tmp" >"$tmp_phase_candidate" 2>/dev/null
    tmp_phase="$tmp_phase_candidate"
  fi
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
if [[ -n "$tmp_phase" && -s "$tmp_phase" ]]; then
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
    ' "$tmp_phase" 2>/dev/null || printf '0\t0\t0\t0\t\t\n'
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
  ' "$tmp_phase" 2>/dev/null)"
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
  ' "$tmp_phase" 2>/dev/null)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$BY_AGENT_TYPE" || BY_AGENT_TYPE='{}'
fi
# $tmp itself is no longer needed for a phase action (the aggregate above, and
# the FC-2 audit-nesting block further down, both read $tmp_phase). $tmp_phase
# stays alive until after that block runs, so its cleanup is deferred to just
# before the ledger-record build.
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
# Each run's cost.json record prices its OWN in-process BY_MODEL at the rate
# whose effective window covers TS (this run's generation stamp) -- a frozen
# snapshot, deliberately distinct from token-rollup.sh's read-time reprice.
# Never guesses, never blocks: empty attribution or an unreadable rate table
# degrade to a marked "unavailable" line rather than a fabricated figure.
#
# The ledger persists the RAW numeric `dollars` (not a formatted string) so a
# downstream reader reproduces this exact historical figure, plus `rate_table_id`
# (the identity of the rate table that priced it) so it can re-price the raw
# by_model under a different card. Both are null off the priced path.
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
      # Persist the raw numeric dollars only when it is a valid JSON number.
      if printf '%s' "$dollars" | jq -e 'type=="number"' >/dev/null 2>&1; then
        COST_DOLLARS_RAW="$dollars"
      fi
      # rate_table_id identifies the exact table that priced this row.
      RATE_TABLE_ID="$(rate_table_id "$cost_rt" 2>/dev/null || true)"
    fi
    # else: pricing failed unexpectedly -> leave dollars/rate_table_id null,
    # never fabricate.
  fi
  # else: rate table unresolvable/unreadable -> leave dollars/rate_table_id null.
fi

# ---------- CACHE_DIR resolution (hoisted): spec/plan's FC-2 audit-window
#            breadcrumb AND execute's FC-6 gh-artifact breadcrumb both resolve
#            through this one derivation. --cache-dir (test seam) defaults to
#            <main_root>/.gaia/local/cache, deriving main_root the same
#            git-common-dir way ledger-path-lib.sh derives the ledger main_root
#            -- NOT via compute_project_id, which returns a hash, not a path
#            (CG-002). A command or review run pays nothing for this (guarded
#            out below).
CACHE_DIR=""
if [[ "$ACTION" == "spec" || "$ACTION" == "plan" || "$ACTION" == "execute" ]]; then
  CACHE_DIR="$CACHE_DIR_ARG"
  if [[ -z "$CACHE_DIR" ]]; then
    audit_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"
    if [[ -n "$audit_common_dir" ]]; then
      case "$audit_common_dir" in
        /*) audit_abs="$audit_common_dir" ;;
        *)  audit_abs="$PWD/$audit_common_dir" ;;
      esac
      audit_main_root="$(cd "$(dirname "$audit_abs")" 2>/dev/null && pwd)"
      [[ -n "$audit_main_root" ]] && CACHE_DIR="$audit_main_root/.gaia/local/cache"
    fi
  fi
fi

# ---------- git_branch (moved up: FC-6's execute breadcrumb read below needs
#            it before the record build; project identity stays at its
#            original site further down) ----------
GIT_BRANCH="$(git branch --show-current 2>/dev/null || true)"

# ---------- FC-2: nest the adversarial-audit annotation (spec/plan only) ----------
# A strict subset drill-down of the phase record just aggregated above: never
# summed into total/buckets/dollars, and omitted entirely (never fabricated)
# when the breadcrumb is absent/unparseable, its session_id does not match
# this tally's session, or its window catches zero sidecar activity.
AUDIT_JSON=""
if [[ "$ACTION" == "spec" || "$ACTION" == "plan" ]]; then
  # The breadcrumb key MUST match what task-breadcrumb-emit writes (FC-1,
  # DP-002 / CG-001): spec -> $SPEC_ID_OUT; spec-derived plan -> "<spec_id>-plan"
  # (namespaced by the SPEC id, never $PLAN_SLUG, which is the literal
  # "plan"/"plan-2" identical across every SPEC); SPEC-less plan -> $PLAN_ID_OUT.
  if [[ "$ACTION" == "spec" ]]; then
    audit_feature="$SPEC_ID_OUT"
  elif [[ -n "$SPEC_ID_OUT" ]]; then
    audit_feature="${SPEC_ID_OUT}-plan"
  else
    audit_feature="$PLAN_ID_OUT"
  fi

  if [[ -n "$CACHE_DIR" && -n "$audit_feature" ]]; then
    breadcrumb="$CACHE_DIR/audit-window-${audit_feature}.json"
    bc="$(gaia_audit_window_read "$breadcrumb")"

    if [[ -n "$bc" ]]; then
      bc_session="$(jq -r '.session_id // empty' <<<"$bc")"
      if [[ -n "$SESSION_ID" && "$bc_session" == "$SESSION_ID" ]]; then
        bc_started="$(jq -r '.started_at // empty' <<<"$bc")"
        bc_ended="$(jq -r '.ended_at // empty' <<<"$bc")"
        bc_lenses="$(jq -c '.lenses // []' <<<"$bc")"
        jq -e 'type=="array"' >/dev/null 2>&1 <<<"$bc_lenses" || bc_lenses='[]'
        bc_intensity="$(jq -r '.intensity // empty' <<<"$bc")"

        # Computed from $tmp_phase (the SAME deduped survivor stream the phase
        # total above aggregates), never a fresh re-read: because the subset is
        # a window-filtered subset of the same sidecar files, each audit bucket
        # is <= the phase bucket by construction (UAT-003).
        audit_subset="$(gaia_window_subset "$tmp_phase" "$bc_started" "$bc_ended")"
        audit_count="$(jq -r '.count' <<<"$audit_subset" 2>/dev/null)"
        is_uint "$audit_count" || audit_count=0

        if [[ "$audit_count" -gt 0 ]]; then
          audit_by_model="$(jq -c '.by_model' <<<"$audit_subset" 2>/dev/null)"
          jq -e 'type=="object"' >/dev/null 2>&1 <<<"$audit_by_model" || audit_by_model='{}'
          audit_dollars="null"
          # Reuse the SAME cost_rt/cost_rates resolved for the phase dollars
          # above; never resolve the rate table a second time. cost_ok is
          # unset (falsy) when BY_MODEL was empty, which safely degrades this
          # to null (a subset of an empty-attribution phase is also empty).
          if [[ "$cost_ok" == "true" ]] && jq -e 'length > 0' >/dev/null 2>&1 <<<"$audit_by_model"; then
            audit_priced="$(jq -cn --argjson rates "$cost_rates" --arg ts "$TS" --argjson bm "$audit_by_model" \
              "$GAIA_PRICING_JQ_DEFS"'
                priced_row({ts: $ts, by_model: $bm})
              ' 2>/dev/null || true)"
            if [[ -n "$audit_priced" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$audit_priced"; then
              audit_d="$(jq -r '.dollars' <<<"$audit_priced" 2>/dev/null)"
              if printf '%s' "$audit_d" | jq -e 'type=="number"' >/dev/null 2>&1; then
                audit_dollars="$audit_d"
              fi
            fi
          fi

          AUDIT_JSON="$(jq -nc \
            --argjson buckets "$(jq -c '.buckets' <<<"$audit_subset")" \
            --argjson dollars "$audit_dollars" \
            --argjson elapsed "$(jq -r '.elapsed_seconds' <<<"$audit_subset")" \
            --argjson lenses "$bc_lenses" \
            --arg intensity "$bc_intensity" \
            '
              {
                adversarial: (
                  {buckets: $buckets, dollars: $dollars, elapsed_seconds: $elapsed, lenses: $lenses}
                  + (if $intensity != "" then {intensity: $intensity} else {} end)
                )
              }
            ' 2>/dev/null || true)"
        fi
        # else: window caught zero sidecar activity -> omit (degrade, never a
        # zero-filled/fabricated object).
      fi
      # else: breadcrumb session_id != this tally's session -> omit (resume/
      # degrade, UAT-009); never attribute another session's audit.

      # Consume the breadcrumb: the phase tally is its only reader, and it has
      # now made its decision either way (nested, or omitted because the
      # session no longer matches / the window caught nothing). A breadcrumb
      # that was absent/unparseable in the first place has nothing to remove.
      rm -f "$breadcrumb" 2>/dev/null || true
    fi
  fi
fi

# $tmp_phase's last reader was the FC-2 block just above; safe to remove now.
[[ -n "$tmp_phase" && "$tmp_phase" != "$tmp" ]] && rm -f "$tmp_phase" 2>/dev/null

# ---------- FC-6: github on --action execute (breadcrumb, read-only, never deletes) ----------
# --action execute only; spec/plan/review/command never read it. A match
# requires the breadcrumb's session_id AND branch to equal this run's, and its
# ts to be within the TTL (the lib enforces all three); the lib never deletes
# it, so every cumulative commit-triggered row re-reads the same breadcrumb.
# The lib being absent/unsourceable, or nothing matching, both just omit
# `github`, never fail.
if [[ "$ACTION" == "execute" ]] && declare -F gaia_gh_artifact_read >/dev/null 2>&1; then
  gh_bc_path="$(gaia_gh_artifact_path "$CACHE_DIR")"
  if [[ -n "$gh_bc_path" ]]; then
    gh_bc="$(gaia_gh_artifact_read "$gh_bc_path" "$SESSION_ID" "$GIT_BRANCH")"
    if [[ -n "$gh_bc" ]] && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$gh_bc"; then
      GITHUB_JSON="$gh_bc"
    fi
  fi
fi

# Display title: stdout uses `<feature>/<slug>`.
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

# ---------- project identity (UAT-008; git_branch is computed earlier, before
#            the CACHE_DIR/FC-2/FC-6 breadcrumb block, which needs it) ----------
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
  --arg audit_json "$AUDIT_JSON" \
  --arg command_val "$COMMAND_OUT" \
  --arg run_id_val "$RUN_ID_OUT" \
  --arg github_json "$GITHUB_JSON" \
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
    + (if $audit_json != "" then {audit: ($audit_json | fromjson)} else {} end)
    + (if $kind == "command" then {command: (if $command_val == "" then null else $command_val end), run_id: $run_id_val} else {} end)
    + (if $github_json != "" then {github: ($github_json | fromjson)} else {} end)
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
# row is lost. Nothing else moves under the lock: seq, the cutover, and the
# cost.json sidecar write keep their pre-existing, correct behavior outside it.
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

# ---------- cost.json sidecar (README C3; FC-1) ----------
# One object keyed by phase kind: {"spec":<rec>} for a spec folder, and
# {"plan":<rec>, "execute":<rec>} for a plan folder. Each value is the same
# record shape appended to the central cost.jsonl. A plan/execute write replaces
# ONLY its own key and copies the sibling key through byte-unchanged, so the
# plan-authoring cost (written by /gaia-plan) and the plan-execution cost
# (written by the KICKOFF git-op hook on each commit) never overwrite or sum.
# Never blocks: a jq failure leaves the prior sidecar untouched and logs to
# stderr; it never aborts the tally and never fabricates. A command record is
# unattributed and sidecar-less like review: no cost.json, ever, even if
# --out-dir is somehow supplied.
if [[ -n "$OUT_DIR" && -n "$rec" && "$ACTION" != "command" ]]; then
  mkdir -p "$OUT_DIR" 2>/dev/null
  sidecar="$OUT_DIR/cost.json"
  if [[ -f "$sidecar" ]]; then
    updated="$(jq -c --argjson rec "$rec" --arg k "$ACTION" '. + {($k): $rec}' "$sidecar" 2>/dev/null || true)"
  else
    updated="$(jq -cn --argjson rec "$rec" --arg k "$ACTION" '{($k): $rec}' 2>/dev/null || true)"
  fi
  if [[ -n "$updated" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$updated"; then
    printf '%s\n' "$updated" >"$sidecar" 2>/dev/null || log "token-tally: cost.json write failed: $sidecar"
  else
    log "token-tally: could not build cost.json; leaving prior sidecar as-is"
  fi
fi

# ---------- stdout tally block (README C4; FC-7 for --action command) ----------
if [[ "$ACTION" == "command" ]]; then
  # Exactly one line, no per-stage breakdown (a command run has one stage), so
  # every command surface relays a byte-identical line. Never bash integer
  # arithmetic (it would truncate); LC_ALL=C keeps a locale's comma decimal
  # separator from leaking in.
  t_human="$(LC_ALL=C awk -v t="$TOTAL" 'BEGIN{printf "%.1f", t/1000000}')"
  if [[ "$COST_DOLLARS_RAW" == "null" ]]; then
    cost_part="cost unavailable"
  else
    cost_part="$(LC_ALL=C awk -v d="$COST_DOLLARS_RAW" 'BEGIN{printf "$%.2f", d}')"
  fi
  line="Cost: ~${t_human}M tokens, ${cost_part}"
  [[ "$DUR_AVAIL" == "true" ]] && line="${line}, ${HUMAN}"
  [[ "$partial" -ne 0 ]] && line="${line} (partial: lower bound)"
  printf '%s\n' "$line"
else
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
fi

exit 0
