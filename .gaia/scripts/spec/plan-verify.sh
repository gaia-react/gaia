#!/usr/bin/env bash
# Deterministic part of the /gaia-plan verification step (step 4.5): checks a
# generated plan folder before an orchestrator runs it cold. The decomposition
# audit that follows is skipped for trivial plans and when fan-out is
# unavailable, so the checks that must always run live here.
#
# Usage: plan-verify.sh <plan-dir> [--spec <spec-path>]
#
# Always checked: README.md, ORCHESTRATOR.md, KICKOFF.md and at least one
# task-*.md exist; ORCHESTRATOR.md carries the verbatim step sentinels the plan
# needs, each on a line of its own (leading and trailing whitespace allowed,
# nothing else), in the order the template places them. Without --spec the plan
# is spec-less and only the wiki-promotion and post-merge-close sentinels are
# required.
#
# With --spec (a spec-derived plan) additionally: the UAT routing table in
# README.md validates (delegated to uat_lib_validate_routing); the three UAT
# sentinels are required; every story-routed UAT has a story play-function
# criterion line in some task doc whose text carries the UAT's then-clause.
# A non-e2e row whose then-clause reads like a route, navigation, URL, redirect,
# session or server-state check prints a non-fatal WARN: line (misrouting hint).
#
# Every failure is reported on stderr, one line each, in a single run.
#
# Exit codes: 0 pass; 1 one or more failures; 2 usage error.
#
# Bash 3.2 compatible; BSD and GNU tools.
set -uo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/uat-lib.sh
. "$script_directory/uat-lib.sh"

usage() {
  printf 'usage: plan-verify.sh <plan-dir> [--spec <spec-path>]\n' >&2
  exit 2
}

plan_directory=''
spec_path=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --spec)
      [ "$#" -ge 2 ] || usage
      spec_path="$2"
      shift 2
      ;;
    -*) usage ;;
    *)
      [ -z "$plan_directory" ] || usage
      plan_directory="$1"
      shift
      ;;
  esac
done
[ -n "$plan_directory" ] || usage
if [ ! -d "$plan_directory" ]; then
  printf 'plan-verify: plan folder not found: %s\n' "$plan_directory" >&2
  exit 2
fi
if [ -n "$spec_path" ] && [ ! -f "$spec_path" ]; then
  printf 'plan-verify: SPEC not found: %s\n' "$spec_path" >&2
  exit 2
fi

failures=0
fail() {
  printf 'plan-verify: %s\n' "$1" >&2
  failures=$((failures + 1))
}

readme="$plan_directory/README.md"
orchestrator="$plan_directory/ORCHESTRATOR.md"

[ -f "$readme" ] || fail "README.md is missing from $plan_directory"
[ -f "$orchestrator" ] || fail "ORCHESTRATOR.md is missing from $plan_directory"
[ -f "$plan_directory/KICKOFF.md" ] || fail "KICKOFF.md is missing from $plan_directory"
task_files=()
for candidate in "$plan_directory"/task-*.md; do
  [ -f "$candidate" ] && task_files+=("$candidate")
done
[ "${#task_files[@]}" -gt 0 ] || fail "no task-*.md file exists in $plan_directory"

# Required sentinels in the order the template places them.
sentinels=()
if [ -n "$spec_path" ]; then
  sentinels+=('<!-- gaia:orchestrator-step uat-render -->' '<!-- gaia:orchestrator-step uat-gate -->' '<!-- gaia:orchestrator-step uat-pre-audit -->')
fi
sentinels+=('<!-- gaia:orchestrator-step wiki-promotion -->' '<!-- gaia:orchestrator-step post-merge-close -->')

if [ -f "$orchestrator" ]; then
  # first_lines[i] is the line number of the first line matching sentinels[i], or 0.
  first_lines=()
  for _ in ${sentinels[@]+"${sentinels[@]}"}; do first_lines+=(0); done
  line_number=0
  while IFS= read -r line || [ -n "$line" ]; do
    line_number=$((line_number + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
      '<!-- gaia:orchestrator-step '*) ;;
      *) continue ;;
    esac
    index=0
    while [ "$index" -lt "${#sentinels[@]}" ]; do
      if [ "$line" = "${sentinels[$index]}" ] && [ "${first_lines[$index]}" -eq 0 ]; then
        first_lines[$index]=$line_number
      fi
      index=$((index + 1))
    done
  done <"$orchestrator"

  index=0
  while [ "$index" -lt "${#sentinels[@]}" ]; do
    if [ "${first_lines[$index]}" -eq 0 ]; then
      fail "ORCHESTRATOR.md is missing the sentinel line ${sentinels[$index]}"
    else
      # Out of order: a sentinel the template places later appears above this one.
      later=$((index + 1))
      while [ "$later" -lt "${#sentinels[@]}" ]; do
        if [ "${first_lines[$later]}" -ne 0 ] && [ "${first_lines[$later]}" -lt "${first_lines[$index]}" ]; then
          fail "ORCHESTRATOR.md sentinel ${sentinels[$index]} is out of order: it must come before ${sentinels[$later]}"
          break
        fi
        later=$((later + 1))
      done
    fi
    index=$((index + 1))
  done
fi

if [ -n "$spec_path" ] && [ -f "$readme" ]; then
  routing_problems=''
  routing_status=0
  routing_problems=$(uat_lib_validate_routing "$spec_path" "$readme" 2>&1 >/dev/null) || routing_status=$?
  if [ "$routing_status" -ne 0 ]; then
    if [ -z "$routing_problems" ]; then
      routing_problems="uat-routing: the routing table in $readme did not validate"
    fi
    while IFS= read -r problem_line; do
      [ -n "$problem_line" ] || continue
      fail "$problem_line"
    done <<<"$routing_problems"
  fi

  spec_rows=''
  routing_rows=''
  if spec_rows=$(uat_lib_parse_spec "$spec_path" 2>/dev/null) && routing_rows=$(uat_lib_parse_routing "$readme" 2>/dev/null); then
    while IFS=$'\t' read -r uat_id surface _ _ _; do
      [ -n "$uat_id" ] || continue
      then_clause=$(printf '%s\n' "$spec_rows" | awk -F'\t' -v id="$uat_id" '$1 == id { print $4; exit }')
      [ -n "$then_clause" ] || continue
      case "$surface" in
        story)
          marker="Story play-function criterion ($uat_id)"
          found=0
          for task_file in ${task_files[@]+"${task_files[@]}"}; do
            while IFS= read -r task_line; do
              case "$task_line" in
                *"$marker"*) ;;
                *) continue ;;
              esac
              remainder=$(printf '%s' "${task_line#*"$marker"}" | uat_lib_whitespace_text)
              case "$remainder" in
                *"$then_clause"*)
                  found=1
                  break
                  ;;
              esac
            done <"$task_file"
            [ "$found" -eq 0 ] || break
          done
          if [ "$found" -eq 0 ]; then
            fail "$uat_id is story-routed but no task doc carries its line: - $marker: <then-clause verbatim>"
          fi
          ;;
      esac
      case "$surface" in
        story | non-ui)
          if printf '%s' "$then_clause" | grep -qiE 'route|navigat|redirect|session|server[ -]?(side )?state|(^|[^a-z])urls?([^a-z]|$)'; then
            printf 'WARN: %s is routed %s but its then-clause reads like a route, navigation, URL, redirect, session or server-state check; confirm it is not an e2e UAT\n' "$uat_id" "$surface" >&2
          fi
          ;;
      esac
    done <<<"$routing_rows"
  fi
fi

[ "$failures" -eq 0 ] || exit 1
exit 0
