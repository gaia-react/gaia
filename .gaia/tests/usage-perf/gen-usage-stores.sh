#!/usr/bin/env bash
# gen-usage-stores.sh: seeded, byte-reproducible synthetic usage ledger.
#
# usage: gen-usage-stores.sh <months> <outdir> [--seed <n>] [--scale <fraction>]
#
# Writes usage.jsonl, links.jsonl, cost.jsonl and probes.json into <outdir>.
# The shape follows the readout's measured ledger: per month about 150 new
# branch keys, 700 sessions, 4,191 segments, 625 bindings, 3,155 cursor rows,
# 60 merged PRs and 480 cost rows. Defaults: seed 89, scale 1. --scale shrinks
# every per-month count proportionally (floor 1) for a fast smoke run.
#
# probes.json carries typical_pr, widest_pr, the probe set (every probe a
# {pr, key, raw, category, expect} object), initiative_roots, and the byte
# offset `cut` of each store where the final day starts (a line boundary), so
# the rows of the final day are a byte suffix of each store.
#
# The `interval` probe's key is a branch whose spec or plan root owns the
# segments a closed start-binding interval attributes: no interval can name a
# branch directly, so the interval shows up as spend under the root `pr` prints.
# The `no_spend` probe's window holds no segment, so its figures read zero.
#
# Reproducibility: one awk program with its own Park-Miller generator, integer
# arithmetic below 2^53 and 32-bit-safe printf conversions, and no rand(),
# srand(), or strftime(), whose results differ between awk implementations. Set
# GAIA_PERF_AWK to run another awk binary. Rows are ordered by timestamp.
#
# Maintainer tooling, release-excluded with the rest of .gaia/tests.

set -euo pipefail

# 2026-10-01T00:00:00Z. A fixed end keeps equal arguments byte-identical.
BASE_END_EPOCH=1790812800

usage() {
  cat <<'EOF'
usage: gen-usage-stores.sh <months> <outdir> [--seed <n>] [--scale <fraction>]
  <months>   whole months of history to generate (a month is 30 days)
  <outdir>   written: usage.jsonl links.jsonl cost.jsonl probes.json
  --seed     generator seed, a non-negative integer (default 89)
  --scale    fraction in (0, 1] shrinking every per-month count (default 1)
EOF
}

die() {
  printf 'gen-usage-stores: %s\n' "$*" >&2
  exit 2
}

months="" output_directory="" seed=89 scale=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --seed | --scale)
      [ $# -ge 2 ] || die "$1 needs a value"
      if [ "$1" = --seed ]; then seed="$2"; else scale="$2"; fi
      shift 2 ;;
    -*) usage >&2; die "unknown flag $1" ;;
    *)
      if [ -z "$months" ]; then months="$1"
      elif [ -z "$output_directory" ]; then output_directory="$1"
      else usage >&2; die "unexpected argument $1"; fi
      shift ;;
  esac
done
[ -n "$months" ] && [ -n "$output_directory" ] || { usage >&2; die "months and outdir are required"; }
[[ "$months" =~ ^[1-9][0-9]{0,2}$ ]] || die "months must be a whole number from 1 to 999"
[[ "$seed" =~ ^[0-9]{1,15}$ ]] || die "--seed must be a non-negative integer"
[[ "$scale" =~ ^[0-9]*\.?[0-9]+$ ]] || die "--scale must be a decimal in (0, 1]"
awk_bin="${GAIA_PERF_AWK:-awk}"
LC_ALL=C "$awk_bin" -v scale_candidate="$scale" 'BEGIN { exit !(scale_candidate > 0 && scale_candidate <= 1) }' || die "--scale must be a decimal in (0, 1]"

mkdir -p "$output_directory"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/gen-usage-stores.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

IFS= read -r -d '' GEN_PROGRAM <<'AWK' || true
function random_below(limit) {
  SEED = (16807 * SEED) % 2147483647
  return int((SEED - 1) * limit / 2147483646)
}
function random_between(low, high) { return low + random_below(high - low + 1) }
function scaled_count(base_count, fraction,   scaled) {
  scaled = int(base_count * fraction * SCALE + 0.5)
  return scaled < 1 ? 1 : scaled
}

# Civil date from epoch seconds (Hinnant), so no strftime is needed.
function civil_date(epoch_seconds,   shifted_days, seconds_of_day, era, day_of_era, year_of_era, day_of_year, shifted_month) {
  shifted_days = int(epoch_seconds / 86400)
  seconds_of_day = epoch_seconds - shifted_days * 86400
  shifted_days += 719468
  era = int(shifted_days / 146097)
  day_of_era = shifted_days - era * 146097
  year_of_era = int((day_of_era - int(day_of_era / 1460) + int(day_of_era / 36524) - int(day_of_era / 146096)) / 365)
  CIVIL_YEAR = year_of_era + era * 400
  day_of_year = day_of_era - (365 * year_of_era + int(year_of_era / 4) - int(year_of_era / 100))
  shifted_month = int((5 * day_of_year + 2) / 153)
  CIVIL_DAY = day_of_year - int((153 * shifted_month + 2) / 5) + 1
  CIVIL_MONTH = shifted_month < 10 ? shifted_month + 3 : shifted_month - 9
  if (CIVIL_MONTH <= 2) CIVIL_YEAR++
  CIVIL_HOUR = int(seconds_of_day / 3600)
  CIVIL_MINUTE = int((seconds_of_day - CIVIL_HOUR * 3600) / 60)
  CIVIL_SECOND = seconds_of_day - CIVIL_HOUR * 3600 - CIVIL_MINUTE * 60
}
function iso(epoch_seconds, milliseconds) {
  civil_date(epoch_seconds)
  if (milliseconds < 0) return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", CIVIL_YEAR, CIVIL_MONTH, CIVIL_DAY, CIVIL_HOUR, CIVIL_MINUTE, CIVIL_SECOND)
  return sprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", CIVIL_YEAR, CIVIL_MONTH, CIVIL_DAY, CIVIL_HOUR, CIVIL_MINUTE, CIVIL_SECOND, milliseconds)
}
function stamp(epoch_seconds,   v) {
  civil_date(epoch_seconds)
  return sprintf("%04d%02d%02dT%02d%02d%02dZ", CIVIL_YEAR, CIVIL_MONTH, CIVIL_DAY, CIVIL_HOUR, CIVIL_MINUTE, CIVIL_SECOND)
}

# Every row leaves here as <store letter><13-digit sort key><TAB><json>; the
# wrapper sorts on that prefix and strips it.
function emit_row(store_letter, epoch_seconds, milliseconds, json) {
  if (milliseconds < 0) milliseconds = 0
  printf "%s%010d%03d\t%s\n", store_letter, epoch_seconds, milliseconds, json
}

function random_session_id(   first_word, second_word, third_word, fourth_word, fifth_word, sixth_word, seventh_word, eighth_word) {
  first_word = random_below(65536); second_word = random_below(65536); third_word = random_below(65536); fourth_word = random_below(65536)
  fifth_word = random_below(65536); sixth_word = random_below(65536); seventh_word = random_below(65536); eighth_word = random_below(65536)
  return sprintf("%04x%04x-%04x-%04x-%04x-%04x%04x%04x", first_word, second_word, third_word, fourth_word, fifth_word, sixth_word, seventh_word, eighth_word)
}
function random_message_id(   first_index, second_index, third_index, fourth_index) {
  first_index = random_below(4096); second_index = random_below(4096); third_index = random_below(4096); fourth_index = random_below(4096)
  return "msg_011C" MESSAGE_SUFFIXES[first_index] MESSAGE_SUFFIXES[second_index] MESSAGE_SUFFIXES[third_index] MESSAGE_SUFFIXES[fourth_index]
}
function random_high_water_ids(   i, id_list, message_id) {
  id_list = ""
  for (i = 0; i < 8; i++) { message_id = random_message_id(); id_list = id_list (i ? "," : "") "\"" message_id "\"" }
  return "[" id_list "]"
}
function random_model_value(   fresh_input_tokens, cache_write_five_minute_tokens, cache_write_one_hour_tokens, cache_read_tokens, output_tokens, has_five_minute_write) {
  fresh_input_tokens = random_below(401); has_five_minute_write = random_below(2); cache_write_five_minute_tokens = has_five_minute_write ? random_below(90001) : 0
  cache_write_one_hour_tokens = random_below(120001); cache_read_tokens = random_between(10000, 3000000); output_tokens = random_between(100, 30000)
  return sprintf("{\"fresh_input\":%d,\"cache_write_5m\":%d,\"cache_write_1h\":%d,\"cache_read\":%d,\"output\":%d}", fresh_input_tokens, cache_write_five_minute_tokens, cache_write_one_hour_tokens, cache_read_tokens, output_tokens)
}
# Sets FIRST_MODEL_VALUE to the first model's value object, returns the by_model object.
function by_model_object(model_count,   first_model_index, second_model_index, object_text) {
  first_model_index = random_below(4)
  FIRST_MODEL_VALUE = random_model_value()
  object_text = "{\"" MODEL_NAMES[first_model_index] "\":" FIRST_MODEL_VALUE
  if (model_count == 2) {
    second_model_index = (first_model_index + 1 + random_below(3)) % 4
    object_text = object_text ",\"" MODEL_NAMES[second_model_index] "\":" random_model_value()
  }
  return object_text "}"
}
function dollars(   whole_dollars, micro_dollars) {
  whole_dollars = random_below(20); micro_dollars = random_below(1000000)
  return sprintf("%d.%06d", whole_dollars, micro_dollars)
}
function random_model_count(   draw) { draw = random_below(5); return draw == 0 ? 2 : 1 }

function segment_row(key, session_id, inherit, start_seconds, milliseconds, end_seconds, end_milliseconds,   message_count, model_count, by_model_json) {
  message_count = random_between(1, 40)
  model_count = random_model_count()
  by_model_json = by_model_object(model_count)
  emit_row("u", start_seconds, milliseconds, "{\"schema_version\":1,\"kind\":\"segment\",\"key\":\"" key "\",\"session_id\":\"" session_id "\",\"inherit\":" (inherit ? "true" : "false") ",\"first_ts\":\"" iso(start_seconds, milliseconds) "\",\"last_ts\":\"" iso(end_seconds, end_milliseconds) "\",\"messages\":" message_count ",\"by_model\":" by_model_json "}")
}
# One segment of ~10 minutes at second epoch_seconds.
function probe_segment(key, session_id, inherit, epoch_seconds,   milliseconds, end_milliseconds) {
  milliseconds = random_below(1000); end_milliseconds = random_below(1000)
  segment_row(key, session_id, inherit, epoch_seconds, milliseconds, epoch_seconds + 600, end_milliseconds)
}
function binding_start(session_id, epoch_seconds, workflow) {
  emit_row("u", epoch_seconds, 0, "{\"schema_version\":1,\"kind\":\"binding\",\"type\":\"start\",\"session_id\":\"" session_id "\",\"ts\":\"" iso(epoch_seconds, 0) "\",\"workflow\":\"" workflow "\",\"source\":\"transcript\"}")
}
function binding_research(session_id, epoch_seconds, reference) {
  emit_row("u", epoch_seconds, 0, "{\"schema_version\":1,\"kind\":\"binding\",\"type\":\"research\",\"session_id\":\"" session_id "\",\"ts\":\"" iso(epoch_seconds, 0) "\",\"ref\":\"" reference "\",\"source\":\"transcript\"}")
}
function binding_declare(session_id, epoch_seconds, reference) {
  emit_row("u", epoch_seconds, 0, "{\"schema_version\":1,\"kind\":\"binding\",\"type\":\"declare\",\"session_id\":\"" session_id "\",\"ts\":\"" iso(epoch_seconds, -1) "\",\"ref\":\"" reference "\",\"source\":\"declare-command\",\"invoking_session_id\":\"" session_id "\",\"sidechain\":false}")
}
function cursorrow(session_id, epoch_seconds,   roll, role, path, offset, milliseconds, first_word, second_word, third_word, fourth_word) {
  roll = random_below(10)
  milliseconds = random_below(1000)
  if (roll < 3) {
    role = "main"
    path = "/Users/dev/.claude/projects/-Users-dev-repo/" session_id ".jsonl"
  } else {
    first_word = random_below(65536); second_word = random_below(65536); third_word = random_below(65536); fourth_word = random_below(4096)
    role = sprintf("subagents/agent-a%04x%04x%04x%03x.jsonl", first_word, second_word, third_word, fourth_word)
    path = "/Users/dev/.claude/projects/-Users-dev-repo/" session_id "/" role
  }
  offset = random_between(10000, 3000000)
  emit_row("u", epoch_seconds, milliseconds, "{\"schema_version\":1,\"kind\":\"cursor\",\"session_id\":\"" session_id "\",\"role\":\"" role "\",\"path\":\"" path "\",\"offset\":" offset ",\"size\":" offset ",\"hw_ts\":\"" iso(epoch_seconds, milliseconds) "\",\"hw_ids\":" random_high_water_ids() ",\"ts\":\"" iso(epoch_seconds, -1) "\"}")
}
# extra_members is a pre-formatted run of members, no braces and no trailing comma.
function costrow(kind, session_id, cost_end_seconds, extra_members, git_branch, cwd,   by_model_json, dollars_text, nb) {
  by_model_json = by_model_object(1)
  dollars_text = dollars()
  emit_row("c", cost_end_seconds, 0, "{\"schema_version\":1,\"kind\":\"" kind "\"," extra_members ",\"plan_slug\":null,\"session_id\":\"" session_id "\",\"buckets\":{\"fresh_input\":1,\"cache_write\":2,\"cache_read\":3,\"output\":4},\"total\":10,\"by_model\":" by_model_json ",\"by_agent_type\":{\"main\":" FIRST_MODEL_VALUE ",\"general-purpose\":" FIRST_MODEL_VALUE "},\"dollars\":" dollars_text ",\"rate_table_id\":\"sha256:6d17ab141d05c333\",\"partial\":false,\"started_at\":\"" iso(cost_end_seconds - 900, 0) "\",\"ended_at\":\"" iso(cost_end_seconds, 0) "\",\"duration_seconds\":900,\"duration_available\":true,\"git_branch\":\"" git_branch "\",\"project\":\"sha256:e8a9fc325f102fc0\",\"seq\":0,\"final\":true,\"ts\":\"" iso(cost_end_seconds, -1) "\",\"session_cwd\":\"" cwd "\",\"source\":\"orchestrator\"}")
}
function cost_plain(kind, session_id, cost_end_seconds, extra_members, git_branch) { costrow(kind, session_id, cost_end_seconds, extra_members, git_branch, "/Users/dev/repo") }
function worktree_name(branch_name,   encoded_branch) {
  encoded_branch = branch_name
  gsub(/\//, "+", encoded_branch)
  return "worktree-" encoded_branch
}

function edge(child, parent, source, epoch_seconds, session_id,   session_json) {
  session_json = session_id == "" ? "null" : "\"" session_id "\""
  emit_row("l", epoch_seconds, 0, "{\"schema_version\":1,\"kind\":\"edge\",\"child\":\"" child "\",\"parent\":\"" parent "\",\"source\":\"" source "\",\"ts\":\"" iso(epoch_seconds, -1) "\",\"session_id\":" session_json ",\"sidechain\":false}")
}
function mergerow(pr, key, epoch_seconds, session_id,   session_json) {
  session_json = session_id == "" ? "null" : "\"" session_id "\""
  emit_row("l", epoch_seconds, 0, "{\"schema_version\":1,\"kind\":\"merge\",\"pr\":" pr ",\"key\":\"" key "\",\"merged_at\":\"" iso(epoch_seconds, -1) "\",\"source\":\"gh-pr-merge\",\"ts\":\"" iso(epoch_seconds, -1) "\",\"session_id\":" session_json "}")
}
function unlinkrow(child, parent, epoch_seconds) {
  emit_row("l", epoch_seconds, 0, "{\"schema_version\":1,\"kind\":\"unlink\",\"child\":\"" child "\",\"parent\":\"" parent "\",\"source\":\"link-command\",\"ts\":\"" iso(epoch_seconds, -1) "\",\"session_id\":null,\"sidechain\":false}")
}
# A PR's rows: the create edge, the merge row, and the merge edge.
function prrows(pr, key, create_seconds, merge_seconds, session_id) {
  edge("pr:" pr, key, "gh-pr-create", create_seconds, session_id)
  mergerow(pr, key, merge_seconds, session_id)
  edge("pr:" pr, key, "gh-pr-merge", merge_seconds, session_id)
}

function newbranch(period_start_seconds, period_length_seconds,   roll, branch_name, pick, slug_pick, epoch_seconds) {
  roll = random_below(100)
  if (roll < 45) {
    LAST_ISSUE_NUMBER++
    pick = random_below(5)
    branch_name = "debt/" LAST_ISSUE_NUMBER "-" DEBT_SLUGS[pick]
    pick = random_below(10)
    if (pick == 0) { LAST_ISSUE_NUMBER++; branch_name = "debt/" (LAST_ISSUE_NUMBER - 1) "-" LAST_ISSUE_NUMBER "-batch" }
  } else if (roll < 60) {
    LAST_SPEC_NUMBER++
    pick = random_below(4)
    branch_name = sprintf("plan/spec-%03d-%s", LAST_SPEC_NUMBER, SPEC_SLUGS[pick])
    SPEC_ROOT_NUMBERS[++SPEC_ROOT_COUNT] = LAST_SPEC_NUMBER
  } else if (roll < 65) {
    LAST_PLAN_NUMBER++
    branch_name = sprintf("plan/plan-%03d-x", LAST_PLAN_NUMBER)
  } else if (roll < 80) {
    LAST_ISSUE_NUMBER++
    pick = random_below(3); slug_pick = random_below(3)
    branch_name = BRANCH_TYPES[pick] "/" LAST_ISSUE_NUMBER "-" ISSUE_SLUGS[slug_pick]
  } else if (roll < 88) {
    epoch_seconds = period_start_seconds + random_below(period_length_seconds)
    civil_date(epoch_seconds)
    branch_name = sprintf("chore/task-%04d-%02d-%02d-%02d%02d", CIVIL_YEAR, CIVIL_MONTH, CIVIL_DAY, CIVIL_HOUR, CIVIL_MINUTE)
  } else if (roll < 93) {
    LAST_SPEC_NUMBER++
    pick = random_below(2)
    branch_name = sprintf("spec-%03d-%s", LAST_SPEC_NUMBER, BARE_SPEC_SLUGS[pick])
  } else {
    pick = random_below(3); slug_pick = random_below(1000001)
    branch_name = "feat/" FEATURE_SLUGS[pick] "-" slug_pick
  }
  ACTIVE_BRANCHES[++ACTIVE_BRANCH_COUNT] = branch_name
}
function pick_active_branch(   low_index) {
  low_index = ACTIVE_BRANCH_COUNT > 300 ? ACTIVE_BRANCH_COUNT - 299 : 1
  return ACTIVE_BRANCHES[low_index + random_below(ACTIVE_BRANCH_COUNT - low_index + 1)]
}

# One stretch of history [period_start_seconds, period_start_seconds + period_length_seconds) holding fraction of a month's activity.
function generate_period(period_start_seconds, period_length_seconds, fraction,   period_end_seconds, branch_count, i, session_count, segment_count, binding_start_count, binding_research_count, binding_declare_count, closed_interval_count, extra_cost_count, merge_count, j, scratch_value, session_segment_count, session_id, epoch_seconds, end_seconds, session_branch, key, inherit, roll, workflow, cost_end_seconds, subject_name, git_branch, pr, create_seconds, merge_seconds, wide_root, kind, extra_members, run_id, cursor_count, link_count, spec_number, milliseconds, end_milliseconds, session_start_seconds, segmented_session_count) {
  period_end_seconds = period_start_seconds + period_length_seconds
  branch_count = scaled_count(150, fraction)
  for (i = 0; i < branch_count; i++) newbranch(period_start_seconds, period_length_seconds)
  session_count = scaled_count(700, fraction)
  split("", SESSION_IDS); split("", SEGMENTS_PER_SESSION); split("", SEGMENTED_SESSIONS); split("", SESSION_FIRST_SECONDS)
  for (i = 0; i < session_count; i++) { SESSION_IDS[i] = random_session_id(); SEGMENTS_PER_SESSION[i] = 0 }
  segment_count = scaled_count(4191, fraction)
  for (i = 0; i < segment_count; i++) { scratch_value = random_below(session_count); SEGMENTS_PER_SESSION[scratch_value]++ }
  segmented_session_count = 0
  for (i = 0; i < session_count; i++) {
    session_segment_count = SEGMENTS_PER_SESSION[i]
    if (session_segment_count == 0) continue
    session_id = SESSION_IDS[i]
    scratch_value = period_length_seconds - session_segment_count * 1500
    if (scratch_value < 0) scratch_value = 0
    epoch_seconds = period_start_seconds + random_below(scratch_value + 1)
    roll = random_below(10)
    session_branch = roll < 6 ? pick_active_branch() : ""
    SEGMENTED_SESSIONS[++segmented_session_count] = i
    for (j = 0; j < session_segment_count; j++) {
      scratch_value = random_between(20, 1800)
      epoch_seconds += scratch_value
      scratch_value = random_between(5, 900)
      end_seconds = epoch_seconds + scratch_value
      if (end_seconds >= period_end_seconds) end_seconds = period_end_seconds - 1
      if (epoch_seconds > end_seconds) epoch_seconds = end_seconds
      if (j == 0) SESSION_FIRST_SECONDS[i] = epoch_seconds
      roll = random_below(100)
      inherit = roll < 6
      roll = random_below(100)
      if (inherit) key = "session:" session_id
      else if (session_branch != "" && roll < 85) key = "branch:" session_branch
      else key = "session:" session_id
      milliseconds = random_below(1000); end_milliseconds = random_below(1000)
      segment_row(key, session_id, inherit, epoch_seconds, milliseconds, end_seconds, end_milliseconds)
      epoch_seconds = end_seconds
    }
  }
  binding_start_count = scaled_count(280, fraction); binding_research_count = scaled_count(270, fraction); binding_declare_count = scaled_count(75, fraction)
  closed_interval_count = 0
  for (i = 0; i < binding_start_count; i++) {
    scratch_value = 1 + random_below(segmented_session_count); session_id = SESSION_IDS[SEGMENTED_SESSIONS[scratch_value]]; session_start_seconds = SESSION_FIRST_SECONDS[SEGMENTED_SESSIONS[scratch_value]]
    epoch_seconds = session_start_seconds - random_below(601)
    if (epoch_seconds < period_start_seconds) epoch_seconds = period_start_seconds
    workflow = WORKFLOW_NAMES[random_below(6)]
    binding_start(session_id, epoch_seconds, workflow)
    roll = random_below(100)
    if (roll < 85) {
      cost_end_seconds = epoch_seconds + random_between(300, 5400)
      if (cost_end_seconds >= period_end_seconds) cost_end_seconds = period_end_seconds - 1
      closed_interval_count++
      if (workflow == "gaia-spec") {
        LAST_SPEC_NUMBER++
        cost_plain("spec", session_id, cost_end_seconds, sprintf("\"spec_id\":\"SPEC-%03d\",\"plan_id\":null", LAST_SPEC_NUMBER), "main")
      } else if (workflow == "gaia-plan") {
        scratch_value = random_below(21)
        scratch_value = LAST_SPEC_NUMBER - scratch_value
        if (scratch_value < 101) scratch_value = 101
        cost_plain("plan", session_id, cost_end_seconds, sprintf("\"spec_id\":\"SPEC-%03d\",\"plan_id\":null", scratch_value), "main")
      } else {
        LAST_RUN_INDEX++
        run_id = sprintf("%s-%s-%04x", workflow, stamp(cost_end_seconds), LAST_RUN_INDEX)
        extra_members = "\"spec_id\":null,\"plan_id\":null,\"command\":\"" workflow "\",\"run_id\":\"" run_id "\""
        roll = random_below(10)
        if (workflow == "gaia-debt" && roll < 7) {
          LAST_PR_NUMBER++
          extra_members = extra_members ",\"github\":{\"type\":\"pr\",\"number\":" LAST_PR_NUMBER ",\"repo\":\"x/y\"}"
        }
        cost_plain("command", session_id, cost_end_seconds, extra_members, "main")
      }
    }
  }
  for (i = 0; i < binding_research_count; i++) {
    scratch_value = 1 + random_below(segmented_session_count); session_id = SESSION_IDS[SEGMENTED_SESSIONS[scratch_value]]; session_start_seconds = SESSION_FIRST_SECONDS[SEGMENTED_SESSIONS[scratch_value]]
    epoch_seconds = session_start_seconds - random_below(601)
    if (epoch_seconds < period_start_seconds) epoch_seconds = period_start_seconds
    roll = random_below(1000)
    if (roll < 110) subject_name = "research:wide-a"
    else if (roll < 165) subject_name = "research:wide-b"
    else { scratch_value = random_below(401); subject_name = "research:topic-" scratch_value }
    binding_research(session_id, epoch_seconds, subject_name)
  }
  for (i = 0; i < binding_declare_count; i++) {
    scratch_value = 1 + random_below(segmented_session_count); session_id = SESSION_IDS[SEGMENTED_SESSIONS[scratch_value]]; session_start_seconds = SESSION_FIRST_SECONDS[SEGMENTED_SESSIONS[scratch_value]]
    epoch_seconds = session_start_seconds - random_below(601)
    if (epoch_seconds < period_start_seconds) epoch_seconds = period_start_seconds
    roll = random_below(2)
    scratch_value = random_below(101)
    subject_name = (roll ? "research" : "init") ":slug-" scratch_value
    binding_declare(session_id, epoch_seconds, subject_name)
  }
  cursor_count = scaled_count(3155, fraction)
  for (i = 0; i < cursor_count; i++) {
    session_id = SESSION_IDS[random_below(session_count)]
    epoch_seconds = period_start_seconds + random_below(period_length_seconds)
    cursorrow(session_id, epoch_seconds)
  }
  extra_cost_count = scaled_count(480, fraction) - closed_interval_count
  for (i = 0; i < extra_cost_count; i++) {
    session_id = SESSION_IDS[random_below(session_count)]
    cost_end_seconds = period_start_seconds + random_below(period_length_seconds)
    roll = random_below(100)
    if (roll < 55) {
      subject_name = pick_active_branch()
      scratch_value = random_below(10)
      git_branch = scratch_value < 3 ? worktree_name(subject_name) : subject_name
      scratch_value = random_below(31)
      scratch_value = LAST_SPEC_NUMBER - scratch_value
      if (scratch_value < 101) scratch_value = 101
      cost_plain("execute", session_id, cost_end_seconds, sprintf("\"spec_id\":\"SPEC-%03d\",\"plan_id\":null", scratch_value), git_branch)
    } else if (roll < 75) {
      subject_name = pick_active_branch()
      cost_plain("review", session_id, cost_end_seconds, "\"spec_id\":null,\"plan_id\":null", subject_name)
    } else {
      LAST_RUN_INDEX++
      run_id = sprintf("gaia-wiki-%s-%04x", stamp(cost_end_seconds), LAST_RUN_INDEX)
      cost_plain("command", session_id, cost_end_seconds, "\"spec_id\":null,\"plan_id\":null,\"command\":\"gaia-wiki\",\"run_id\":\"" run_id "\"", "main")
    }
  }
  merge_count = scaled_count(60, fraction)
  for (j = 0; j < merge_count; j++) {
    subject_name = pick_active_branch()
    LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
    create_seconds = period_start_seconds + random_below(period_length_seconds)
    scratch_value = random_between(1, 72)
    merge_seconds = create_seconds + scratch_value * 3600
    if (merge_seconds >= period_end_seconds) merge_seconds = period_end_seconds - 1
    if (create_seconds > merge_seconds) create_seconds = merge_seconds
    session_id = SESSION_IDS[random_below(session_count)]
    prrows(pr, "branch:" subject_name, create_seconds, merge_seconds, session_id)
    if (j % 6 == 0) wide_root = "research:wide-a"
    else if (j % 12 == 1) wide_root = "research:wide-b"
    else wide_root = ""
    if (wide_root != "") {
      scratch_value = random_below(3600)
      epoch_seconds = merge_seconds + scratch_value
      if (epoch_seconds >= period_end_seconds) epoch_seconds = period_end_seconds - 1
      edge("branch:" subject_name, wide_root, "link-command", epoch_seconds, "")
      WIDE_ROOT_LINK_COUNTS[wide_root]++
    }
  }
  link_count = scaled_count(10, fraction)
  for (i = 0; i < link_count; i++) {
    epoch_seconds = period_start_seconds + random_below(period_length_seconds)
    spec_number = SPEC_ROOT_COUNT > 0 ? SPEC_ROOT_NUMBERS[1 + random_below(SPEC_ROOT_COUNT)] : 101
    scratch_value = random_below(401)
    edge(sprintf("spec:SPEC-%03d", spec_number), "research:topic-" scratch_value, "spec-frontmatter", epoch_seconds, "")
  }
  link_count = scaled_count(2, fraction)
  for (i = 0; i < link_count; i++) {
    epoch_seconds = period_start_seconds + random_below(period_length_seconds)
    subject_name = pick_active_branch()
    unlinkrow("branch:" subject_name, "issue:1", epoch_seconds)
  }
}

function addprobe(pr, key, raw, category, expect,   key_json, raw_json) {
  key_json = key == "" ? "null" : "\"" key "\""
  raw_json = raw == "" ? "null" : "\"" raw "\""
  PROBES = PROBES (PROBE_COUNT ? ",\n" : "") "  {\"pr\":" pr ",\"key\":" key_json ",\"raw\":" raw_json ",\"category\":\"" category "\",\"expect\":{" expect "}}"
  PROBE_COUNT++
}

# The probe structures, built around the day that starts at day_start_seconds. Eight
# categories land in every set; the final set also carries the cursor probe and
# names the typical, widest, and initiative probes.
function probe_set(day_start_seconds, is_final, uses_plan_variant,   issue_number, branch_name, session_id, second_session_id, pr, first_pr, second_pr, research_session_id, research_reference, plan_number, plan_session_id, execute_session_id, reference, k, epoch_seconds) {
  issue_number = NEXT_PROBE_ISSUE++
  branch_name = "debt/" issue_number "-first"
  session_id = random_session_id()
  LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 3600)
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 7200)
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 10800)
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 25200)
  prrows(pr, "branch:" branch_name, day_start_seconds + 1800, day_start_seconds + 21600, session_id)
  addprobe(pr, "branch:" branch_name, "worktree-debt+" issue_number "-first", "first_merge", "\"merges\":1")
  if (is_final) { TYPICAL = pr; ISSUE_ROOT = "issue:" issue_number }

  issue_number = NEXT_PROBE_ISSUE++
  branch_name = "fix/" issue_number "-repeat"
  session_id = random_session_id(); second_session_id = random_session_id()
  LAST_PR_NUMBER++; first_pr = LAST_PR_NUMBER
  LAST_PR_NUMBER++; second_pr = LAST_PR_NUMBER
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds - 180000)
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds - 176400)
  prrows(first_pr, "branch:" branch_name, day_start_seconds - 259200, day_start_seconds - 172800, session_id)
  probe_segment("branch:" branch_name, second_session_id, 0, day_start_seconds + 7200)
  probe_segment("branch:" branch_name, second_session_id, 0, day_start_seconds + 10800)
  prrows(second_pr, "branch:" branch_name, day_start_seconds + 3600, day_start_seconds + 32400, second_session_id)
  addprobe(first_pr, "branch:" branch_name, branch_name, "repeat_merge", "\"merges\":2")
  addprobe(second_pr, "branch:" branch_name, branch_name, "repeat_merge", "\"merges\":2")

  issue_number = NEXT_PROBE_ISSUE++
  branch_name = "debt/" issue_number "-multi"
  research_reference = "research:multi-" issue_number
  session_id = random_session_id(); research_session_id = random_session_id()
  LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
  binding_research(research_session_id, day_start_seconds + 1800, research_reference)
  probe_segment("session:" research_session_id, research_session_id, 0, day_start_seconds + 3000)
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 3600)
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 7200)
  edge("branch:" branch_name, research_reference, "link-command", day_start_seconds + 1800, "")
  prrows(pr, "branch:" branch_name, day_start_seconds + 1800, day_start_seconds + 28800, session_id)
  addprobe(pr, "branch:" branch_name, branch_name, "multi_root", "\"roots_min\":2")
  if (is_final) RESEARCH_ROOT = research_reference

  issue_number = NEXT_PROBE_ISSUE++
  branch_name = "feat/" issue_number "-inherit"
  session_id = random_session_id()
  LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 3600)
  probe_segment("session:" session_id, session_id, 1, day_start_seconds + 7200)
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 10800)
  prrows(pr, "branch:" branch_name, day_start_seconds + 1800, day_start_seconds + 28800, session_id)
  addprobe(pr, "branch:" branch_name, branch_name, "inherit", "\"inherit\":true")

  plan_number = NEXT_PROBE_PLAN++
  plan_session_id = random_session_id(); execute_session_id = random_session_id()
  LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
  if (uses_plan_variant) {
    branch_name = sprintf("plan/plan-%03d-int", plan_number)
    reference = sprintf("plan:PLAN-%03d", plan_number)
    binding_start(plan_session_id, day_start_seconds + 1800, "gaia-plan")
    cost_plain("plan", plan_session_id, day_start_seconds + 7200, sprintf("\"spec_id\":null,\"plan_id\":\"PLAN-%03d\"", plan_number), "main")
  } else {
    branch_name = sprintf("plan/spec-%03d-int", plan_number)
    reference = sprintf("spec:SPEC-%03d", plan_number)
    binding_start(plan_session_id, day_start_seconds + 1800, "gaia-spec")
    cost_plain("spec", plan_session_id, day_start_seconds + 7200, sprintf("\"spec_id\":\"SPEC-%03d\",\"plan_id\":null", plan_number), "main")
  }
  probe_segment("session:" plan_session_id, plan_session_id, 0, day_start_seconds + 2400)
  probe_segment("session:" plan_session_id, plan_session_id, 0, day_start_seconds + 3600)
  probe_segment("branch:" branch_name, execute_session_id, 0, day_start_seconds + 10800)
  probe_segment("branch:" branch_name, execute_session_id, 0, day_start_seconds + 14400)
  prrows(pr, "branch:" branch_name, day_start_seconds + 9000, day_start_seconds + 32400, execute_session_id)
  addprobe(pr, "branch:" branch_name, branch_name, "interval", "\"interval\":true")
  if (is_final) SPEC_ROOT = reference

  issue_number = NEXT_PROBE_ISSUE++
  branch_name = "docs/" issue_number "-nospend"
  session_id = random_session_id()
  LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
  prrows(pr, "branch:" branch_name, day_start_seconds + 1800, day_start_seconds + 21600, session_id)
  addprobe(pr, "branch:" branch_name, branch_name, "no_spend", "\"no_spend\":true")

  issue_number = NEXT_PROBE_ISSUE++
  branch_name = "debt/" issue_number "-wide"
  session_id = random_session_id()
  LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 3600)
  probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 7200)
  edge("branch:" branch_name, "research:wide-a", "link-command", day_start_seconds + 1800, "")
  WIDE_ROOT_LINK_COUNTS["research:wide-a"]++
  prrows(pr, "branch:" branch_name, day_start_seconds + 1800, day_start_seconds + 28800, session_id)
  addprobe(pr, "branch:" branch_name, branch_name, "wide_root", "\"roots_min\":1")
  if (is_final) WIDEST = pr

  if (is_final) {
    branch_name = "fix/cursor-drift"
    session_id = random_session_id()
    LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
    probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 3600)
    probe_segment("branch:" branch_name, session_id, 0, day_start_seconds + 7200)
    costrow("execute", session_id, day_start_seconds + 7500, "\"spec_id\":null,\"plan_id\":null", branch_name, "/Users/dev/{\\\"schema_version\\\":1,\\\"kind\\\":\\\"cursor\\\",\\\"x\\\":1}")
    emit_row("u", day_start_seconds + 7600, 0, "{\"kind\":\"cursor\",\"schema_version\":1,\"session_id\":\"" session_id "\",\"role\":\"main\",\"path\":\"/Users/dev/.claude/projects/-Users-dev-repo/" session_id ".jsonl\",\"offset\":4096,\"size\":4096,\"hw_ts\":\"" iso(day_start_seconds + 7600, 0) "\",\"hw_ids\":[],\"ts\":\"" iso(day_start_seconds + 7600, -1) "\"}")
    prrows(pr, "branch:" branch_name, day_start_seconds + 1800, day_start_seconds + 28800, session_id)
    addprobe(pr, "branch:" branch_name, branch_name, "cursor_adversarial", "\"nonzero\":true")
  }
}

BEGIN {
  SEED = (seed_input % 2147483646) + 1
  for (i = 0; i < 16; i++) random_below(2)
  SCALE = scale + 0
  split("claude-opus-5-5 claude-sonnet-5-5 claude-haiku-4-5 claude-opus-4-8", MODEL_NAMES, " ")
  for (i = 1; i <= 4; i++) MODEL_NAMES[i - 1] = MODEL_NAMES[i]
  split("gaia-spec gaia-plan gaia-debt gaia-wiki gaia-audit update-deps", WORKFLOW_NAMES_ONE_BASED, " ")
  for (i = 1; i <= 6; i++) WORKFLOW_NAMES[i - 1] = WORKFLOW_NAMES_ONE_BASED[i]
  split("fix-x guard lint docs quote", DEBT_SLUGS_ONE_BASED, " ")
  for (i = 1; i <= 5; i++) DEBT_SLUGS[i - 1] = DEBT_SLUGS_ONE_BASED[i]
  split("cost usage ledger ui", SPEC_SLUGS_ONE_BASED, " ")
  for (i = 1; i <= 4; i++) SPEC_SLUGS[i - 1] = SPEC_SLUGS_ONE_BASED[i]
  split("fix feat chore", BRANCH_TYPES_ONE_BASED, " ")
  for (i = 1; i <= 3; i++) BRANCH_TYPES[i - 1] = BRANCH_TYPES_ONE_BASED[i]
  split("a bb ccc", ISSUE_SLUGS_ONE_BASED, " ")
  for (i = 1; i <= 3; i++) ISSUE_SLUGS[i - 1] = ISSUE_SLUGS_ONE_BASED[i]
  split("foo bar", BARE_SPEC_SLUGS_ONE_BASED, " ")
  for (i = 1; i <= 2; i++) BARE_SPEC_SLUGS[i - 1] = BARE_SPEC_SLUGS_ONE_BASED[i]
  split("widget page hook", FEATURE_SLUGS_ONE_BASED, " ")
  for (i = 1; i <= 3; i++) FEATURE_SLUGS[i - 1] = FEATURE_SLUGS_ONE_BASED[i]
  ALPHA = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz0123456789"
  for (i = 0; i < 4096; i++) {
    suffix = ""
    for (j = 0; j < 5; j++) { alphabet_index = random_below(length(ALPHA)); suffix = suffix substr(ALPHA, alphabet_index + 1, 1) }
    MESSAGE_SUFFIXES[i] = suffix
  }
  LAST_ISSUE_NUMBER = 3000; LAST_SPEC_NUMBER = 100; LAST_PLAN_NUMBER = 10; LAST_PR_NUMBER = 5000; LAST_RUN_INDEX = 0; ACTIVE_BRANCH_COUNT = 0; SPEC_ROOT_COUNT = 0
  NEXT_PROBE_ISSUE = 90001; NEXT_PROBE_PLAN = 901; PROBE_COUNT = 0; PROBES = ""
  SECONDS_PER_DAY = 86400
  END_SECONDS = base_end + 0
  START_SECONDS = END_SECONDS - 30 * months * SECONDS_PER_DAY
  for (month_index = 0; month_index < months - 1; month_index++) generate_period(START_SECONDS + month_index * 30 * SECONDS_PER_DAY, 30 * SECONDS_PER_DAY, 1)
  generate_period(START_SECONDS + (months - 1) * 30 * SECONDS_PER_DAY, 29 * SECONDS_PER_DAY, 29 / 30)
  generate_period(END_SECONDS - SECONDS_PER_DAY, SECONDS_PER_DAY, 1 / 30)

  # The first segment of the ledger, so the earliest-spend probe sits inside
  # the coverage window by construction.
  session_id = random_session_id()
  probe_segment("session:" session_id, session_id, 0, START_SECONDS + 120)
  issue_number = NEXT_PROBE_ISSUE++
  branch_name = "fix/" issue_number "-early"
  session_id = random_session_id()
  LAST_PR_NUMBER++; pr = LAST_PR_NUMBER
  probe_segment("branch:" branch_name, session_id, 0, START_SECONDS + 7200)
  probe_segment("branch:" branch_name, session_id, 0, START_SECONDS + 10800)
  prrows(pr, "branch:" branch_name, START_SECONDS + 14400, START_SECONDS + 3 * SECONDS_PER_DAY, session_id)
  addprobe(pr, "branch:" branch_name, branch_name, "lower_bound", "\"lower_bound\":true")

  probe_set(START_SECONDS + 8 * SECONDS_PER_DAY, 0, 0)
  probe_set(START_SECONDS + int(months * 15) * SECONDS_PER_DAY, 0, 1)
  probe_set(END_SECONDS - SECONDS_PER_DAY, 1, 0)

  addprobe(7777777, "", "", "unresolvable", "\"unresolvable\":true")

  printf "{\"typical_pr\":%d,\"widest_pr\":%d,\"probes\":[\n%s\n],\"initiative_roots\":{\"research\":\"%s\",\"issue\":\"%s\",\"spec\":\"%s\"},\"cut\":__CUT__}\n", TYPICAL, WIDEST, PROBES, RESEARCH_ROOT, ISSUE_ROOT, SPEC_ROOT > probes_file
  close(probes_file)
}
AWK

IFS= read -r -d '' SPLIT_PROGRAM <<'AWK' || true
BEGIN {
  store_files["u"] = usage_file; store_files["l"] = links_file; store_files["c"] = cost_file
  cut_key_text = cutkey ""
}
{
  store_letter = substr($0, 1, 1)
  key = substr($0, 2, 13)
  line = substr($0, 16)
  if (!(store_letter in cut) && (key "") >= cut_key_text) cut[store_letter] = bytes[store_letter] + 0
  print line > store_files[store_letter]
  bytes[store_letter] += length(line) + 1
}
END {
  for (store_letter in store_files) {
    close(store_files[store_letter])
    if (!(store_letter in cut)) cut[store_letter] = bytes[store_letter] + 0
  }
  printf "%d %d %d\n", cut["u"], cut["l"], cut["c"] > cutfile
  close(cutfile)
}
AWK

: >"$output_directory/usage.jsonl"
: >"$output_directory/links.jsonl"
: >"$output_directory/cost.jsonl"
cut_key="$(printf '%010d000' $((BASE_END_EPOCH - 86400)))"

LC_ALL=C "$awk_bin" -v months="$months" -v seed_input="$seed" -v scale="$scale" -v base_end="$BASE_END_EPOCH" \
  -v probes_file="$temporary_directory/probes.frag" "$GEN_PROGRAM" |
  LC_ALL=C sort -s -k1,1 |
  LC_ALL=C "$awk_bin" -v usage_file="$output_directory/usage.jsonl" -v links_file="$output_directory/links.jsonl" -v cost_file="$output_directory/cost.jsonl" \
    -v cutkey="$cut_key" -v cutfile="$temporary_directory/cuts" "$SPLIT_PROGRAM"

read -r cut_usage cut_links cut_cost <"$temporary_directory/cuts"
fragment="$(cat "$temporary_directory/probes.frag")"
cut_json="{\"u\":$cut_usage,\"l\":$cut_links,\"c\":$cut_cost}"
printf '%s\n' "${fragment/__CUT__/$cut_json}" >"$output_directory/probes.json"
