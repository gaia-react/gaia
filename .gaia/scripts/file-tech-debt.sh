#!/usr/bin/env bash
#
# The one door every tech-debt filing passes through (the file-tech-debt
# skill, .claude/skills/file-tech-debt/SKILL.md, tells every caller to run it).
# It screens a finding for security class FIRST, probes the issue backend,
# re-reads repository visibility immediately before any write, and then either
# files (dedup, labels, metadata check, create, verify-after-file) or writes a
# redacted local record and reports only a count. No security-class finding's
# detail reaches a public or internal GitHub surface from any caller.
#
# Usage:
#   file-tech-debt.sh probe  --repo <owner/name>
#   file-tech-debt.sh screen --finding <json-file>
#   file-tech-debt.sh screen-text --text-file <path>
#   file-tech-debt.sh file   --finding <json-file> --outcome-file <path>
#                            [--repo <owner/name>] [--disposition file|divert]
#
# probe: stdout `present` (exit 0), `absent` (10) or `transient` (11), usage 2.
#   absent is a definitive answer (repo unresolvable, gh unauthenticated,
#   Issues disabled, viewer lacks write permission); transient is a timeout,
#   rate limit, 5xx or any answer that cannot be classified.
# screen: stdout `clear` (exit 0) or `security <trigger>` (exit 1). Triggers:
#   flag-true, flag-absent, flag-non-boolean, severity-error,
#   issue-severity-critical, secret-shaped, class-absent, class-malformed.
#   `holistic/unclassified` is a valid class and never a trigger. The class
#   check is a shape check; membership in the closed vocabulary is the
#   CLI's finding-class schema's job.
# screen-text: exit 1 with `security secret-shaped` when the text holds a
#   secret-shaped token (ghp_/gho_/ghs_/github_pat_ tokens, AKIA access keys, a
#   PEM private-key header), 0 with `clear` otherwise.
# file: appends exactly one JSON line to --outcome-file:
#   {"key":{"member","finding_class","path","line"},"disposition":"file|divert",
#    "outcome":"filed|diverted|absent|transient|failed","issue":<int|null>,
#    "record":"<path|null>"}
#   and prints one stdout line: `filed <n>`, `diverted <count> <record-path>`,
#   `absent`, `transient` or `failed <reason>`. Exit 0 for filed, diverted,
#   absent and transient; 1 for failed; 2 usage; 3 unreadable input or a
#   missing tool (jq, a sha256 tool).
#   The outcome line keeps the key fields so the caller can reconcile it with
#   its dispositions; it never carries a title, failure mode, fix or trigger.
#   The outcome file lives under .gaia/local on the one machine.
#
# Order for file: screen, then (security-class only) a first visibility read,
# probe, dedup, a second visibility read as the last gh call before the first
# write, label creation, create, verify-after-file. A security-class finding
# files only when BOTH reads answer exactly PRIVATE and the backend is present;
# every other path diverts, running no gh write verb (issue create/edit, label
# create, api POST/PATCH/PUT). A divert writes
# <root>/.gaia/local/audit/security/<sha256 of the wrapped key>.md and nothing
# else leaves the machine. Visibility counts as PRIVATE only when
# `gh repo view <repo> --json visibility` answers exactly `PRIVATE`; an error,
# empty answer, PUBLIC or INTERNAL is not PRIVATE. No environment variable
# overrides it.
#
# Transient retention: a non-security finding whose outcome is `transient` is
# copied byte for byte to <dirname of --outcome-file>/filing-retry/<sha256 of
# the wrapped key>.json. A later run for the same key that ends filed, absent
# or failed removes it; another transient leaves it. Security-class findings
# never reach that directory.
#
# Dedup choices. The lists are fetched here, with --repo, and handed to
# debt-dedup.sh through its test seams, which owns the matching rules. An open
# match (keyed or keyless) is not filed again and is recorded as outcome
# `filed` with the matched issue's number. A declined-closed match follows the
# skill's idempotency step the same way: no second filing, outcome `filed` with
# the matched number. A list that cannot be fetched is transient (non-security)
# or a divert (security-class); a list that fills its limit is `failed`.
#
# Honest limits. An issue filed while the repository is PRIVATE becomes public
# if visibility later flips. A caller that mislabels `security` as false
# defeats the screen's flag test, which is why the content and severity
# triggers exist beside it. Labels are created with plain `gh label create`
# when missing; `gaia labels sync` (colors) is the operator's job.
#
# Every gh call carries --repo. Without --repo it is resolved once from
# `gh repo view --json nameWithOwner` run in the working root.

set -u

program_name="file-tech-debt"
open_limit=1000
closed_limit=5000

die_usage() {
  printf '%s: %s\n' "$program_name" "$1" >&2
  exit 2
}

die_input() {
  printf '%s: %s\n' "$program_name" "$1" >&2
  exit 3
}

command -v jq >/dev/null 2>&1 || die_input "jq is not installed; refusing to continue (never a silent pass)"

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || die_input "cannot resolve the script directory"

work_directory=""
# shellcheck disable=SC2329
cleanup() {
  [ -n "$work_directory" ] && rm -rf "$work_directory"
  return 0
}
trap cleanup EXIT

make_work_directory() {
  work_directory="$(mktemp -d "${TMPDIR:-/tmp}/file-tech-debt.XXXXXX")" || die_input "cannot create a scratch directory"
}

sha256_of_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    die_input "neither shasum nor sha256sum is installed"
  fi
}

# Secret-shaped content, the pattern set the dispositions check shares through
# the screen-text subcommand. Fail-safe direction: a false hit diverts.
secret_pattern='(ghp|gho|ghs)_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

text_has_secret() {
  grep -Eq -e "$secret_pattern"
}

# finding_text <json-file>: every string value in the finding, one per line.
finding_text() {
  jq -r '[.. | strings] | join("\n")' "$1" 2>/dev/null
}

# class_is_well_formed <class>: the shape convention of the class vocabulary.
class_is_well_formed() {
  case "$1" in
    holistic/unclassified) return 0 ;;
  esac
  printf '%s' "$1" | grep -Eq '^(holistic|rule|workflow)/[a-z0-9][a-z0-9-]*$' && return 0
  [ "${#1}" -le 140 ] || return 1
  printf '%s' "$1" | grep -Eq '^(react-doctor|axe|knip|cve)/[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9][A-Za-z0-9_.-]*)*$'
}

# screen_trigger <json-file>: prints the trigger, or nothing when clear.
screen_trigger() {
  local screened_file="$1" flag_trigger class_state class_value
  flag_trigger="$(jq -r '
    if (has("security") | not) or .security == null then "flag-absent"
    elif (.security | type) != "boolean" then "flag-non-boolean"
    elif .security then "flag-true"
    elif .severity == "error" then "severity-error"
    elif .issue_severity == "Critical" then "issue-severity-critical"
    else empty end' "$screened_file")" || return 3
  if [ -n "$flag_trigger" ]; then
    printf '%s\n' "$flag_trigger"
    return 0
  fi
  if finding_text "$screened_file" | text_has_secret; then
    printf 'secret-shaped\n'
    return 0
  fi
  class_state="$(jq -r '
    if (has("finding_class") | not) or .finding_class == null or .finding_class == "" then "absent"
    elif (.finding_class | type) != "string" then "malformed"
    else "ok" end' "$screened_file")" || return 3
  case "$class_state" in
    absent) printf 'class-absent\n' ;;
    malformed) printf 'class-malformed\n' ;;
    *)
      class_value="$(jq -r '.finding_class' "$screened_file")" || return 3
      class_is_well_formed "$class_value" || printf 'class-malformed\n'
      ;;
  esac
  return 0
}

# --- gh plumbing --------------------------------------------------------------

gh_output=""
gh_error=""
gh_status=0

# run_gh <args...>: runs gh once, capturing stdout, stderr and the status.
run_gh() {
  gh_output="$(gh "$@" 2>"$work_directory/gh-error")"
  gh_status=$?
  gh_error="$(cat "$work_directory/gh-error" 2>/dev/null)"
  return 0
}

# classify_gh_failure: absent for a definitive no (auth, missing repo, Issues
# disabled), transient for anything else, including rate limits and 5xx.
classify_gh_failure() {
  local lowered
  lowered="$(printf '%s' "$gh_error" | tr '[:upper:]' '[:lower:]')"
  case "$lowered" in
    *"rate limit"* | *"timeout"* | *"timed out"* | *"http 5"* | *"http 429"* | *"abuse"* | *"temporarily"*)
      printf 'transient\n'
      return 0
      ;;
    *"gh auth login"* | *"gh_token"* | *"not logged"* | *"authentication"* | *"http 401"* | *"http 404"* | *"could not resolve to a repository"* | *"none of the git remotes"* | *"not a git repository"* | *"has disabled issues"* | *"issues are disabled"*)
      printf 'absent\n'
      return 0
      ;;
  esac
  printf 'transient\n'
}

# probe_backend <repo>: prints present, absent or transient.
probe_backend() {
  local probed_repo="$1" issues_enabled permission
  run_gh repo view "$probed_repo" --json hasIssuesEnabled,viewerPermission
  if [ "$gh_status" -ne 0 ]; then
    classify_gh_failure
    return 0
  fi
  issues_enabled="$(printf '%s' "$gh_output" | jq -r '.hasIssuesEnabled | if type == "boolean" then tostring else "unknown" end' 2>/dev/null)"
  permission="$(printf '%s' "$gh_output" | jq -r '.viewerPermission | if type == "string" then . else "unknown" end' 2>/dev/null)"
  case "$issues_enabled" in
    false)
      printf 'absent\n'
      return 0
      ;;
    true) ;;
    *)
      printf 'transient\n'
      return 0
      ;;
  esac
  case "$permission" in
    WRITE | MAINTAIN | ADMIN) ;;
    READ | TRIAGE | NONE)
      printf 'absent\n'
      return 0
      ;;
    *)
      printf 'transient\n'
      return 0
      ;;
  esac
  run_gh issue list --repo "$probed_repo" --limit 1 --json number
  if [ "$gh_status" -ne 0 ]; then
    classify_gh_failure
    return 0
  fi
  printf 'present\n'
}

# repo_is_private <repo>: true only on an exact PRIVATE answer.
repo_is_private() {
  run_gh repo view "$1" --json visibility --jq .visibility
  [ "$gh_status" -eq 0 ] && [ "$gh_output" = PRIVATE ]
}

# --- subcommands --------------------------------------------------------------

cmd_probe() {
  local probe_repo=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --repo)
        [ "$#" -ge 2 ] || die_usage "--repo needs a value"
        probe_repo="$2"
        shift 2
        ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$probe_repo" ] || die_usage "probe needs --repo"
  make_work_directory
  local probe_answer
  probe_answer="$(probe_backend "$probe_repo")"
  printf '%s\n' "$probe_answer"
  case "$probe_answer" in
    present) exit 0 ;;
    absent) exit 10 ;;
    *) exit 11 ;;
  esac
}

cmd_screen() {
  local finding_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --finding)
        [ "$#" -ge 2 ] || die_usage "--finding needs a value"
        finding_file="$2"
        shift 2
        ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$finding_file" ] || die_usage "screen needs --finding"
  jq -e 'type == "object"' "$finding_file" >/dev/null 2>&1 || die_input "cannot read $finding_file as a JSON object"
  local trigger
  trigger="$(screen_trigger "$finding_file")" || die_input "cannot screen $finding_file"
  if [ -n "$trigger" ]; then
    printf 'security %s\n' "$trigger"
    exit 1
  fi
  printf 'clear\n'
  exit 0
}

cmd_screen_text() {
  local text_file=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --text-file)
        [ "$#" -ge 2 ] || die_usage "--text-file needs a value"
        text_file="$2"
        shift 2
        ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$text_file" ] || die_usage "screen-text needs --text-file"
  [ -r "$text_file" ] || die_input "cannot read $text_file"
  if text_has_secret <"$text_file"; then
    printf 'security secret-shaped\n'
    exit 1
  fi
  printf 'clear\n'
  exit 0
}

# --- file ---------------------------------------------------------------------

finding_file=""
outcome_file=""
repo=""
disposition="file"
root=""
member=""
finding_class_text=""
finding_path=""
finding_line=""
wrapped_key=""
key_hash=""
retry_file=""
security_trigger=""

# append_outcome <outcome> <issue-or-null> <record-or-empty>
append_outcome() {
  local outcome_issue="$2" outcome_record="$3"
  mkdir -p "$(dirname "$outcome_file")" 2>/dev/null || die_input "cannot create the outcome directory"
  jq -n -c --arg member "$member" --arg finding_class "$finding_class_text" --arg path "$finding_path" \
    --argjson line "$finding_line" --arg disposition "$disposition" --arg outcome "$1" \
    --argjson issue "$outcome_issue" --arg record "$outcome_record" \
    '{key: {member: $member, finding_class: (if $finding_class == "" then null else $finding_class end), path: $path, line: $line},
      disposition: $disposition, outcome: $outcome, issue: $issue,
      record: (if $record == "" then null else $record end)}' >>"$outcome_file" \
    || die_input "cannot append to $outcome_file"
}

drop_retry_file() {
  [ -n "$retry_file" ] && rm -f "$retry_file"
  return 0
}

finish_filed() {
  append_outcome filed "$1" ""
  drop_retry_file
  printf 'filed %s\n' "$1"
  exit 0
}

finish_failed() {
  append_outcome failed null ""
  drop_retry_file
  printf 'failed %s\n' "$1"
  exit 1
}

finish_absent() {
  append_outcome absent null ""
  drop_retry_file
  printf 'absent\n'
  exit 0
}

finish_transient() {
  append_outcome transient null ""
  if [ -z "$security_trigger" ] && [ "$disposition" = file ]; then
    mkdir -p "$(dirname "$retry_file")" 2>/dev/null && { [ "$finding_file" -ef "$retry_file" ] || cp "$finding_file" "$retry_file"; }
  fi
  printf 'transient\n'
  exit 0
}

# finish_diverted <trigger>: writes the redacted local record, then reports the
# count and the record path only.
finish_diverted() {
  local record_directory record_path
  record_directory="$root/.gaia/local/audit/security"
  record_path="$record_directory/$key_hash.md"
  if ! (umask 077 && mkdir -p "$record_directory" && {
    printf '# Diverted security-class finding\n\n'
    printf 'Time: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Repo: %s\n' "${repo:-unknown}"
    printf 'Member: %s\n' "$member"
    printf 'Location: %s:%s\n' "$finding_path" "$finding_line"
    printf 'Trigger: %s\n\n' "$1"
    printf 'Title: %s\n\n' "$(jq -r '.title // ""' "$finding_file")"
    printf 'Failure mode: %s\n\n' "$(jq -r '.failure_mode // ""' "$finding_file")"
    printf 'Suggested fix: %s\n' "$(jq -r '.suggested_fix // ""' "$finding_file")"
  } >"$record_path") 2>/dev/null; then
    append_outcome failed null ""
    printf 'failed record-write\n'
    exit 1
  fi
  append_outcome diverted null "$record_path"
  printf 'diverted 1 %s\n' "$record_path"
  exit 0
}

# fetch_lists: the open and closed tech-debt lists into the work directory.
# Sets list_status: 0 ok, 1 gh could not answer.
fetch_lists() {
  run_gh issue list --repo "$repo" --label tech-debt --state open --limit "$open_limit" --json number,body
  [ "$gh_status" -eq 0 ] || return 1
  printf '%s\n' "$gh_output" >"$work_directory/open.json"
  run_gh issue list --repo "$repo" --label tech-debt --state closed --limit "$closed_limit" --json number,body,labels,stateReason
  [ "$gh_status" -eq 0 ] || return 1
  printf '%s\n' "$gh_output" >"$work_directory/closed.json"
  return 0
}

severity_label() {
  jq -r '
    if (.issue_severity // "") != "" then
      ({"Critical": "critical", "Important": "important", "Suggestion": "suggestion"}[.issue_severity] // empty)
    else
      ({"error": "critical", "warning": "important", "suggestion": "suggestion"}[.severity // ""] // empty)
    end' "$1"
}

cmd_file() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --finding | --outcome-file | --repo | --disposition)
        [ "$#" -ge 2 ] || die_usage "$1 needs a value"
        case "$1" in
          --finding) finding_file="$2" ;;
          --outcome-file) outcome_file="$2" ;;
          --repo) repo="$2" ;;
          --disposition) disposition="$2" ;;
        esac
        shift 2
        ;;
      *) die_usage "unknown argument $1" ;;
    esac
  done
  [ -n "$finding_file" ] || die_usage "file needs --finding"
  [ -n "$outcome_file" ] || die_usage "file needs --outcome-file"
  case "$disposition" in
    file | divert) ;;
    *) die_usage "--disposition must be file or divert" ;;
  esac
  jq -e 'type == "object"' "$finding_file" >/dev/null 2>&1 || die_input "cannot read $finding_file as a JSON object"
  jq -e '(.path | type == "string" and . != "") and (.line | type == "number" and . == floor and . >= 0)' "$finding_file" >/dev/null 2>&1 \
    || die_input "$finding_file needs a non-empty string path and an integer line"

  make_work_directory
  member="$(jq -r '.member // ""' "$finding_file")"
  finding_path="$(jq -r '.path' "$finding_file")"
  finding_line="$(jq -r '.line | floor | tostring' "$finding_file")"
  finding_class_text="$(jq -r 'if (.finding_class | type) == "string" then .finding_class else "" end' "$finding_file")"
  security_trigger="$(screen_trigger "$finding_file")" || die_input "cannot screen $finding_file"

  local key_class="$finding_class_text"
  class_is_well_formed "$key_class" || key_class="holistic/unclassified"
  wrapped_key="<!-- gaia-debt-key: v1 class=$key_class path=$finding_path line=$finding_line -->"
  key_hash="$(sha256_of_text "$wrapped_key")" || exit 3
  retry_file="$(dirname "$outcome_file")/filing-retry/$key_hash.json"

  root="$(bash "$script_directory/main-root-lib.sh")" || die_input "cannot resolve the working root"

  local sensitive=0
  if [ -n "$security_trigger" ] || [ "$disposition" = divert ]; then
    sensitive=1
    [ -n "$security_trigger" ] || security_trigger="caller-divert"
  fi

  [ "$disposition" = divert ] && finish_diverted "$security_trigger"

  if [ -z "$repo" ]; then
    gh_output="$(cd "$root" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>"$work_directory/gh-error")"
    gh_status=$?
    gh_error="$(cat "$work_directory/gh-error" 2>/dev/null)"
    if [ "$gh_status" -eq 0 ] && [ -n "$gh_output" ]; then
      repo="$gh_output"
    elif [ "$sensitive" -eq 1 ]; then
      finish_diverted "$security_trigger"
    elif [ "$gh_status" -eq 0 ]; then
      finish_transient
    else
      case "$(classify_gh_failure)" in
        absent) finish_absent ;;
        *) finish_transient ;;
      esac
    fi
  fi

  if [ "$sensitive" -eq 1 ]; then
    repo_is_private "$repo" || finish_diverted "$security_trigger"
  fi

  local probe_answer
  probe_answer="$(probe_backend "$repo")"
  case "$probe_answer" in
    present) ;;
    absent)
      [ "$sensitive" -eq 1 ] && finish_diverted "$security_trigger"
      finish_absent
      ;;
    *)
      [ "$sensitive" -eq 1 ] && finish_diverted "$security_trigger"
      finish_transient
      ;;
  esac

  local title failure_mode suggested_fix tier grade footprint audience=""
  title="$(jq -r '.title // ""' "$finding_file")"
  failure_mode="$(jq -r '.failure_mode // ""' "$finding_file")"
  suggested_fix="$(jq -r '.suggested_fix // ""' "$finding_file")"
  tier="$(severity_label "$finding_file")"
  grade="$(jq -r '.grade // ""' "$finding_file")"
  footprint="$(jq -r '.footprint // ""' "$finding_file")"
  # gaia:maintainer-only:start
  audience="$(jq -r '.audience // ""' "$finding_file")"
  # gaia:maintainer-only:end

  if ! fetch_lists; then
    [ "$sensitive" -eq 1 ] && finish_diverted "$security_trigger"
    finish_transient
  fi
  local dedup_json dedup_status matched_number
  dedup_json="$(bash "$script_directory/debt-dedup.sh" --path "$finding_path" --line "$finding_line" \
    --open-json "$work_directory/open.json" --closed-json "$work_directory/closed.json" 2>"$work_directory/dedup-error")"
  dedup_status=$?
  case "$dedup_status" in
    0) ;;
    1)
      matched_number="$(printf '%s' "$dedup_json" | jq -r '.number')"
      finish_filed "$matched_number"
      ;;
    *)
      [ "$sensitive" -eq 1 ] && finish_diverted "$security_trigger"
      finish_failed "dedup-unavailable"
      ;;
  esac

  [ -n "$title" ] || finish_failed "missing-title"
  [ -n "$failure_mode" ] || finish_failed "missing-failure-mode"
  [ -n "$suggested_fix" ] || finish_failed "missing-suggested-fix"
  [ -n "$tier" ] || finish_failed "missing-severity"

  local body_file="$work_directory/issue-body.md"
  {
    printf '%s\n\n' "$wrapped_key"
    # shellcheck disable=SC2016
    printf '**Location:** `%s:%s`\n\n' "$finding_path" "$finding_line"
    printf '**Failure mode:** %s\n\n' "$failure_mode"
    printf '**Suggested fix:** %s\n' "$suggested_fix"
  } >"$body_file"

  local labels_csv="tech-debt,severity:$tier" label_arguments
  label_arguments=(--label tech-debt --label "severity:$tier")
  if [ -n "$footprint" ]; then
    labels_csv="$labels_csv,footprint:$footprint"
    label_arguments+=(--label "footprint:$footprint")
  fi
  if [ -n "$audience" ]; then
    labels_csv="$labels_csv,audience:$audience"
    label_arguments+=(--label "audience:$audience")
  fi
  if [ -n "$grade" ]; then
    labels_csv="$labels_csv,difficulty:$grade"
    label_arguments+=(--label "difficulty:$grade")
  fi

  local metadata_report
  if ! metadata_report="$(bash "$script_directory/check-debt-issue-metadata.sh" --pre-file --labels "$labels_csv" --body-file "$body_file" 2>&1)"; then
    printf '%s\n' "$metadata_report" >&2
    finish_failed "metadata-check"
  fi

  run_gh label list --repo "$repo" --limit 200 --json name --jq '.[].name'
  [ "$gh_status" -eq 0 ] || { [ "$sensitive" -eq 1 ] && finish_diverted "$security_trigger"; finish_transient; }
  local present_labels="$gh_output"

  # The last gh call before the first write.
  if [ "$sensitive" -eq 1 ]; then
    repo_is_private "$repo" || finish_diverted "$security_trigger"
  fi

  local wanted_label
  while IFS= read -r wanted_label; do
    printf '%s\n' "$present_labels" | grep -qx -e "$wanted_label" || gh label create "$wanted_label" --repo "$repo" >/dev/null 2>&1 || true
  done <<<"$(printf '%s' "$labels_csv" | tr ',' '\n')"

  if ! gh issue create --repo "$repo" --title "$title" ${label_arguments[@]+"${label_arguments[@]}"} --body-file "$body_file" >/dev/null 2>"$work_directory/create-error"; then
    finish_failed "create"
  fi

  if ! fetch_lists; then
    finish_failed "verify-after-file"
  fi
  local verified_number
  verified_number="$(jq -r --arg key "$wrapped_key" '[.[] | select((.body // "") | contains($key)) | .number] | sort | .[0] // empty' "$work_directory/open.json")"
  [ -n "$verified_number" ] || finish_failed "verify-after-file"

  # Best-effort: nudge the statusline debt count to recompute.
  { mkdir -p "$root/.gaia/local/debt" && : >"$root/.gaia/local/debt/refresh-requested"; } 2>/dev/null || true

  finish_filed "$verified_number"
}

[ "$#" -ge 1 ] || die_usage "usage: file-tech-debt.sh probe|screen|screen-text|file ..."
subcommand="$1"
shift
case "$subcommand" in
  probe) cmd_probe "$@" ;;
  screen) cmd_screen "$@" ;;
  screen-text) cmd_screen_text "$@" ;;
  file) cmd_file "$@" ;;
  *) die_usage "unknown subcommand $subcommand" ;;
esac
