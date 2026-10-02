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
# (<projects-root>/*/<session-id>/subagents/agent-*.jsonl, plus a Workflow run's
# subagents/workflows/wf_*/agent-*.jsonl). A single assistant
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
#     [--rate-table <path>] [--cache-dir <dir>] [--branch-name <branch>]
#
# `--branch-name` (any action) records the given branch as `git_branch` in place
# of the ambient `git branch --show-current`. It exists because the prescribed
# merge paths clean up before the tally runs: feature-branch cleanup checks main
# out and worktree cleanup leaves the worktree, so by then the ambient answer is
# main, not the branch the work was done on. The caller captures the branch
# before cleanup and hands it in; the tally cannot run before cleanup instead,
# because the Claude Code runtime refuses this call from inside a worktree
# session.
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
# shellcheck source=.gaia/scripts/main-root-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/main-root-lib.sh" 2>/dev/null || true

log() {
  printf '%s\n' "$*" >&2
}

is_unsigned_integer() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Reads stdin, echoes the first 16 hex of its sha256. `shasum -a 256` is present
# on macOS and most Linux; `sha256sum` is the coreutils fallback. Returns 1 when
# neither tool is available, so the caller degrades to null (never fabricates).
hash16() {
  local checksum_output
  if checksum_output="$(shasum -a 256 2>/dev/null)"; then :;
  elif checksum_output="$(sha256sum 2>/dev/null)"; then :;
  else return 1; fi
  checksum_output="${checksum_output%% *}"
  [[ -z "$checksum_output" ]] && return 1
  printf '%s' "${checksum_output:0:16}"
}

# Echoes `sha256:<first-16-hex>` for a readable file, else returns 1. Delegates
# to token-pricing-lib.sh so every writer computes the identity the same way.
# The lib is a hard dependency of the priced path anyway (GAIA_PRICING_JQ_DEFS
# and gaia_load_rate_table both come from it), so there is no state where this
# resolves and the pricing around it does not.
rate_table_id() {
  gaia_rate_table_id "$@"
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
  local url normalized_url url_hash main_root
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    normalized_url="$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')"
    normalized_url="${normalized_url#*://}"          # strip a leading scheme://
    normalized_url="${normalized_url#*@}"            # strip a leading user@
    normalized_url="${normalized_url//:/\/}"         # ":" -> "/"
    normalized_url="${normalized_url%.git}"          # drop a trailing .git
    normalized_url="${normalized_url%/}"             # drop a trailing slash
    url_hash="$(printf '%s' "$normalized_url" | hash16)" || return 0
    [[ -n "$url_hash" ]] && printf 'sha256:%s' "$url_hash"
    return 0
  fi
  # Path fallback: hash the main-checkout absolute path, resolved through the
  # shared main-root resolver -- the same one ledger-path-lib.sh uses for the
  # ledger, here for the directory rather than the file, so the two stay tied.
  main_root="$TALLY_MAIN_ROOT"
  if [[ -z "$main_root" ]]; then
    main_root="$(gaia_resolve_main_root)" || return 0
  fi
  url_hash="$(printf '%s' "$main_root" | hash16)" || return 0
  [[ -n "$url_hash" ]] && printf 'path:%s' "$url_hash"
}

# Pinned human duration format: <N>h<M>m<S>s, dropping any LEADING zero-valued
# unit (45s, 6m39s, 2h4m10s), second granularity, lossless vs duration_seconds.
human_duration() {
  local total="$1" hours minutes seconds
  hours=$(( total / 3600 ))
  minutes=$(( (total % 3600) / 60 ))
  seconds=$(( total % 60 ))
  if (( hours > 0 )); then
    printf '%dh%dm%ds' "$hours" "$minutes" "$seconds"
  elif (( minutes > 0 )); then
    printf '%dm%ds' "$minutes" "$seconds"
  else
    printf '%ds' "$seconds"
  fi
}

# Render a raw UTC transcript timestamp (…Z) in the machine's LOCAL zone, for the
# human surfaces only. jq renders the local clock (DST-correct for H:M:S); the
# zone LABEL is $ZONE_LABEL (resolved once via `date +%Z`). Falls back to the raw
# input if jq cannot parse it (never fabricates, never blocks).
ZONE_LABEL=""
to_local() {
  local iso_timestamp="$1" clock
  clock="$(jq -rn --arg iso_timestamp "$iso_timestamp" '
    $iso_timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strflocaltime("%Y-%m-%d %H:%M:%S")
  ' 2>/dev/null || true)"
  if [[ -n "$clock" ]]; then
    printf '%s%s' "$clock" "${ZONE_LABEL:+ $ZONE_LABEL}"
  else
    printf '%s' "$iso_timestamp"
  fi
}

# ---------- argument parsing (never crash on a bad/missing flag) ----------
ACTION=""
SPEC_ID=""
PLAN_ID=""
PLAN_SLUG=""
OUTPUT_DIRECTORY=""
SESSION_ID_ARGUMENT=""
PROJECTS_ROOT_ARGUMENT=""
LEDGER_OVERRIDE=""
RATE_TABLE_OVERRIDE=""
CACHE_DIRECTORY_ARGUMENT=""
COMMAND_ARGUMENT=""
RUN_ID_ARGUMENT=""
GITHUB_TYPE_ARGUMENT=""
GITHUB_NUMBER_ARGUMENT=""
GITHUB_REPO_ARGUMENT=""
BRANCH_NAME_ARGUMENT=""

while [[ $# -gt 0 ]]; do
  key="$1"
  case "$key" in
    --action|--spec-id|--plan-id|--plan-slug|--out-dir|--session-id|--projects-root|--ledger|--rate-table|--cache-dir|--command|--run-id|--github-type|--github-number|--github-repo|--branch-name)
      flag_value="${2:-}"
      case "$key" in
        --action)        ACTION="$flag_value" ;;
        --spec-id)       SPEC_ID="$flag_value" ;;
        --plan-id)       PLAN_ID="$flag_value" ;;
        --plan-slug)     PLAN_SLUG="$flag_value" ;;
        --out-dir)       OUTPUT_DIRECTORY="$flag_value" ;;
        --session-id)    SESSION_ID_ARGUMENT="$flag_value" ;;
        --projects-root) PROJECTS_ROOT_ARGUMENT="$flag_value" ;;
        --ledger)        LEDGER_OVERRIDE="$flag_value" ;;
        --rate-table)    RATE_TABLE_OVERRIDE="$flag_value" ;;
        --cache-dir)     CACHE_DIRECTORY_ARGUMENT="$flag_value" ;;
        --command)       COMMAND_ARGUMENT="$flag_value" ;;
        --run-id)        RUN_ID_ARGUMENT="$flag_value" ;;
        --github-type)   GITHUB_TYPE_ARGUMENT="$flag_value" ;;
        --github-number) GITHUB_NUMBER_ARGUMENT="$flag_value" ;;
        --github-repo)   GITHUB_REPO_ARGUMENT="$flag_value" ;;
        --branch-name)   BRANCH_NAME_ARGUMENT="$flag_value" ;;
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

# The main root is resolved once per process and handed to the ledger path, the
# rate table, the cache dir, and the project id, so a hook run pays one git
# call for it, not one per consumer. Empty means every consumer keeps its own
# no-main-root behavior.
TALLY_MAIN_ROOT=""
if declare -F gaia_resolve_main_root >/dev/null 2>&1; then
  TALLY_MAIN_ROOT="$(gaia_resolve_main_root 2>/dev/null)" || TALLY_MAIN_ROOT=""
fi

resolve_branch() {
  if [[ -n "$BRANCH_NAME_ARGUMENT" ]]; then
    printf '%s' "$BRANCH_NAME_ARGUMENT"
  else
    git branch --show-current 2>/dev/null || true
  fi
}

SESSION_ID="${SESSION_ID_ARGUMENT:-${CLAUDE_CODE_SESSION_ID:-}}"
PROJECTS_ROOT="${PROJECTS_ROOT_ARGUMENT:-$HOME/.claude/projects}"
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
SPEC_ID_VALIDATED=""
PLAN_ID_VALIDATED=""
case "$SPEC_ID" in SPEC-*) SPEC_ID_VALIDATED="$SPEC_ID" ;; esac
case "$PLAN_ID" in PLAN-*) PLAN_ID_VALIDATED="$PLAN_ID" ;; esac
if [[ -n "$SPEC_ID_VALIDATED" ]]; then
  PLAN_ID_VALIDATED=""   # spec identity wins; the record never carries both
fi
# The single feature key used for the stdout title and the seq/final match.
FEATURE="${SPEC_ID_VALIDATED:-$PLAN_ID_VALIDATED}"

# Missing required flags are belt-and-suspenders (callers pass well-formed args);
# degrade to partial rather than crash. --action review/command are exempt from
# the feature-identity and --out-dir checks (COV-001): both kinds are
# legitimately unattributed (both ids null is valid, not a defect) and write no
# cost.json sidecar, so neither absence may mark them partial (the
# never-mark-partial clause).
if [[ "$ACTION" != "review" && "$ACTION" != "command" ]]; then
  [[ -z "$FEATURE" ]] && { log "token-tally: no feature identity (--spec-id SPEC-* or --plan-id PLAN-*)"; partial=1; }
  [[ -z "$OUTPUT_DIRECTORY" ]] && { log "token-tally: missing --out-dir"; partial=1; }
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
COMMAND_VALIDATED=""
RUN_ID_RESOLVED=""
if [[ "$ACTION" == "command" ]]; then
  case "$COMMAND_ARGUMENT" in
    gaia-audit|gaia-debt|gaia-fitness|gaia-forensics|gaia-harden|gaia-residue|gaia-wiki)
      COMMAND_VALIDATED="$COMMAND_ARGUMENT"
      ;;
    "")
      log "token-tally: missing --command for action=command"
      partial=1
      ;;
    *)
      log "token-tally: unrecognized --command value: $COMMAND_ARGUMENT"
      COMMAND_VALIDATED="$COMMAND_ARGUMENT"
      partial=1
      ;;
  esac

  # run_id: <slug>-<YYYYMMDDTHHMMSSZ>-<4 lowercase hex>. --run-id overrides
  # verbatim (a test seam; production callers omit it). The hex suffix is not
  # a uniqueness guarantee, only what keeps two same-second runs distinct.
  if [[ -n "$RUN_ID_ARGUMENT" ]]; then
    RUN_ID_RESOLVED="$RUN_ID_ARGUMENT"
  else
    run_slug="$(printf '%s' "$COMMAND_ARGUMENT" | tr -dc 'A-Za-z0-9._-')"
    [[ -z "$run_slug" ]] && run_slug="unknown"
    run_hex="$(printf '%04x' "$((RANDOM % 65536))")"
    RUN_ID_RESOLVED="${run_slug}-$(date -u +%Y%m%dT%H%M%SZ)-${run_hex}"
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
  if [[ "$GITHUB_TYPE_ARGUMENT" == "pr" || "$GITHUB_TYPE_ARGUMENT" == "issue" ]] \
     && [[ "$GITHUB_NUMBER_ARGUMENT" =~ ^[1-9][0-9]*$ ]] \
     && [[ "$GITHUB_REPO_ARGUMENT" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    GITHUB_JSON="$(jq -nc --arg type "$GITHUB_TYPE_ARGUMENT" --argjson number "$GITHUB_NUMBER_ARGUMENT" --arg repo "$GITHUB_REPO_ARGUMENT" \
      '{type: $type, number: $number, repo: $repo}' 2>/dev/null || true)"
    jq -e 'type == "object"' >/dev/null 2>&1 <<<"$GITHUB_JSON" || GITHUB_JSON=""
  elif [[ -n "$GITHUB_TYPE_ARGUMENT$GITHUB_NUMBER_ARGUMENT$GITHUB_REPO_ARGUMENT" ]]; then
    log "token-tally: incomplete/invalid --github-* flags for action=command; omitting github"
  fi
fi

# ---------- single-pass tally over main transcript + sidecars ----------
# Per file, ONE streaming read emits {usage:[{id,u,m}], tmin, tmax} where usage is
# deduped within the file (last-wins) and tmin/tmax range over EVERY usage line
# (not the deduped survivors). `m` carries `.message.model` (null when absent),
# threaded through alongside the usage object so the aggregate step can attribute
# buckets per model AFTER the same dedup. A file
# that fails to parse flips `partial` and contributes nothing, but never aborts
# the run or the other files.
temporary_file="$(mktemp 2>/dev/null)" || temporary_file=""
[[ -z "$temporary_file" ]] && { log "token-tally: mktemp failed; degrading to partial"; partial=1; }

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
# emit_file <path> <agent_bucket> <file_id>: <file_id> stamps the FILE's own identity
# ("" for the main transcript, the sidecar basename sans .jsonl for a sidecar)
# alongside <agent_bucket> (the FILE's agent type: "main" or the sidecar's agentType),
# so the audit-window-lib can select records by sidecar
# identity/window. The per-usage-entry `b` tag (compaction override included)
# is untouched -- only two new FILE-level keys are added to the emitted line.
emit_file() {
  jq -cn --arg agent_bucket "$2" --arg file_id "$3" '
    reduce inputs as $transcript_entry (
      {usage:{}, tmin:null, tmax:null};
      if $transcript_entry.message.usage != null
      then .usage[($transcript_entry.message.id // $transcript_entry.uuid)] = {
             u: $transcript_entry.message.usage,
             m: ($transcript_entry.message.model // null),
             b: (if ($transcript_entry.isCompactSummary == true) or ($transcript_entry.message.isCompactSummary == true)
                 then "auto-compaction" else $agent_bucket end)
           }
         | (if ($transcript_entry.timestamp | type) == "string"
            then .tmin = (if .tmin == null or $transcript_entry.timestamp < .tmin then $transcript_entry.timestamp else .tmin end)
               | .tmax = (if .tmax == null or $transcript_entry.timestamp > .tmax then $transcript_entry.timestamp else .tmax end)
            else . end)
      else . end)
    | {usage: (.usage | to_entries | map({id: .key, u: .value.u, m: .value.m, b: .value.b})),
       tmin, tmax, file_agent: $agent_bucket, file_id: $file_id}
  ' "$1" >>"$temporary_file" 2>/dev/null || partial=1
}

# The agent-type bucket for a sidecar is its own sidecar attribution: read the
# sibling agent-<hash>.meta.json and take `.agentType` (shape:
# {"agentType":"general-purpose","description":"…","toolUseId":"…"}). A missing/
# unreadable meta or absent agentType degrades to `unknown`, so every sidecar
# line still lands in exactly one bucket (reconcile-by-equality holds).
sidecar_agent_type() {
  local meta agent_type
  meta="${1%.jsonl}.meta.json"
  agent_type="$(jq -r '.agentType // empty' "$meta" 2>/dev/null || true)"
  [[ -n "$agent_type" ]] && printf '%s' "$agent_type" || printf 'unknown'
}

if [[ -n "$SESSION_ID" && -n "$temporary_file" ]]; then
  # Main transcript: first match of <projects-root>/*/<session-id>.jsonl.
  main_found=0
  for transcript_file in "$PROJECTS_ROOT"/*/"$SESSION_ID".jsonl; do
    if [[ -f "$transcript_file" ]]; then
      emit_file "$transcript_file" "main" ""
      main_found=1
      break
    fi
  done
  [[ "$main_found" -eq 0 ]] && { log "token-tally: no main transcript for session $SESSION_ID"; partial=1; }

  # Sidecars: zero matches is fine (a session may fan out no sub-agents), NOT
  # partial. The agent-*.jsonl glob excludes the sibling agent-*.meta.json files.
  for transcript_file in "$PROJECTS_ROOT"/*/"$SESSION_ID"/subagents/agent-*.jsonl; do
    if [[ -f "$transcript_file" ]]; then
      sidecar_file_id="$(basename "$transcript_file")"
      sidecar_file_id="${sidecar_file_id%.jsonl}"
      emit_file "$transcript_file" "$(sidecar_agent_type "$transcript_file")" "$sidecar_file_id"
    fi
  done

  # Workflow sidecars sit one level deeper, under workflows/wf_<id>/. The file
  # id keeps the wf_<id> segment so it stays unique across workflow runs; the
  # agent-*.jsonl glob excludes the run's journal.jsonl as well as meta.json.
  for transcript_file in "$PROJECTS_ROOT"/*/"$SESSION_ID"/subagents/workflows/wf_*/agent-*.jsonl; do
    if [[ -f "$transcript_file" ]]; then
      sidecar_file_id="$(basename "$(dirname "$transcript_file")")/$(basename "$transcript_file")"
      sidecar_file_id="${sidecar_file_id%.jsonl}"
      emit_file "$transcript_file" "$(sidecar_agent_type "$transcript_file")" "$sidecar_file_id"
    fi
  done
fi

# ---------- --action review: standalone FC-3 records, no phase record ----------
# A distinct path, branched early (before the phase aggregate/pricing/record
# machinery below): scans this session's sidecars for code-review-audit runs
# and appends one standalone kind:"review" ledger row per run not already
# recorded, then exits. It never builds a phase aggregate, never nests an
# audit annotation, and never writes a cost.json sidecar (a review is not
# phase-keyed). --spec-id/--plan-id/--out-dir are all optional here; the
# feature-identity and --out-dir partial checks above are already skipped for
# this action (COV-001).
if [[ "$ACTION" == "review" ]]; then
  windows="$(gaia_review_windows "$temporary_file")"
  window_count="$(jq -r 'length' <<<"$windows" 2>/dev/null)"
  is_unsigned_integer "$window_count" || window_count=0

  if [[ "$window_count" -eq 0 ]]; then
    log "token-tally: no code-review-audit run in session"
    [[ -n "$temporary_file" ]] && rm -f "$temporary_file" 2>/dev/null
    exit 0
  fi

  ledger=""
  if resolved_ledger_path="$(gaia_resolve_ledger_path "$LEDGER_OVERRIDE" "$TALLY_MAIN_ROOT")" && [[ -n "$resolved_ledger_path" ]]; then
    ledger="$resolved_ledger_path"
  else
    log "token-tally: could not resolve ledger path; skipping review append"
    [[ -n "$temporary_file" ]] && rm -f "$temporary_file" 2>/dev/null
    exit 0
  fi

  # Cutover (mirrors the phase path below): the first cost.jsonl append moves a
  # legacy tokens.jsonl sibling aside, exactly once, idempotent thereafter.
  if [[ "$(basename "$ledger")" == "cost.jsonl" ]]; then
    ledger_directory="$(dirname "$ledger")"
    if [[ -f "$ledger_directory/tokens.jsonl" && ! -f "$ledger" ]]; then
      mv "$ledger_directory/tokens.jsonl" "$ledger_directory/tokens.jsonl.bak" 2>/dev/null \
        || log "token-tally: cutover move-aside failed: $ledger_directory/tokens.jsonl"
    fi
  fi

  GIT_BRANCH="$(resolve_branch)"
  PROJECT_ID="$(compute_project_id 2>/dev/null || true)"
  TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  partial_bool=false
  [[ "$partial" -ne 0 ]] && partial_bool=true

  # The rate table is prepared lazily, on the first window that survives the
  # dedup skip below, so a run that only re-sees recorded reviews never seeds,
  # syncs, or heals anything. Prepared once for every record this run produces.
  review_cost_ok=false
  review_prepared=false
  review_rate_table=""
  review_rates="null"

  telemetry_directory="$(dirname "$ledger")"
  mkdir -p "$telemetry_directory" 2>/dev/null   # the lock dir must exist before acquisition

  _review_ledger_write() {
    printf '%s\n' "$review_record" >>"$ledger" 2>/dev/null || log "token-tally: ledger write failed: $ledger"
    return 0
  }

  while IFS= read -r window; do
    [[ -z "$window" ]] && continue
    review_id="$(jq -r '.review_id // empty' <<<"$window")"
    window_started="$(jq -r '.started_at // empty' <<<"$window")"
    window_ended="$(jq -r '.ended_at // empty' <<<"$window")"
    [[ -z "$review_id" ]] && continue

    # Dedup: skip a review_id already on the ledger (idempotent across both the
    # Stop-hook and the gh-pr-merge triggers, and across repeat runs).
    duplicate_count="$(jq -R -n --arg review_id "$review_id" '
      [ inputs
        | (try fromjson catch empty)
        | select(type == "object")
        | select(.kind == "review" and .review_id == $review_id)
      ] | length
    ' "$ledger" 2>/dev/null || printf '0')"
    is_unsigned_integer "$duplicate_count" || duplicate_count=0
    if [[ "$duplicate_count" -gt 0 ]]; then
      log "token-tally: review $review_id already recorded; skipping"
      continue
    fi

    # Unfiltered $temporary_file: this IS the review's own window (never temporary_phase_file, which
    # excludes code-review-audit windows for the PHASE path only), narrowed to
    # the sidecars gaia_review_windows assigned it, so parallel members whose
    # windows nest never count the same spend in two review rows.
    window_file_ids="$(jq -c '.file_ids // null' <<<"$window" 2>/dev/null)"
    subset="$(gaia_window_subset "$temporary_file" "$window_started" "$window_ended" "$window_file_ids")"

    review_fresh_input="$(jq -r '.buckets.fresh_input' <<<"$subset" 2>/dev/null)"
    review_cache_write="$(jq -r '.buckets.cache_write' <<<"$subset" 2>/dev/null)"
    review_cache_read="$(jq -r '.buckets.cache_read' <<<"$subset" 2>/dev/null)"
    review_output="$(jq -r '.buckets.output' <<<"$subset" 2>/dev/null)"
    is_unsigned_integer "$review_fresh_input"  || review_fresh_input=0
    is_unsigned_integer "$review_cache_write" || review_cache_write=0
    is_unsigned_integer "$review_cache_read"  || review_cache_read=0
    is_unsigned_integer "$review_output" || review_output=0
    review_total=$(( review_fresh_input + review_cache_write + review_cache_read + review_output ))

    review_usage_count="$(jq -r '.count' <<<"$subset" 2>/dev/null)"
    is_unsigned_integer "$review_usage_count" || review_usage_count=0
    review_duration_seconds="$(jq -r '.elapsed_seconds' <<<"$subset" 2>/dev/null)"
    review_duration_available=false
    if [[ "$review_usage_count" -gt 0 ]] && is_unsigned_integer "$review_duration_seconds"; then
      review_duration_available=true
    else
      review_duration_seconds=""
    fi

    review_by_model="$(jq -c '.by_model' <<<"$subset" 2>/dev/null)"
    jq -e 'type=="object"' >/dev/null 2>&1 <<<"$review_by_model" || review_by_model='{}'
    review_dollars="null"
    review_rate_table_id=""
    review_unpriced="[]"
    if [[ "$review_prepared" != "true" ]] && jq -e 'length > 0' >/dev/null 2>&1 <<<"$review_by_model"; then
      review_prepared=true
      review_rate_table=""
      if declare -F gaia_rates_prepare >/dev/null 2>&1; then
        # Called in this shell, not in $(...): it sets GAIA_RATES_TABLE and keeps
        # per-process state a subshell would discard.
        if gaia_rates_prepare "$RATE_TABLE_OVERRIDE" "$TALLY_MAIN_ROOT"; then
          review_rate_table="$GAIA_RATES_TABLE"
        fi
      else
        # A partial update can leave the local-table lib absent.
        review_rate_table="$(gaia_resolve_rate_table "$RATE_TABLE_OVERRIDE")" || review_rate_table=""
      fi
      if [[ -n "$review_rate_table" ]]; then
        if review_rates="$(gaia_load_rate_table "$review_rate_table")"; then
          review_cost_ok=true
        else
          log "token-tally: rate table unreadable: $review_rate_table"
        fi
      else
        log "token-tally: could not resolve rate table path"
      fi
    fi
    if [[ "$review_cost_ok" == "true" ]] && jq -e 'length > 0' >/dev/null 2>&1 <<<"$review_by_model"; then
      # The feed lib makes at most one request per process, so calling this per
      # window costs nothing after the first attempt.
      if declare -F gaia_rates_heal >/dev/null 2>&1 \
        && gaia_rates_heal "$(jq -c 'keys' <<<"$review_by_model")"; then
        review_rate_table="$GAIA_RATES_TABLE"
        if healed_rates="$(gaia_load_rate_table "$review_rate_table")"; then
          review_rates="$healed_rates"
        fi
      fi
      review_priced="$(jq -cn --argjson rates "$review_rates" --arg timestamp "$TIMESTAMP" --argjson by_model "$review_by_model" \
        "$GAIA_PRICING_JQ_DEFS"'
          priced_row({ts: $timestamp, by_model: $by_model})
        ' 2>/dev/null || true)"
      if [[ -n "$review_priced" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$review_priced"; then
        review_priced_dollars="$(jq -r '.dollars' <<<"$review_priced" 2>/dev/null)"
        if printf '%s' "$review_priced_dollars" | jq -e 'type=="number"' >/dev/null 2>&1; then
          review_dollars="$review_priced_dollars"
        fi
        review_rate_table_id="$(rate_table_id "$review_rate_table" 2>/dev/null || true)"
        # Same rule as the phase record: keep the names only as a real array.
        review_unpriced_raw="$(jq -c '.unpriced' <<<"$review_priced" 2>/dev/null)"
        if printf '%s' "$review_unpriced_raw" | jq -e 'type=="array"' >/dev/null 2>&1; then
          review_unpriced="$review_unpriced_raw"
        fi
      fi
    fi

    review_record="$(jq -nc \
      --arg session_id "$SESSION_ID" \
      --argjson fresh_input "$review_fresh_input" \
      --argjson cache_write "$review_cache_write" \
      --argjson cache_read "$review_cache_read" \
      --argjson output "$review_output" \
      --argjson total "$review_total" \
      --argjson by_model "$review_by_model" \
      --argjson dollars "$review_dollars" \
      --argjson unpriced "$review_unpriced" \
      --arg rate_table_id "$review_rate_table_id" \
      --argjson partial "$partial_bool" \
      --arg started "$window_started" \
      --arg ended "$window_ended" \
      --argjson duration_seconds "${review_duration_seconds:-null}" \
      --argjson duration_available "$review_duration_available" \
      --arg git_branch "$GIT_BRANCH" \
      --arg project "$PROJECT_ID" \
      --arg timestamp "$TIMESTAMP" \
      --arg session_cwd "$SESSION_CWD" \
      --arg spec_id "$SPEC_ID_VALIDATED" \
      --arg plan_id "$PLAN_ID_VALIDATED" \
      --arg review_id "$review_id" \
      '
        {
          schema_version: 1,
          kind: "review",
          spec_id: (if $spec_id == "" then null else $spec_id end),
          plan_id: (if $plan_id == "" then null else $plan_id end),
          plan_slug: null,
          session_id: $session_id,
          buckets: {fresh_input: $fresh_input, cache_write: $cache_write, cache_read: $cache_read, output: $output},
          total: $total
        }
        + (if ($by_model | type) == "object" and ($by_model | length) > 0 then {by_model: $by_model} else {} end)
        + (if ($unpriced | type) == "array" and ($unpriced | length) > 0 then {unpriced: $unpriced} else {} end)
        + {
            dollars: $dollars,
            rate_table_id: (if $rate_table_id == "" then null else $rate_table_id end),
            partial: $partial,
            started_at: (if $duration_available then $started else null end),
            ended_at: (if $duration_available then $ended else null end),
            duration_seconds: (if $duration_available then $duration_seconds else null end),
            duration_available: $duration_available,
            git_branch: (if $git_branch == "" then null else $git_branch end),
            project: (if $project == "" then null else $project end),
            seq: 0,
            final: true,
            ts: $timestamp,
            session_cwd: (if $session_cwd == "" then null else $session_cwd end),
            source: "code-review-audit",
            review_id: $review_id
          }
      ' 2>/dev/null || true)"

    if [[ -n "$review_record" ]]; then
      if declare -f with_ledger_lock >/dev/null 2>&1; then
        lock_exit_status=0
        with_ledger_lock "$telemetry_directory" _review_ledger_write || lock_exit_status=$?
        if [[ "$lock_exit_status" -eq 75 ]]; then
          log "token-tally: review lock timed out; appending without lock"
          printf '%s\n' "$review_record" >>"$ledger" 2>/dev/null || log "token-tally: degraded review append failed: $ledger"
        fi
      else
        _review_ledger_write
      fi
      log "token-tally: recorded review $review_id"
    else
      log "token-tally: failed to build review record for $review_id"
    fi
  done < <(jq -c '.[]' <<<"$windows" 2>/dev/null)

  [[ -n "$temporary_file" ]] && rm -f "$temporary_file" 2>/dev/null
  exit 0
fi

# ---------- exclude any code-review-audit window from a phase tally ----------
# Double-count guard (AUDIT directive #3): a review run's spend must land ONLY
# in its own standalone kind:"review" row, never also folded into a phase
# total. $temporary_file stays intact (unused by phase actions past this point); the
# aggregate + BY_MODEL + BY_AGENT_TYPE + duration below all read $temporary_phase_file.
# In an authoring session with no code-review-audit sidecars this is a byte
# no-op (temporary_phase_file == temporary_file; the lib's own degrade guarantees this).
temporary_phase_file="$temporary_file"
# Guard on function existence only: a missing/unsourced audit-window-lib.sh
# (e.g. a partial /update-gaia mid-upgrade) must degrade to NO exclusion, not
# an empty stream that would zero out $temporary_phase_file and fabricate a 0 total.
if [[ -n "$temporary_file" && -s "$temporary_file" ]] && declare -F gaia_exclude_review_windows >/dev/null 2>&1; then
  temporary_phase_candidate_file="$(mktemp 2>/dev/null)" || temporary_phase_candidate_file=""
  if [[ -n "$temporary_phase_candidate_file" ]]; then
    gaia_exclude_review_windows "$temporary_file" >"$temporary_phase_candidate_file" 2>/dev/null
    temporary_phase_file="$temporary_phase_candidate_file"
  fi
fi

# ---------- aggregate: global dedup + bucket sums + global min/max ----------
FRESH_INPUT=0
CACHE_WRITE=0
CACHE_READ=0
OUTPUT=0
EARLIEST_TIMESTAMP=""
LATEST_TIMESTAMP=""
BY_MODEL='{}'
BY_AGENT_TYPE='{}'
if [[ -n "$temporary_phase_file" && -s "$temporary_phase_file" ]]; then
  IFS=$'\t' read -r FRESH_INPUT CACHE_WRITE CACHE_READ OUTPUT EARLIEST_TIMESTAMP LATEST_TIMESTAMP < <(
    jq -rs '
      ((map(.usage) | add // []) | reduce .[] as $usage_row ({}; .[$usage_row.id] = {u: $usage_row.u, m: $usage_row.m}) | [.[]]) as $deduplicated_usage
      | [ ($deduplicated_usage | map(.u.input_tokens // 0)                | add // 0),
          ($deduplicated_usage | map(.u.cache_creation_input_tokens // 0) | add // 0),
          ($deduplicated_usage | map(.u.cache_read_input_tokens // 0)     | add // 0),
          ($deduplicated_usage | map(.u.output_tokens // 0)               | add // 0),
          (map(.tmin) | map(select(. != null)) | min // ""),
          (map(.tmax) | map(select(. != null)) | max // "") ]
      | @tsv
    ' "$temporary_phase_file" 2>/dev/null || printf '0\t0\t0\t0\t\t\n'
  )

  # ---------- per-model attribution (FC-1): same dedup-by-id, grouped by model ----------
  # Reuses the identical global dedup so per-model sums reconcile exactly to the
  # aggregate above (AUDIT directive 3: dedup THEN group). A model key is dropped
  # when `.m` is null/empty (line not attributable) or its five-bucket sum is
  # zero (drops `<synthetic>` and other zero-usage sentinels). Never blocks: any
  # failure here degrades BY_MODEL to `{}`, so `by_model` is simply omitted below.
  BY_MODEL="$(jq -cs '
    ((map(.usage) | add // []) | reduce .[] as $usage_row ({}; .[$usage_row.id] = {u: $usage_row.u, m: $usage_row.m}) | [.[]]) as $deduplicated_usage
    | ($deduplicated_usage | map(select(.m != null and .m != "")))
    | group_by(.m)
    | map({
        key: .[0].m,
        value: (reduce .[] as $group_row (
          {fresh_input: 0, cache_write_5m: 0, cache_write_1h: 0, cache_read: 0, output: 0};
          .fresh_input      += ($group_row.u.input_tokens // 0)
          | .cache_write_5m += ($group_row.u.cache_creation.ephemeral_5m_input_tokens // 0)
          | .cache_write_1h += ($group_row.u.cache_creation.ephemeral_1h_input_tokens // ($group_row.u.cache_creation_input_tokens // 0))
          | .cache_read     += ($group_row.u.cache_read_input_tokens // 0)
          | .output         += ($group_row.u.output_tokens // 0)
        ))
      })
    | map(select(([.value[]] | add) > 0))
    | from_entries
  ' "$temporary_phase_file" 2>/dev/null)"
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
    ((map(.usage) | add // []) | reduce .[] as $usage_row ({}; .[$usage_row.id] = {u: $usage_row.u, b: $usage_row.b}) | [.[]]) as $deduplicated_usage
    | ($deduplicated_usage | map(select(.b != null and .b != "")))
    | group_by(.b)
    | map({
        key: .[0].b,
        value: (reduce .[] as $group_row (
          {fresh_input: 0, cache_write_5m: 0, cache_write_1h: 0, cache_read: 0, output: 0};
          .fresh_input      += ($group_row.u.input_tokens // 0)
          | .cache_write_5m += ($group_row.u.cache_creation.ephemeral_5m_input_tokens // 0)
          | .cache_write_1h += ($group_row.u.cache_creation.ephemeral_1h_input_tokens // ($group_row.u.cache_creation_input_tokens // 0))
          | .cache_read     += ($group_row.u.cache_read_input_tokens // 0)
          | .output         += ($group_row.u.output_tokens // 0)
        ))
      })
    | map(select(([.value[]] | add) > 0))
    | from_entries
  ' "$temporary_phase_file" 2>/dev/null)"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$BY_AGENT_TYPE" || BY_AGENT_TYPE='{}'
fi
# $temporary_file itself is no longer needed for a phase action (the aggregate above, and
# the FC-2 audit-nesting block further down, both read $temporary_phase_file). $temporary_phase_file
# stays alive until after that block runs, so its cleanup is deferred to just
# before the ledger-record build.
[[ -n "$temporary_file" ]] && rm -f "$temporary_file" 2>/dev/null

is_unsigned_integer "$FRESH_INPUT"  || FRESH_INPUT=0
is_unsigned_integer "$CACHE_WRITE" || CACHE_WRITE=0
is_unsigned_integer "$CACHE_READ"  || CACHE_READ=0
is_unsigned_integer "$OUTPUT"    || OUTPUT=0
TOTAL=$(( FRESH_INPUT + CACHE_WRITE + CACHE_READ + OUTPUT ))

# ---------- duration: convert ONLY the two extremes in jq (never `date`) ----------
# A malformed extremal timestamp -> unavailable (own flag), never a fabricated 0,
# never an abort. The subtraction stays inside jq so empty vars can't leak a 0.
DURATION_SECONDS=""
DURATION_AVAILABLE=false
if [[ -n "$EARLIEST_TIMESTAMP" && -n "$LATEST_TIMESTAMP" ]]; then
  DURATION_SECONDS="$(jq -rn --arg earliest "$EARLIEST_TIMESTAMP" --arg latest "$LATEST_TIMESTAMP" '
    def to_epoch_seconds: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    (($latest | to_epoch_seconds) - ($earliest | to_epoch_seconds))
  ' 2>/dev/null || true)"
  if is_unsigned_integer "$DURATION_SECONDS"; then
    DURATION_AVAILABLE=true
  else
    DURATION_SECONDS=""
  fi
fi

# Human-facing duration + LOCAL-zone endpoint strings (the ledger keeps raw UTC).
# Resolve the zone label once; both endpoints share it.
HUMAN_ELAPSED=""
LOCAL_START=""
LOCAL_END=""
if [[ "$DURATION_AVAILABLE" == "true" ]]; then
  HUMAN_ELAPSED="$(human_duration "$DURATION_SECONDS")"
  ZONE_LABEL="$(date +%Z 2>/dev/null || true)"
  LOCAL_START="$(to_local "$EARLIEST_TIMESTAMP")"
  LOCAL_END="$(to_local "$LATEST_TIMESTAMP")"
fi

# ---------- shared generation stamp (date -u here is fine; the ban is only on
#            parsing transcript timestamps to epoch, which stays jq-only) ----------
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- dollar pricing of this section's own by_model ----------
# Each run's cost.json record prices its OWN in-process BY_MODEL at the rate
# whose effective window covers TIMESTAMP (this run's generation stamp) -- a frozen
# snapshot, deliberately distinct from token-rollup.sh's read-time reprice.
# Never guesses, never blocks: empty attribution or an unreadable rate table
# degrade to a marked "unavailable" line rather than a fabricated figure. The
# table is the machine-local one (seeded from the main checkout's distributed
# table), or the --rate-table override.
#
# The ledger persists the RAW numeric `dollars` (not a formatted string) so a
# downstream reader reproduces this exact historical figure, plus `rate_table_id`
# (the identity of the rate table that priced it) so it can re-price the raw
# by_model under a different card. Both are null off the priced path.
#
# `unpriced` names every claude-* model the table had no row for. priced_row
# maps a null rate window to 0 and still returns a well-formed row, so without
# this field a run priced at zero is indistinguishable from a run that cost
# nothing, and a mixed-model run reports a plausible figure silently missing one
# model's share. Persisting it makes an affected row findable by field instead of
# by re-deriving which keys the table was missing when it was written.
COST_DOLLARS_RAW="null"       # JSON number on the priced path, else null
RATE_TABLE_ID=""              # sha256:<16hex> on the priced path, else empty -> null
UNPRICED_JSON="[]"            # claude-* models with no rate-table row; [] when all priced

if jq -e 'length > 0' >/dev/null 2>&1 <<<"$BY_MODEL"; then
  cost_rates="null"
  cost_ok=false
  cost_rate_table=""
  if declare -F gaia_rates_prepare >/dev/null 2>&1; then
    # Called in this shell, not in $(...): it sets GAIA_RATES_TABLE and keeps
    # per-process state a subshell would discard.
    if gaia_rates_prepare "$RATE_TABLE_OVERRIDE" "$TALLY_MAIN_ROOT"; then
      cost_rate_table="$GAIA_RATES_TABLE"
    fi
  else
    # A partial update can leave the local-table lib absent.
    cost_rate_table="$(gaia_resolve_rate_table "$RATE_TABLE_OVERRIDE")" || cost_rate_table=""
  fi
  if [[ -n "$cost_rate_table" ]]; then
    if cost_rates="$(gaia_load_rate_table "$cost_rate_table")"; then
      cost_ok=true
      # A claude-* model the table lacks may be a release GAIA has since priced;
      # heal fetches it once, and only then is the figure final. Status 0 means
      # the local table was rewritten, so reload before pricing.
      if declare -F gaia_rates_heal >/dev/null 2>&1 \
        && gaia_rates_heal "$(jq -c 'keys' <<<"$BY_MODEL")"; then
        cost_rate_table="$GAIA_RATES_TABLE"
        if healed_rates="$(gaia_load_rate_table "$cost_rate_table")"; then
          cost_rates="$healed_rates"
        fi
      fi
    else
      log "token-tally: rate table unreadable: $cost_rate_table"
    fi
  else
    log "token-tally: could not resolve rate table path"
  fi

  if [[ "$cost_ok" == "true" ]]; then
    priced="$(jq -cn --argjson rates "$cost_rates" --arg timestamp "$TIMESTAMP" --argjson by_model "$BY_MODEL" \
      "$GAIA_PRICING_JQ_DEFS"'
        priced_row({ts: $timestamp, by_model: $by_model})
      ' 2>/dev/null || true)"
    if [[ -n "$priced" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$priced"; then
      dollars="$(jq -r '.dollars' <<<"$priced" 2>/dev/null)"
      # Persist the raw numeric dollars only when it is a valid JSON number.
      if printf '%s' "$dollars" | jq -e 'type=="number"' >/dev/null 2>&1; then
        COST_DOLLARS_RAW="$dollars"
      fi
      # rate_table_id identifies the exact table that priced this row.
      RATE_TABLE_ID="$(rate_table_id "$cost_rate_table" 2>/dev/null || true)"
      # Keep the unpriced names only when they arrive as a real array; anything
      # else degrades to [] rather than a fabricated or malformed field.
      unpriced_raw="$(jq -c '.unpriced' <<<"$priced" 2>/dev/null)"
      if printf '%s' "$unpriced_raw" | jq -e 'type=="array"' >/dev/null 2>&1; then
        UNPRICED_JSON="$unpriced_raw"
      fi
    fi
    # else: pricing failed unexpectedly -> leave dollars/rate_table_id null,
    # never fabricate.
  fi
  # else: rate table unresolvable/unreadable -> leave dollars/rate_table_id null.
fi

# ---------- CACHE_DIRECTORY resolution (hoisted): spec/plan's FC-2 audit-window
#            breadcrumb AND execute's FC-6 gh-artifact breadcrumb both resolve
#            through this one derivation. --cache-dir (test seam) defaults to
#            <main_root>/.gaia/local/cache, deriving main_root through the
#            shared main-root resolver (.gaia/scripts/main-root-lib.sh), the
#            same one ledger-path-lib.sh uses for the ledger main_root -- NOT
#            via compute_project_id, which returns a hash, not a path
#            (CG-002). A command or review run pays nothing for this (guarded
#            out below).
CACHE_DIRECTORY=""
if [[ "$ACTION" == "spec" || "$ACTION" == "plan" || "$ACTION" == "execute" ]]; then
  CACHE_DIRECTORY="$CACHE_DIRECTORY_ARGUMENT"
  if [[ -z "$CACHE_DIRECTORY" ]]; then
    if [[ -n "$TALLY_MAIN_ROOT" ]]; then
      CACHE_DIRECTORY="$TALLY_MAIN_ROOT/.gaia/local/cache"
    elif audit_main_root="$(gaia_resolve_main_root)"; then
      CACHE_DIRECTORY="$audit_main_root/.gaia/local/cache"
    fi
  fi
fi

# ---------- git_branch (moved up: FC-6's execute breadcrumb read below needs
#            it before the record build; project identity stays at its
#            original site further down) ----------
GIT_BRANCH="$(resolve_branch)"

# ---------- FC-2: nest the adversarial-audit annotation (spec/plan only) ----------
# A strict subset drill-down of the phase record just aggregated above: never
# summed into total/buckets/dollars, and omitted entirely (never fabricated)
# when the breadcrumb is absent/unparseable, its session_id does not match
# this tally's session, or its window catches zero sidecar activity.
AUDIT_JSON=""
if [[ "$ACTION" == "spec" || "$ACTION" == "plan" ]]; then
  # The breadcrumb key MUST match what task-breadcrumb-emit writes (FC-1,
  # DP-002 / CG-001): spec -> $SPEC_ID_VALIDATED; spec-derived plan -> "<spec_id>-plan"
  # (namespaced by the SPEC id, never $PLAN_SLUG, which is the literal
  # "plan"/"plan-2" identical across every SPEC); SPEC-less plan -> $PLAN_ID_VALIDATED.
  if [[ "$ACTION" == "spec" ]]; then
    audit_feature="$SPEC_ID_VALIDATED"
  elif [[ -n "$SPEC_ID_VALIDATED" ]]; then
    audit_feature="${SPEC_ID_VALIDATED}-plan"
  else
    audit_feature="$PLAN_ID_VALIDATED"
  fi

  if [[ -n "$CACHE_DIRECTORY" && -n "$audit_feature" ]]; then
    breadcrumb="$CACHE_DIRECTORY/audit-window-${audit_feature}.json"
    breadcrumb_content="$(gaia_audit_window_read "$breadcrumb")"

    if [[ -n "$breadcrumb_content" ]]; then
      breadcrumb_session="$(jq -r '.session_id // empty' <<<"$breadcrumb_content")"
      if [[ -n "$SESSION_ID" && "$breadcrumb_session" == "$SESSION_ID" ]]; then
        breadcrumb_started="$(jq -r '.started_at // empty' <<<"$breadcrumb_content")"
        breadcrumb_ended="$(jq -r '.ended_at // empty' <<<"$breadcrumb_content")"
        breadcrumb_lenses="$(jq -c '.lenses // []' <<<"$breadcrumb_content")"
        jq -e 'type=="array"' >/dev/null 2>&1 <<<"$breadcrumb_lenses" || breadcrumb_lenses='[]'
        breadcrumb_intensity="$(jq -r '.intensity // empty' <<<"$breadcrumb_content")"

        # Computed from $temporary_phase_file (the SAME deduped survivor stream the phase
        # total above aggregates), never a fresh re-read: because the subset is
        # a window-filtered subset of the same sidecar files, each audit bucket
        # is <= the phase bucket by construction.
        audit_subset="$(gaia_window_subset "$temporary_phase_file" "$breadcrumb_started" "$breadcrumb_ended")"
        audit_count="$(jq -r '.count' <<<"$audit_subset" 2>/dev/null)"
        is_unsigned_integer "$audit_count" || audit_count=0

        if [[ "$audit_count" -gt 0 ]]; then
          audit_by_model="$(jq -c '.by_model' <<<"$audit_subset" 2>/dev/null)"
          jq -e 'type=="object"' >/dev/null 2>&1 <<<"$audit_by_model" || audit_by_model='{}'
          audit_dollars="null"
          # Reuse the SAME cost_rate_table/cost_rates resolved for the phase dollars
          # above; never resolve the rate table a second time. cost_ok is
          # unset (falsy) when BY_MODEL was empty, which safely degrades this
          # to null (a subset of an empty-attribution phase is also empty).
          if [[ "$cost_ok" == "true" ]] && jq -e 'length > 0' >/dev/null 2>&1 <<<"$audit_by_model"; then
            audit_priced="$(jq -cn --argjson rates "$cost_rates" --arg timestamp "$TIMESTAMP" --argjson by_model "$audit_by_model" \
              "$GAIA_PRICING_JQ_DEFS"'
                priced_row({ts: $timestamp, by_model: $by_model})
              ' 2>/dev/null || true)"
            if [[ -n "$audit_priced" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$audit_priced"; then
              audit_priced_dollars="$(jq -r '.dollars' <<<"$audit_priced" 2>/dev/null)"
              if printf '%s' "$audit_priced_dollars" | jq -e 'type=="number"' >/dev/null 2>&1; then
                audit_dollars="$audit_priced_dollars"
              fi
            fi
          fi

          AUDIT_JSON="$(jq -nc \
            --argjson buckets "$(jq -c '.buckets' <<<"$audit_subset")" \
            --argjson dollars "$audit_dollars" \
            --argjson elapsed "$(jq -r '.elapsed_seconds' <<<"$audit_subset")" \
            --argjson lenses "$breadcrumb_lenses" \
            --arg intensity "$breadcrumb_intensity" \
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
      # degrade); never attribute another session's audit.

      # Consume the breadcrumb: the phase tally is its only reader, and it has
      # now made its decision either way (nested, or omitted because the
      # session no longer matches / the window caught nothing). A breadcrumb
      # that was absent/unparseable in the first place has nothing to remove.
      rm -f "$breadcrumb" 2>/dev/null || true
    fi
  fi
fi

# $temporary_phase_file's last reader was the FC-2 block just above; safe to remove now.
[[ -n "$temporary_phase_file" && "$temporary_phase_file" != "$temporary_file" ]] && rm -f "$temporary_phase_file" 2>/dev/null

# ---------- FC-6: github on --action execute (breadcrumb, read-only, never deletes) ----------
# --action execute only; spec/plan/review/command never read it. A match
# requires the breadcrumb's session_id AND branch to equal this run's, and its
# ts to be within the TTL (the lib enforces all three); the lib never deletes
# it, so every cumulative commit-triggered row re-reads the same breadcrumb.
# The lib being absent/unsourceable, or nothing matching, both just omit
# `github`, never fail.
if [[ "$ACTION" == "execute" ]] && declare -F gaia_gh_artifact_read >/dev/null 2>&1; then
  gh_breadcrumb_path="$(gaia_gh_artifact_path "$CACHE_DIRECTORY" "$GIT_BRANCH")"
  if [[ -n "$gh_breadcrumb_path" ]]; then
    gh_breadcrumb_content="$(gaia_gh_artifact_read "$gh_breadcrumb_path" "$SESSION_ID" "$GIT_BRANCH")"
    if [[ -n "$gh_breadcrumb_content" ]] && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$gh_breadcrumb_content"; then
      GITHUB_JSON="$gh_breadcrumb_content"
    fi
  fi
fi

# Display title: stdout uses `<feature>/<slug>`.
if [[ "$ACTION" == "spec" ]]; then
  output_title="$ACTION $FEATURE"
else
  output_title="$ACTION $FEATURE/$PLAN_SLUG"
fi

# ---------- ledger record (README C2), resolved to the main checkout ----------
# The main-checkout ledger path (…/cost.jsonl) comes from the shared lib, so the
# ledger filename lives in one place. A KICKOFF run inside a linked worktree
# records to the surviving main ledger. --ledger overrides (test seam).
resolve_ledger() {
  gaia_resolve_ledger_path "$LEDGER_OVERRIDE" "$TALLY_MAIN_ROOT"
}

# Best-effort: clear `final` on every PRIOR same-(feature,session) execute row so
# only the terminal (just-appended, seq==$5) row keeps final:true. Rewrites the
# whole ledger through a temp file, preserving non-matching rows AND unparseable
# lines verbatim; a corrupt line is never dropped. On any failure the ledger is
# left as-is (prior finals stay set) -- the reader's documented fallback is
# max-seq, so a failed rewrite never loses correctness. Never aborts the run.
clear_prior_finals() {
  local ledger="$1" session_id="$2" spec="$3" plan="$4" new_sequence_number="$5" temporary_ledger_file ledger_directory
  # mktemp into the ledger's own directory so the `mv` below is a same-filesystem
  # rename(2) (atomic), never a cross-fs copy+unlink that could expose a
  # partially written ledger. Fail-open is unchanged: an unwritable dir degrades
  # to leaving prior finals as-is (the reader's max-seq fallback stays correct).
  ledger_directory="$(dirname "$ledger")"
  temporary_ledger_file="$(mktemp "$ledger_directory/.cost.jsonl.XXXXXX" 2>/dev/null)" || { log "token-tally: mktemp failed; leaving prior finals as-is"; return 0; }
  if jq -R -r -n --arg session_id "$session_id" --arg spec "$spec" --arg plan "$plan" --argjson new_sequence_number "$new_sequence_number" '
        inputs as $line
        | ($line | try fromjson catch null) as $ledger_row
        | if ($ledger_row | type) == "object" then
            ( if ($ledger_row.kind == "execute") and ($ledger_row.session_id == $session_id)
                 and ( ($spec != "" and $ledger_row.spec_id == $spec) or ($plan != "" and $ledger_row.plan_id == $plan) )
                 and ($ledger_row.seq != $new_sequence_number)
              then $ledger_row + {final: false}
              else $ledger_row end
            ) | tojson
          else
            $line
          end
      ' "$ledger" >"$temporary_ledger_file" 2>/dev/null && [[ -s "$temporary_ledger_file" ]]; then
    mv "$temporary_ledger_file" "$ledger" 2>/dev/null || { log "token-tally: could not replace ledger; prior finals left as-is"; rm -f "$temporary_ledger_file" 2>/dev/null; }
  else
    log "token-tally: could not clear prior finals; reader falls back to max seq"
    rm -f "$temporary_ledger_file" 2>/dev/null
  fi
}

ledger=""
if resolved_ledger_path="$(resolve_ledger)" && [[ -n "$resolved_ledger_path" ]]; then
  ledger="$resolved_ledger_path"
else
  log "token-tally: could not resolve ledger path; skipping ledger append"
fi

# ---------- cutover: start a fresh cost.jsonl, move the old ledger aside
# Fires only when the resolved ledger basename is cost.jsonl, a sibling
# tokens.jsonl exists, and cost.jsonl does not yet exist -- so it is idempotent
# (never re-fires once cost.jsonl exists) and leaves non-cost.jsonl --ledger test
# runs untouched. The old ledger is moved to a .bak the contract never reads,
# never deleted, so the fresh cost.jsonl begins empty at schema_version 1 with no
# mixed-vintage rows.
if [[ -n "$ledger" && "$(basename "$ledger")" == "cost.jsonl" ]]; then
  ledger_directory="$(dirname "$ledger")"
  if [[ -f "$ledger_directory/tokens.jsonl" && ! -f "$ledger" ]]; then
    mv "$ledger_directory/tokens.jsonl" "$ledger_directory/tokens.jsonl.bak" 2>/dev/null \
      || log "token-tally: cutover move-aside failed: $ledger_directory/tokens.jsonl"
  fi
fi

# ---------- project identity (git_branch is computed earlier, before the
#            CACHE_DIRECTORY/FC-2/FC-6 breadcrumb block, which needs it) ----------
PROJECT_ID="$(compute_project_id 2>/dev/null || true)"

# ---------- seq ----------
# spec/plan: one row per session -> seq 0. execute: one cumulative row per commit
# -> seq = count of PRIOR same-(feature,session) execute rows already on the
# ledger; the new row is always final:true and clears prior finals after append.
SEQUENCE_NUMBER=0
if [[ "$ACTION" == "execute" && -n "$ledger" && -f "$ledger" ]]; then
  prior_count="$(jq -R -n --arg session_id "$SESSION_ID" --arg spec "$SPEC_ID_VALIDATED" --arg plan "$PLAN_ID_VALIDATED" '
    [ inputs
      | (try fromjson catch empty)
      | select(type == "object")
      | select(.kind == "execute" and .session_id == $session_id)
      | select( ($spec != "" and .spec_id == $spec) or ($plan != "" and .plan_id == $plan) )
    ] | length
  ' "$ledger" 2>/dev/null || printf '0')"
  is_unsigned_integer "$prior_count" && SEQUENCE_NUMBER="$prior_count"
fi

partial_bool=false
[[ "$partial" -ne 0 ]] && partial_bool=true

record="$(jq -nc \
  --arg kind "$ACTION" \
  --arg spec_id "$SPEC_ID_VALIDATED" \
  --arg plan_id "$PLAN_ID_VALIDATED" \
  --arg plan_slug "$PLAN_SLUG" \
  --arg session_id "$SESSION_ID" \
  --argjson fresh_input "$FRESH_INPUT" \
  --argjson cache_write "$CACHE_WRITE" \
  --argjson cache_read "$CACHE_READ" \
  --argjson output "$OUTPUT" \
  --argjson total "$TOTAL" \
  --argjson by_model "$BY_MODEL" \
  --argjson by_agent_type "$BY_AGENT_TYPE" \
  --argjson dollars "$COST_DOLLARS_RAW" \
  --arg rate_table_id "$RATE_TABLE_ID" \
  --argjson unpriced "$UNPRICED_JSON" \
  --argjson partial "$partial_bool" \
  --arg started "$EARLIEST_TIMESTAMP" \
  --arg ended "$LATEST_TIMESTAMP" \
  --argjson duration_seconds "${DURATION_SECONDS:-null}" \
  --argjson duration_available "$DURATION_AVAILABLE" \
  --arg git_branch "$GIT_BRANCH" \
  --arg project "$PROJECT_ID" \
  --argjson sequence_number "$SEQUENCE_NUMBER" \
  --arg timestamp "$TIMESTAMP" \
  --arg session_cwd "$SESSION_CWD" \
  --arg audit_json "$AUDIT_JSON" \
  --arg command_value "$COMMAND_VALIDATED" \
  --arg run_id_value "$RUN_ID_RESOLVED" \
  --arg github_json "$GITHUB_JSON" \
  '
    {
      schema_version: 1,
      kind: $kind,
      spec_id: (if $spec_id == "" then null else $spec_id end),
      plan_id: (if $plan_id == "" then null else $plan_id end),
      plan_slug: (if $plan_slug == "" then null else $plan_slug end),
      session_id: $session_id,
      buckets: {fresh_input: $fresh_input, cache_write: $cache_write, cache_read: $cache_read, output: $output},
      total: $total
    }
    + (if ($by_model | type) == "object" and ($by_model | length) > 0 then {by_model: $by_model} else {} end)
    + (if ($by_agent_type | type) == "object" and ($by_agent_type | length) > 0 then {by_agent_type: $by_agent_type} else {} end)
    + (if ($unpriced | type) == "array" and ($unpriced | length) > 0 then {unpriced: $unpriced} else {} end)
    + (if $audit_json != "" then {audit: ($audit_json | fromjson)} else {} end)
    + (if $kind == "command" then {command: (if $command_value == "" then null else $command_value end), run_id: $run_id_value} else {} end)
    + (if $github_json != "" then {github: ($github_json | fromjson)} else {} end)
    + {
        dollars: $dollars,
        rate_table_id: (if $rate_table_id == "" then null else $rate_table_id end),
        partial: $partial,
        started_at: (if $duration_available then $started else null end),
        ended_at: (if $duration_available then $ended else null end),
        duration_seconds: (if $duration_available then $duration_seconds else null end),
        duration_available: $duration_available,
        git_branch: (if $git_branch == "" then null else $git_branch end),
        project: (if $project == "" then null else $project end),
        seq: $sequence_number,
        final: true,
        ts: $timestamp,
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
  if printf '%s\n' "$record" >>"$ledger" 2>/dev/null; then
    # execute: only the terminal row stays final:true (best-effort, fail-open).
    [[ "$ACTION" == "execute" ]] && clear_prior_finals "$ledger" "$SESSION_ID" "$SPEC_ID_VALIDATED" "$PLAN_ID_VALIDATED" "$SEQUENCE_NUMBER"
  else
    log "token-tally: ledger write failed: $ledger"
  fi
  return 0
}

if [[ -n "$record" && -n "$ledger" ]]; then
  telemetry_directory="$(dirname "$ledger")"
  mkdir -p "$telemetry_directory" 2>/dev/null   # the lock dir must exist before acquisition
  if declare -f with_ledger_lock >/dev/null 2>&1; then
    lock_exit_status=0
    with_ledger_lock "$telemetry_directory" _cost_ledger_write || lock_exit_status=$?
    if [[ "$lock_exit_status" -eq 75 ]]; then
      # Lock-acquisition timeout: degrade to the append WITHOUT clear_prior_finals.
      # Never skip the append; never run the rewrite unlocked. The reader's max-seq
      # fallback copes with the un-cleared prior final.
      #
      # This append is UNLOCKED, so it is visible to a concurrent whole-ledger
      # rewrite: a rewriter re-reading the ledger's tail immediately before its
      # atomic replace carries anything that landed. That narrows the loss window
      # to the gap between that re-read and the rename rather than closing it: a
      # row is only safe from the rewrite once the rewrite has seen it. Never
      # block the hook is the invariant this branch keeps; never lose a row is
      # kept on the rewriting side, where the row can actually be observed.
      log "token-tally: cost lock timed out; appending without clear_prior_finals"
      printf '%s\n' "$record" >>"$ledger" 2>/dev/null || log "token-tally: degraded append failed: $ledger"
    fi
  else
    # Mutex helper unavailable (source failed): preserve the never-block contract
    # with a direct, unguarded append + clear_prior_finals.
    _cost_ledger_write
  fi
elif [[ -z "$record" ]]; then
  log "token-tally: failed to build ledger record; skipping ledger append"
fi

# ---------- cost.json sidecar (README C3; FC-1) ----------
# One object keyed by phase kind: {"spec":<record>} for a spec folder, and
# {"plan":<record>, "execute":<record>} for a plan folder. Each value is the same
# record shape appended to the central cost.jsonl. A plan/execute write replaces
# ONLY its own key and copies the sibling key through byte-unchanged, so the
# plan-authoring cost (written by /gaia-plan) and the plan-execution cost
# (written by the KICKOFF git-op hook on each commit) never overwrite or sum.
# Never blocks: a jq failure leaves the prior sidecar untouched and logs to
# stderr; it never aborts the tally and never fabricates. A command record is
# unattributed and sidecar-less like review: no cost.json, ever, even if
# --out-dir is somehow supplied.
if [[ -n "$OUTPUT_DIRECTORY" && -n "$record" && "$ACTION" != "command" ]]; then
  mkdir -p "$OUTPUT_DIRECTORY" 2>/dev/null
  sidecar="$OUTPUT_DIRECTORY/cost.json"
  if [[ -f "$sidecar" ]]; then
    updated="$(jq -c --argjson record "$record" --arg phase_kind "$ACTION" '. + {($phase_kind): $record}' "$sidecar" 2>/dev/null || true)"
  else
    updated="$(jq -cn --argjson record "$record" --arg phase_kind "$ACTION" '{($phase_kind): $record}' 2>/dev/null || true)"
  fi
  if [[ -n "$updated" ]] && jq -e 'type=="object"' >/dev/null 2>&1 <<<"$updated"; then
    printf '%s\n' "$updated" >"$sidecar" 2>/dev/null || log "token-tally: cost.json write failed: $sidecar"
  else
    log "token-tally: could not build cost.json; leaving prior sidecar as-is"
  fi
fi

# ---------- stdout tally block (README C4; FC-7 for --action command) ----------
# The unpriced-model marker both stdout shapes below append, worded as
# token-rollup.sh:402 already words it. It keys on an unpriced MODEL, never on a
# $0.00 total: a mixed-model run whose other model priced correctly reports a
# plausible non-zero figure while silently dropping the unpriced model's share,
# so a total-keyed check would stay quiet on exactly the rows that most need it.
# `", "`, the separator token-rollup.sh:305 joins its own list with. A bare space
# reads as one hyphenated name per model once two models are unpriced.
UNPRICED_LIST="$(jq -r 'join(", ")' <<<"$UNPRICED_JSON" 2>/dev/null || true)"

if [[ "$ACTION" == "command" ]]; then
  # Exactly one line, no per-stage breakdown (a command run has one stage), so
  # every command surface relays a byte-identical line. Never bash integer
  # arithmetic (it would truncate); LC_ALL=C keeps a locale's comma decimal
  # separator from leaking in.
  total_millions="$(LC_ALL=C awk -v total_tokens="$TOTAL" 'BEGIN{printf "%.1f", total_tokens/1000000}')"
  if [[ "$COST_DOLLARS_RAW" == "null" ]]; then
    cost_part="cost unavailable"
  else
    cost_part="$(LC_ALL=C awk -v cost_dollars="$COST_DOLLARS_RAW" 'BEGIN{printf "$%.2f", cost_dollars}')"
  fi
  line="Cost: ~${total_millions}M tokens, ${cost_part}"
  [[ "$DURATION_AVAILABLE" == "true" ]] && line="${line}, ${HUMAN_ELAPSED}"
  [[ "$partial" -ne 0 ]] && line="${line} (partial: lower bound)"
  [[ -n "$UNPRICED_LIST" ]] && line="${line} (lower bound: unpriced model(s) ${UNPRICED_LIST})"
  printf '%s\n' "$line"
else
  printf 'Cost (%s):\n' "$output_title"
  printf '  Fresh input:  %s\n' "$FRESH_INPUT"
  printf '  Cache write:  %s\n' "$CACHE_WRITE"
  printf '  Cache read:   %s\n' "$CACHE_READ"
  printf '  Output:       %s\n' "$OUTPUT"
  printf '  Total:        %s\n' "$TOTAL"
  if [[ "$DURATION_AVAILABLE" == "true" ]]; then
    printf '  Elapsed:      %s  (first to last model turn: %s to %s)\n' "$HUMAN_ELAPSED" "$LOCAL_START" "$LOCAL_END"
  else
    printf '  Elapsed:      unavailable (no readable turn timestamps)\n'
  fi
  if [[ "$partial" -ne 0 ]]; then
    printf '  (partial: figures are a lower bound; some inputs were unreadable)\n'
  fi
  if [[ -n "$UNPRICED_LIST" ]]; then
    printf '  (lower bound: unpriced model(s) %s)\n' "$UNPRICED_LIST"
  fi
fi

exit 0
