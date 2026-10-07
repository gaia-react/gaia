#!/usr/bin/env bash
# Renders a SPEC's e2e-routed UATs into red Playwright specs. The generated
# plan orchestrator runs it at its UAT render step, from the resolved isolation
# root, with the absolute SPEC path and the plan README that holds the UAT
# routing table; the step's procedure is
# .claude/skills/gaia/references/spec/uat-write.md.
#
#   uat-write.sh <spec-path> --routing <routing-file> [--overwrite <repo-relative-path>]...
#
# Exit codes the caller branches on:
#   0  success, no conflict; stdout is the JSON summary
#   1  operational failure; stdout is {"ok":false,"error":"..."}; nothing written
#   2  invalid input (usage, malformed SPEC, invalid routing table, a
#      working-document id in an e2e-routed UAT); stderr only; nothing written
#   3  conflict: every other action applied, the JSON summary printed, every
#      conflict file left byte-identical. --overwrite names the conflict paths a
#      human chose to replace on the next run.
#
# Render ledger: uat-render.json beside the routing file lists the paths this
# renderer owns, so a later run can find the spec of a removed or re-routed UAT
# without globbing (a glob would reach hand-written neighbours). Only a file
# whose first line is the contract marker is ever rewritten or deleted.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
usage: uat-write.sh <spec-path> --routing <routing-file> [--overwrite <repo-relative-path>]...
EOF
}

usage_failure() {
  printf 'uat-write.sh: %s\n' "$1" >&2
  usage
  exit 2
}

fail_operation() {
  local message_escaped
  message_escaped=$(printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"ok":false,"error":"%s"}\n' "$message_escaped"
  exit 1
}

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/uat-lib.sh
source "$script_directory/uat-lib.sh"
template_path="$script_directory/../../templates/spec/uat-spec.ts.tmpl"
repo_root="$PWD"

spec_path=''
routing_path=''
overwrite_paths=''
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
    --overwrite)
      [ "$#" -ge 2 ] || usage_failure '--overwrite needs a repo-relative path'
      overwrite_paths="$overwrite_paths$2"$'\n'
      shift 2
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
[ -f "$spec_path" ] || usage_failure "spec file not found: $spec_path"
[ -f "$routing_path" ] || usage_failure "routing file not found: $routing_path"

# --- Validate every input before anything is written ---
spec_rows=$(uat_lib_parse_spec "$spec_path") || exit 2
uat_lib_validate_routing "$spec_path" "$routing_path" || exit 2
routing_rows=$(uat_lib_parse_routing "$routing_path") || exit 2

e2e_rows=''
id_refusals=0
refuse_working_document_id() {
  if grep -qiE '(SPEC|UAT|PLAN)-[0-9]+' <<<"$3"; then
    printf 'uat-write.sh: %s %s carries a working-document id, which a rendered spec may not hold. Next step: reopen the SPEC and describe the behavior without the id.\n' "$1" "$2" >&2
    id_refusals=$((id_refusals + 1))
  fi
}
while IFS=$'\t' read -r uat_id surface _ feature_folder file_name; do
  [ "$surface" = "e2e" ] || continue
  spec_row=$(awk -F'\t' -v wanted="$uat_id" '$1 == wanted { print; exit }' <<<"$spec_rows")
  IFS=$'\t' read -r _ given_text when_text then_text <<<"$spec_row"
  refuse_working_document_id "$uat_id" given "$given_text"
  refuse_working_document_id "$uat_id" when "$when_text"
  refuse_working_document_id "$uat_id" 'then' "$then_text"
  e2e_rows="$e2e_rows$uat_id"$'\t'"$feature_folder/$file_name"$'\t'"$given_text"$'\t'"$when_text"$'\t'"$then_text"$'\n'
done <<<"$routing_rows"
[ "$id_refusals" -eq 0 ] || exit 2

if ! e2e_directory=$(uat_lib_e2e_directory "$repo_root" 2>&1); then
  fail_operation "$e2e_directory"
fi
if [ ! -f "$template_path" ]; then
  fail_operation "template missing: $template_path. Next step: restore it from the GAIA release."
fi
if [ "$(head -n 1 "$template_path")" != "\${CONTRACT_MARKER}" ]; then
  fail_operation "template's first line is not the contract marker placeholder: $template_path"
fi
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  fail_operation 'no sha256 tool available (need shasum or sha256sum)'
fi
if ! command -v jq >/dev/null 2>&1; then
  fail_operation 'jq is not on PATH. Next step: install jq and retry.'
fi

ledger_path="$(dirname "$routing_path")/uat-render.json"
ledger_rows=''
if [ -f "$ledger_path" ]; then
  if ! ledger_rows=$(jq -r '.rendered[] | [.uat_id, .path] | @tsv' "$ledger_path" 2>/dev/null); then
    fail_operation "render ledger is malformed: $ledger_path. Next step: delete it and re-run; a spec of a removed UAT is then left for a human to delete."
  fi
fi

staging_directory=$(mktemp -d)
trap 'rm -rf "$staging_directory"' EXIT

# A JS string literal for the then-clause, in the exact form the frontend's
# eslint --fix (prettier plus the quote and String.raw rules) leaves alone, so a
# render is a formatter fixed point and its body hash survives the quality
# gate. A clause with a backslash, and nothing that stops String.raw from
# carrying it verbatim, is String.raw; any other clause takes the quote prettier
# prefers (single, unless it holds more single than double quotes), escaping
# only backslashes and that quote.
javascript_literal() {
  UAT_TEXT="$1" LC_ALL=C awk 'BEGIN {
    text = ENVIRON["UAT_TEXT"]
    text_length = length(text)
    if (index(text, "\\") > 0 && index(text, "`") == 0 && index(text, "${") == 0 && substr(text, text_length, 1) != "\\") {
      printf "String.raw`%s`", text
      exit
    }
    singles = 0
    doubles = 0
    for (position = 1; position <= text_length; position++) {
      character = substr(text, position, 1)
      if (character == "\047") singles++
      else if (character == "\"") doubles++
    }
    quote = singles > doubles ? "\"" : "\047"
    escaped = ""
    for (position = 1; position <= text_length; position++) {
      character = substr(text, position, 1)
      if (character == "\\" || character == quote) escaped = escaped "\\"
      escaped = escaped character
    }
    printf "%s%s%s", quote, escaped, quote
  }'
}

# Placeholders are spliced in one left-to-right pass, so text a value carries
# (even a literal placeholder name) is never substituted a second time.
render_spec_file() {
  local output_file="$4" body_file="$4.body" digest
  UAT_GIVEN="$1" UAT_WHEN="$2" UAT_THEN="$3" UAT_THEN_JS="$(javascript_literal "$3")" \
    LC_ALL=C awk 'NR > 1 {
      line = $0
      result = ""
      while ((start = index(line, "${")) > 0) {
        rest = substr(line, start + 2)
        finish = index(rest, "}")
        name = finish > 0 ? substr(rest, 1, finish - 1) : ""
        if (name == "UAT_GIVEN" || name == "UAT_WHEN" || name == "UAT_THEN" || name == "UAT_THEN_JS") {
          result = result substr(line, 1, start - 1) ENVIRON[name]
          line = substr(rest, finish + 1)
        } else {
          result = result substr(line, 1, start + 1)
          line = rest
        }
      }
      print result line
    }' "$template_path" >"$body_file"
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 <"$body_file" | awk '{ print $1 }')
  else
    digest=$(sha256sum <"$body_file" | awk '{ print $1 }')
  fi
  {
    printf '// gaia-uat-contract sha256:%s\n' "$digest"
    cat "$body_file"
  } >"$output_file"
  rm -f "$body_file"
}

is_overwrite_requested() {
  grep -qxF -- "$1" <<<"$overwrite_paths"
}

# --- Decide one action per target ---
# details rows: path, uat_id, action, reason. ledger_next rows: uat_id, path.
details=''
conflict_count=0
ledger_next=''
claimed_paths=''
staged_count=0
writes=''
deletions=''

add_detail() {
  [ "$3" != "conflict" ] || conflict_count=$((conflict_count + 1))
  details="$details$1"$'\t'"$2"$'\t'"$3"$'\t'"${4:-}"$'\n'
}

while IFS=$'\t' read -r uat_id relative_path given_text when_text then_text; do
  [ -n "$uat_id" ] || continue
  relative_path="$e2e_directory/$relative_path"
  absolute_path="$repo_root/$relative_path"
  claimed_paths="$claimed_paths$relative_path"$'\n'
  ledger_next="$ledger_next$uat_id"$'\t'"$relative_path"$'\n'
  staged_count=$((staged_count + 1))
  staged_file="$staging_directory/$staged_count.spec.ts"
  render_spec_file "$given_text" "$when_text" "$then_text" "$staged_file"

  if [ ! -e "$absolute_path" ] && [ ! -L "$absolute_path" ]; then
    action=written
    reason=''
  elif [ ! -f "$absolute_path" ]; then
    action=conflict
    reason=unmarked-file-at-target
  else
    embedded_digest=$(uat_lib_embedded_hash "$absolute_path")
    if [ -z "$embedded_digest" ]; then
      action=conflict
      reason=unmarked-file-at-target
    else
      current_digest=$(uat_lib_body_hash "$absolute_path") || fail_operation 'no sha256 tool available (need shasum or sha256sum)'
      current_contract=$(uat_lib_contract "$absolute_path") || current_contract=''
      expected_contract="$given_text"$'\t'"$when_text"$'\t'"$then_text"
      reason=''
      if [ "$current_contract" = "$expected_contract" ]; then
        if [ "$embedded_digest" = "$current_digest" ]; then action=unchanged; else action=preserved; fi
      elif [ "$embedded_digest" = "$current_digest" ]; then
        action=rewritten
      else
        action=conflict
        reason=changed-and-edited
      fi
    fi
    if [ "$action" = "conflict" ] && [ -f "$absolute_path" ] && is_overwrite_requested "$relative_path"; then
      action=rewritten
      reason=''
    fi
  fi
  case "$action" in
    written | rewritten) writes="$writes$staged_file"$'\t'"$relative_path"$'\n' ;;
  esac
  add_detail "$relative_path" "$uat_id" "$action" "$reason"
done <<<"$e2e_rows"

while IFS=$'\t' read -r uat_id relative_path; do
  [ -n "$relative_path" ] || continue
  case "$relative_path" in
    "$e2e_directory"/*.spec.ts) ;;
    *) continue ;;
  esac
  case "/$relative_path/" in
    */../* | */./* | *//*) continue ;;
  esac
  grep -qxF -- "$relative_path" <<<"$claimed_paths" && continue
  claimed_paths="$claimed_paths$relative_path"$'\n'
  absolute_path="$repo_root/$relative_path"
  [ -f "$absolute_path" ] || continue
  embedded_digest=$(uat_lib_embedded_hash "$absolute_path")
  [ -n "$embedded_digest" ] || continue
  current_digest=$(uat_lib_body_hash "$absolute_path") || fail_operation 'no sha256 tool available (need shasum or sha256sum)'
  if [ "$embedded_digest" = "$current_digest" ] || is_overwrite_requested "$relative_path"; then
    deletions="$deletions$relative_path"$'\n'
    add_detail "$relative_path" "$uat_id" deleted
  else
    ledger_next="$ledger_next$uat_id"$'\t'"$relative_path"$'\n'
    add_detail "$relative_path" "$uat_id" conflict removed-or-rerouted-and-edited
  fi
done <<<"$ledger_rows"

# --- Apply ---
while IFS=$'\t' read -r staged_file relative_path; do
  [ -n "$relative_path" ] || continue
  absolute_path="$repo_root/$relative_path"
  target_directory=$(dirname "$absolute_path")
  mkdir -p "$target_directory" || fail_operation "cannot create $target_directory"
  temporary_file=$(mktemp "$target_directory/.uat-write.XXXXXX") || fail_operation "cannot write in $target_directory"
  if ! cp "$staged_file" "$temporary_file" || ! mv -f "$temporary_file" "$absolute_path"; then
    rm -f "$temporary_file"
    fail_operation "cannot write $relative_path"
  fi
done <<<"$writes"

while IFS= read -r relative_path; do
  [ -n "$relative_path" ] || continue
  absolute_path="$repo_root/$relative_path"
  rm -f "$absolute_path" || fail_operation "cannot delete $relative_path"
  target_directory=$(dirname "$absolute_path")
  if [ "$target_directory" != "$repo_root/$e2e_directory" ]; then
    rmdir "$target_directory" 2>/dev/null || true
  fi
done <<<"$deletions"

ledger_json=$(printf '%s' "$ledger_next" | LC_ALL=C sort -t $'\t' -k2,2 | jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t") | {uat_id: .[0], path: .[1]}) | {rendered: .}
')
ledger_temporary=$(mktemp "$(dirname "$ledger_path")/.uat-render.XXXXXX") || fail_operation "cannot write the render ledger beside $routing_path"
printf '%s\n' "$ledger_json" >"$ledger_temporary"
mv -f "$ledger_temporary" "$ledger_path" || fail_operation "cannot write the render ledger $ledger_path"

summary_json=$(printf '%s' "$details" | LC_ALL=C sort -t $'\t' -k1,1 | jq -R -s -c --arg directory "$e2e_directory" '
  split("\n")
  | map(select(length > 0) | split("\t")
      | {uat_id: .[1], path: .[0], action: .[2]}
        + (if (.[3] // "") != "" then {reason: .[3]} else {} end))
  | . as $details
  | def count(action): $details | map(select(.action == action)) | length;
  {
    ok: true,
    e2e_directory: $directory,
    summary: {
      written: count("written"),
      rewritten: count("rewritten"),
      unchanged: count("unchanged"),
      preserved: count("preserved"),
      deleted: count("deleted"),
      conflict: count("conflict")
    },
    details: $details
  }
')
printf '%s\n' "$summary_json"

[ "$conflict_count" -eq 0 ] || exit 3
exit 0
