#!/usr/bin/env bash
# Compares each rendered e2e spec's Given/When/Then contract comment with the
# SPEC's UAT text, through the plan's routing table. The generated plan
# orchestrator and the owning-phase gate (uat-gate.sh) call it from the resolved
# isolation root; the contract it enforces is
# .claude/skills/gaia/references/spec/uat-divergence.md.
#
#   uat-divergence-check.sh <spec-path> --routing <routing-file> [--phase <N> | --all]
#
# With neither --phase nor --all, every e2e row is checked.
#
# Exit codes the caller branches on:
#   0  every selected spec's contract matches the SPEC
#   1  at least one mismatch; stdout names one `<path> <uat_id> <field>` per
#      problem, field being given, when, then, or file for a missing spec
#   2  invalid input (usage, malformed SPEC, invalid routing table); stderr only
#
# Honest limit: it reads only the three contract comment lines, never the test
# body, so a body edit (selectors, labels, copy) never changes the verdict. Whether
# a body still honors its contract is judged by the pre-merge audit member.
set -uo pipefail

usage() {
  cat <<'USAGE' >&2
usage: uat-divergence-check.sh <spec-path> --routing <routing-file> [--phase <N> | --all]
USAGE
}

usage_failure() {
  printf 'uat-divergence-check.sh: %s\n' "$1" >&2
  usage
  exit 2
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/uat-lib.sh
source "$script_directory/uat-lib.sh"
repo_root="$PWD"

spec_path=''
routing_path=''
selected_phase=''
select_all=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 2
      ;;
    --routing)
      [ "$#" -ge 2 ] || usage_failure '--routing needs a file'
      routing_path="$2"
      shift 2
      ;;
    --phase)
      [ "$#" -ge 2 ] || usage_failure '--phase needs a number'
      selected_phase="$2"
      shift 2
      ;;
    --all)
      select_all=1
      shift
      ;;
    -*)
      usage_failure "unknown option: $1"
      ;;
    *)
      [ -z "$spec_path" ] || usage_failure "unexpected argument: $1"
      spec_path="$1"
      shift
      ;;
  esac
done
[ -n "$spec_path" ] || usage_failure 'no SPEC path given'
[ -n "$routing_path" ] || usage_failure '--routing is required'
if [ -n "$selected_phase" ] && [ "$select_all" -eq 1 ]; then
  usage_failure '--phase and --all are mutually exclusive'
fi
if [ -n "$selected_phase" ] && ! [[ "$selected_phase" =~ ^[1-9][0-9]*$ ]]; then
  usage_failure "--phase needs a positive integer, got '$selected_phase'"
fi

spec_rows=$(uat_lib_parse_spec "$spec_path") || exit 2
uat_lib_validate_routing "$spec_path" "$routing_path" || exit 2
routing_rows=$(uat_lib_parse_routing "$routing_path") || exit 2
e2e_directory=$(uat_lib_e2e_directory "$repo_root") || exit 2

mismatches=0
while IFS=$'\t' read -r uat_id surface phase feature_folder file_name; do
  [ "$surface" = "e2e" ] || continue
  if [ -n "$selected_phase" ] && [ "$phase" != "$selected_phase" ]; then
    continue
  fi
  relative_path="$e2e_directory/$feature_folder/$file_name"
  absolute_path="$repo_root/$relative_path"
  if [ ! -f "$absolute_path" ]; then
    printf '%s %s file\n' "$relative_path" "$uat_id"
    mismatches=$((mismatches + 1))
    continue
  fi
  spec_row=$(awk -F'\t' -v wanted="$uat_id" '$1 == wanted { print; exit }' <<<"$spec_rows")
  if ! file_contract=$(uat_lib_contract "$absolute_path"); then
    for field in given when 'then'; do
      if ! awk -v prefix="// $(printf '%s' "$field" | awk '{ print toupper(substr($0, 1, 1)) substr($0, 2) }'): " 'index($0, prefix) == 1 { found = 1; exit } END { exit !found }' "$absolute_path"; then
        printf '%s %s %s\n' "$relative_path" "$uat_id" "$field"
        mismatches=$((mismatches + 1))
      fi
    done
    continue
  fi
  field_index=1
  for field in given when 'then'; do
    file_field=$(printf '%s' "$file_contract" | cut -f"$field_index")
    spec_field=$(printf '%s' "$spec_row" | cut -f"$((field_index + 1))")
    if [ "$file_field" != "$spec_field" ]; then
      printf '%s %s %s\n' "$relative_path" "$uat_id" "$field"
      mismatches=$((mismatches + 1))
    fi
    field_index=$((field_index + 1))
  done
done <<<"$routing_rows"

[ "$mismatches" -eq 0 ] || exit 1
exit 0
