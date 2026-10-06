#!/usr/bin/env bash
# shellcheck shell=bash
#
# audit-light-telemetry.sh: the maintainer-only evidence log for light-review
# routing. It records every router decision, every light-review outcome, and
# every full member result as one JSON Lines event, and `tally` reduces the log
# to the numbers that say whether Light routing pays off and whether it misses
# defects.
#
#   audit-light-telemetry.sh route         --root <r> --record <route-record-path>
#   audit-light-telemetry.sh outcome       --root <r> --member <m> --digest <d> --tree <t>
#                                          --verdict clear|escalate|failed
#                                          [--tokens <n>] [--duration-ms <n>]
#   audit-light-telemetry.sh member-result --root <r> --member <m>
#   audit-light-telemetry.sh tally         [--root <r>] [--baseline-tokens <n>]
#
# Log: <main>/.gaia/local/telemetry/audit-light-routing.jsonl, <main> from
# main-root-lib.sh.
#
# Why maintainer-only: the log answers a question only the maintainer asks, and
# adopters have no use for the file. This script is release-excluded, and the
# three append subcommands additionally check for
# <main>/.claude/rules/maintainers/harness-triage-threshold.md before writing,
# so a copy that ever reaches an adopter checkout still records nothing and
# creates no directory.
#
# Never blocks: telemetry must not change or delay a route. Every append
# subcommand exits 0 with nothing on stdout whatever goes wrong (unwritable
# directory, jq absent, an unreadable record), at most one line on stderr.
# Callers still wrap the call in `|| true`; this is the second wall, not the
# first.
#
# Engagement rate is light routes over post-clearance rotations. The
# denominator is the route events EXCLUDING the reasons no-full-clearance,
# not-opted-in, no-version, and degraded: none of those is a post-clearance
# rotation of an opted-in member (no earlier full clearance exists, or the
# member never opted in, or the version could not be read). `degraded` never
# emits an event but is excluded for robustness. `rotations` still counts every
# route event, so the two lines differ by exactly the excluded reasons.
#
# Light misses are best-effort: a finding from a full member counts as a miss
# when an earlier light clear for the same branch and member covered the
# finding's path, and the finding's line falls inside that route's post-image
# changed ranges. Findings without a numeric line never count.
#
# Bash 3.2 compatible, BWK awk safe. Never `cd`; no `set -e`, because every
# failure here is deliberately swallowed.
set -u

self_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || self_directory=""
repo_directory="$self_directory/../.."

DEFAULT_BASELINE_TOKENS=3300000
MAINTAINER_RULE_RELATIVE_PATH=".claude/rules/maintainers/harness-triage-threshold.md"
LOG_RELATIVE_PATH=".gaia/local/telemetry/audit-light-routing.jsonl"

usage() {
  cat >&2 <<'EOF'
usage: audit-light-telemetry.sh route         --root <r> --record <route-record-path>
       audit-light-telemetry.sh outcome       --root <r> --member <m> --digest <d> --tree <t> --verdict clear|escalate|failed [--tokens <n>] [--duration-ms <n>]
       audit-light-telemetry.sh member-result --root <r> --member <m>
       audit-light-telemetry.sh tally         [--root <r>] [--baseline-tokens <n>]
EOF
}

# One stderr line, never a failure: the append subcommands exit 0 regardless.
swallow() {
  printf 'audit-light-telemetry: %s\n' "$1" >&2
  exit 0
}

if [ "$self_directory" != "" ] && [ -f "$self_directory/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$self_directory/main-root-lib.sh"
fi
if [ "$self_directory" != "" ] && [ -f "$self_directory/audit-key-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$self_directory/audit-key-lib.sh"
fi

subcommand="${1:-}"
case "$subcommand" in
  route | outcome | member-result | tally) shift ;;
  --help | -h)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

root=""
record_path=""
member=""
digest=""
tree=""
verdict=""
tokens=""
duration_milliseconds=""
baseline_tokens="$DEFAULT_BASELINE_TOKENS"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      root="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --record)
      record_path="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --member)
      member="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --digest)
      digest="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --tree)
      tree="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --verdict)
      verdict="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --tokens)
      tokens="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --duration-ms)
      duration_milliseconds="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    --baseline-tokens)
      baseline_tokens="${2:-}"
      shift 2 2>/dev/null || shift
      ;;
    *)
      if [ "$subcommand" = "tally" ]; then
        usage
        exit 2
      fi
      swallow "unknown argument: $1"
      ;;
  esac
done

# The log lives under the main checkout so every worktree of one repository
# feeds the same file.
resolve_main_root() {
  local directory="$1" resolved
  command -v gaia_resolve_main_root >/dev/null 2>&1 || return 1
  resolved="$(gaia_resolve_main_root "$directory" 2>/dev/null)" || return 1
  [ -n "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

is_non_negative_integer() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Token/name fields end up in a path or a record key: refuse anything that could
# climb out of the light directory.
is_plain_token() {
  case "$1" in
    '' | */* | *..*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# tally
# ---------------------------------------------------------------------------

# format_ratio <numerator> <denominator>: two decimals, or n/a on a zero
# denominator.
format_ratio() {
  awk -v numerator="$1" -v denominator="$2" 'BEGIN {
    if (denominator + 0 == 0) { print "n/a"; exit }
    printf "%.2f\n", numerator / denominator
  }'
}

run_tally() {
  local main log counts
  is_non_negative_integer "$baseline_tokens" && [ "$baseline_tokens" -gt 0 ] || {
    printf 'audit-light-telemetry: --baseline-tokens must be a positive integer\n' >&2
    exit 2
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'audit-light-telemetry: jq is required for tally\n' >&2
    exit 1
  }
  main="$(resolve_main_root "${root:-$PWD}")" || main=""
  log=""
  [ -n "$main" ] && log="$main/$LOG_RELATIVE_PATH"

  counts="0	0	0	0	0	0	0	0	"
  if [ -n "$log" ] && [ -f "$log" ]; then
    # A torn or hand-edited line is dropped rather than failing the report.
    counts="$(jq -R -c 'fromjson? // empty' "$log" 2>/dev/null | jq -s -r '
      def excluded_reason: . == "no-full-clearance" or . == "not-opted-in" or . == "no-version" or . == "degraded";
      def median: sort | if length == 0 then null
        else ((.[((length - 1) / 2 | floor)] + .[(length / 2 | floor)]) / 2 | round) end;
      def covered_by($routes; $outcome; $location):
        any($routes[];
          .member == $outcome.member
          and (.branch // "") == ($outcome.branch // "")
          and .digest == $outcome.digest
          and any((.ranges // [])[];
            .path == $location.path
            and any((.post_ranges // [])[];
              ($location.line | type) == "number"
              and .[0] <= $location.line
              and $location.line <= .[1])));
      . as $events
      | [$events[] | select(.event == "route")] as $routes
      | [$events[] | select(.event == "light_outcome")] as $outcomes
      | [$events[] | select(.event == "escalation_followup")] as $followups
      | [ range(0; $events | length) as $i
          | $events[$i]
          | select(.event == "member_result") as $result
          | ($result.locations // [])[] as $location
          | select(
              any(range(0; $i) as $j | $events[$j];
                .event == "light_outcome" and .verdict == "clear"
                and .member == $result.member
                and (.branch // "") == ($result.branch // "")
                and covered_by($routes; .; $location)))
        ] | length as $light_misses
      | [
          ($routes | length),
          ([$routes[] | select(.route == "light")] | length),
          ([$routes[] | select((.reason // "") | excluded_reason | not)] | length),
          ([$outcomes[] | select(.verdict == "escalate")] | length),
          ($outcomes | length),
          ([$followups[] | select(.result == "refused")] | length),
          ($followups | length),
          $light_misses,
          ([$outcomes[] | .tokens | select(type == "number")] | median // "")
        ] | map(tostring) | join("\t")' 2>/dev/null)" || counts=""
    [ -n "$counts" ] || {
      printf 'audit-light-telemetry: cannot read %s\n' "$log" >&2
      exit 1
    }
  fi

  local rotations light_routes denominator escalations light_outcomes
  local refused_followups followups light_misses median_tokens
  IFS='	' read -r rotations light_routes denominator escalations light_outcomes \
    refused_followups followups light_misses median_tokens <<EOF
$counts
EOF

  printf 'rotations: %s\n' "$rotations"
  printf 'light_routes: %s\n' "$light_routes"
  printf 'engagement_rate: %s\n' "$(format_ratio "$light_routes" "$denominator")"
  printf 'escalations: %s\n' "$escalations"
  printf 'escalation_rate: %s\n' "$(format_ratio "$escalations" "$light_outcomes")"
  printf 'escalation_precision: %s\n' "$(format_ratio "$refused_followups" "$followups")"
  printf 'light_misses: %s\n' "$light_misses"
  if [ -n "$median_tokens" ]; then
    printf 'light_median_tokens: %s\n' "$median_tokens"
  else
    printf 'light_median_tokens: n/a\n'
  fi
  printf 'baseline_tokens: %s\n' "$baseline_tokens"
  if [ -n "$median_tokens" ]; then
    printf 'light_vs_baseline: %s\n' "$(format_ratio "$median_tokens" "$baseline_tokens")"
  else
    printf 'light_vs_baseline: n/a\n'
  fi
  exit 0
}

if [ "$subcommand" = "tally" ]; then
  run_tally
fi

# ---------------------------------------------------------------------------
# append subcommands: gate, then one event line
# ---------------------------------------------------------------------------

[ -n "$root" ] || swallow "--root is required"
command -v jq >/dev/null 2>&1 || swallow "jq is not available, nothing recorded"
main="$(resolve_main_root "$root")" || swallow "main checkout unresolved, nothing recorded"
# Adopter installs carry no maintainer rule file: record nothing, create nothing.
[ -f "$main/$MAINTAINER_RULE_RELATIVE_PATH" ] || exit 0

log="$main/$LOG_RELATIVE_PATH"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
branch_slug=""
if command -v gaia_branch_slug >/dev/null 2>&1; then
  branch_slug="$(gaia_branch_slug "$root" 2>/dev/null)" || branch_slug=""
fi

# append_event <json-line>: one O_APPEND write of one complete line, so a
# failure leaves nothing half-written.
append_event() {
  local line="$1"
  [ -n "$line" ] || return 0
  mkdir -p "$(dirname "$log")" 2>/dev/null || {
    printf 'audit-light-telemetry: cannot create the telemetry directory\n' >&2
    return 0
  }
  { printf '%s\n' "$line" >>"$log"; } 2>/dev/null || {
    printf 'audit-light-telemetry: cannot append to the telemetry log\n' >&2
    return 0
  }
  return 0
}

# log_events_json: the log as one JSON array, malformed lines dropped.
log_events_json() {
  if [ -f "$log" ]; then
    jq -R -c 'fromjson? // empty' "$log" 2>/dev/null | jq -s -c '.' 2>/dev/null || printf '[]'
  else
    printf '[]'
  fi
}

case "$subcommand" in
  route)
    [ -n "$record_path" ] && [ -f "$record_path" ] || swallow "route record unreadable"
    line="$(jq -c --arg branch "$branch_slug" --arg at "$timestamp" '
      {event: "route",
       branch: (if $branch == "" then null else $branch end),
       at: $at,
       member: .member,
       digest: .digest,
       tree: .tree,
       route: .route,
       reason: .reason,
       lines: .lines,
       files: ((.files // []) | length),
       hard_full_rule: .hard_full_rule,
       cap: .cap,
       anchor_sha: .anchor_sha,
       ranges: [(.files // [])[] | {path: .path, post_ranges: (.post_ranges // [])}]}' \
      "$record_path" 2>/dev/null)" || line=""
    [ -n "$line" ] || swallow "route record unparseable"
    append_event "$line"
    ;;

  outcome)
    [ -n "$member" ] && [ -n "$digest" ] && [ -n "$tree" ] || swallow "--member, --digest and --tree are required"
    case "$verdict" in
      clear | escalate | failed) ;;
      *) swallow "--verdict must be clear, escalate or failed" ;;
    esac
    tokens_value="null"
    duration_value="null"
    is_non_negative_integer "$tokens" && tokens_value="$tokens"
    is_non_negative_integer "$duration_milliseconds" && duration_value="$duration_milliseconds"
    route_record="null"
    if is_plain_token "$member" && is_plain_token "$digest"; then
      route_record_path="$root/.gaia/local/audit/light/$digest.$member.route.json"
      if [ -f "$route_record_path" ]; then
        route_record="$(jq -c '{route: .route, reason: .reason, lines: .lines, files: ((.files // []) | length)}' \
          "$route_record_path" 2>/dev/null)" || route_record="null"
        [ -n "$route_record" ] || route_record="null"
      fi
    fi
    line="$(jq -n -c --arg branch "$branch_slug" --arg at "$timestamp" \
      --arg member "$member" --arg digest "$digest" --arg tree "$tree" --arg verdict "$verdict" \
      --argjson tokens "$tokens_value" --argjson duration "$duration_value" \
      --argjson record "$route_record" '
      {event: "light_outcome",
       branch: (if $branch == "" then null else $branch end),
       at: $at, member: $member, digest: $digest, tree: $tree,
       route: ($record.route // null),
       reason: ($record.reason // null),
       lines: ($record.lines // null),
       files: ($record.files // null),
       verdict: $verdict, tokens: $tokens, duration_ms: $duration}' 2>/dev/null)" || line=""
    append_event "$line"
    ;;

  member-result)
    [ -n "$member" ] || swallow "--member is required"
    is_plain_token "$member" || swallow "--member is not a plain name"
    clearance_library="$repo_directory/.claude/hooks/lib/audit-clearance.sh"
    [ -f "$clearance_library" ] || swallow "clearance library unavailable"
    # shellcheck source=/dev/null
    . "$clearance_library"
    member_digest="$(bash "$self_directory/audit-member-digest.sh" --root "$root" --member "$member" 2>/dev/null)" || member_digest=""
    [ -n "$member_digest" ] || swallow "member digest underivable"
    head_tree="$(git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null)" || head_tree=""

    # A refusal outranks an earned marker, matching the merge gate's precedence.
    result="pending"
    if clearance_member_refused "$root" "$member_digest" "$member"; then
      result="refused"
    elif clearance_member_cleared "$root" "$member_digest" "$member"; then
      result="cleared"
    fi

    # The newest full-round sidecar for this branch. The light sidecar is named
    # <key>.<member>.light.findings.json and so never matches this glob.
    newest_sidecar=""
    if [ -n "$branch_slug" ]; then
      for sidecar in "$root"/.gaia/local/audit/*."$branch_slug"."$member".findings.json; do
        [ -f "$sidecar" ] || continue
        if [ -z "$newest_sidecar" ] || [ "$sidecar" -nt "$newest_sidecar" ]; then
          newest_sidecar="$sidecar"
        fi
      done
    fi
    findings_count=0
    locations='[]'
    if [ -n "$newest_sidecar" ]; then
      locations="$(jq -c '[(.findings // [])[] | {path: .path, line: .line}]' "$newest_sidecar" 2>/dev/null)" || locations='[]'
      [ -n "$locations" ] || locations='[]'
      findings_count="$(printf '%s' "$locations" | jq -r 'length' 2>/dev/null)" || findings_count=0
    fi

    line="$(jq -n -c --arg branch "$branch_slug" --arg at "$timestamp" \
      --arg member "$member" --arg digest "$member_digest" --arg tree "$head_tree" \
      --arg result "$result" --argjson findings "$findings_count" --argjson locations "$locations" '
      {event: "member_result",
       branch: (if $branch == "" then null else $branch end),
       at: $at, member: $member, digest: $digest, tree: $tree,
       result: $result, findings: $findings, locations: $locations}' 2>/dev/null)" || line=""

    # A full member running right after its own light escalation or failure is
    # the evidence for escalation precision; find that light route first, from
    # the log as it stood before this append.
    followup_line=""
    if [ -n "$head_tree" ]; then
      route_digest="$(log_events_json | jq -r --arg member "$member" --arg branch "$branch_slug" --arg tree "$head_tree" '
        ([.[] | select(.event == "route" and .member == $member and (.branch // "") == $branch and .tree == $tree)] | last) as $route
        | if $route == null or $route.route != "light" then empty
          else
            ([.[] | select(.event == "light_outcome" and .member == $member and (.branch // "") == $branch and .digest == $route.digest)] | last) as $outcome
            | if $outcome != null and ($outcome.verdict == "escalate" or $outcome.verdict == "failed") then $route.digest else empty end
          end' 2>/dev/null)" || route_digest=""
      if [ -n "$route_digest" ]; then
        followup_line="$(jq -n -c --arg branch "$branch_slug" --arg at "$timestamp" \
          --arg member "$member" --arg route_digest "$route_digest" \
          --arg result "$result" --argjson findings "$findings_count" '
          {event: "escalation_followup",
           branch: (if $branch == "" then null else $branch end),
           at: $at, member: $member, route_digest: $route_digest,
           result: $result, findings: $findings}' 2>/dev/null)" || followup_line=""
      fi
    fi
    append_event "$line"
    append_event "$followup_line"
    ;;
esac

exit 0
