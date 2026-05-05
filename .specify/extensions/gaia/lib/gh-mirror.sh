#!/usr/bin/env bash
# gh-mirror.sh - Optionally mirror a saved SPEC to a GitHub Issue.
#
# Reads JSON payload on stdin (or $SPECKIT_HOOK_PAYLOAD). Mirrors the SPEC body
# to a GitHub Issue ONLY when ALL THREE conditions hold:
#   1. `gh auth status` exits 0 (authenticated).
#   2. `gh api repos/{owner}/{repo} --jq .has_issues` is true (Issues enabled).
#   3. The viewer has admin or write permission on the repo.
#
# On any conditional failure: log to .gaia/local/telemetry/gh-mirror.jsonl with
# the failed condition and exit 0. Absence does not block save.
#
# On success: `gh issue create --title "<spec-id>: <intent first line>"
# --body-file <spec_path>`, then write the issue URL into the SPEC frontmatter
# under a new `gh_issue_url` field, and emit a success telemetry record.
#
# UAT: UAT-012.
set -uo pipefail

# Always-on telemetry helper. Writes one JSONL line per invocation outcome.
log_telemetry() {
  # $1=event, $2=status (skipped|mirrored|error), $3=reason or url, $4=spec_id, $5=cwd
  local event="$1" status="$2" detail="$3" spec_id="$4" telemetry_cwd="$5"
  local telemetry_dir="$telemetry_cwd/.gaia/local/telemetry"
  local telemetry_file="$telemetry_dir/gh-mirror.jsonl"
  mkdir -p "$telemetry_dir" 2> /dev/null || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if command -v jq > /dev/null 2>&1; then
    jq -nc \
      --arg ts "$ts" \
      --arg event "$event" \
      --arg status "$status" \
      --arg detail "$detail" \
      --arg spec_id "$spec_id" \
      '{ts:$ts, event:$event, status:$status, detail:$detail, spec_id:$spec_id}' \
      >> "$telemetry_file" 2> /dev/null || true
  else
    printf '{"ts":"%s","event":"%s","status":"%s","detail":"%s","spec_id":"%s"}\n' \
      "$ts" "$event" "$status" "$detail" "$spec_id" \
      >> "$telemetry_file" 2> /dev/null || true
  fi
}

# Conditional-failure exit: log + exit 0 (never propagate to lifecycle).
skip() {
  local condition="$1" detail="$2"
  log_telemetry "$condition" "skipped" "$detail" "${spec_id:-}" "${cwd:-.}"
  exit 0
}

# --- jq availability (treated as a condition failure - skip rather than block) ---
if ! command -v jq > /dev/null 2>&1; then
  # No jq means we cannot parse the payload; record what we can to a fallback
  # path under cwd derived from the script location, then exit 0.
  fallback_cwd="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." 2> /dev/null && pwd || echo ".")"
  log_telemetry "no_jq" "skipped" "jq not installed; mirror skipped" "" "$fallback_cwd"
  exit 0
fi

# --- Read payload ---
payload=""
if [ -n "${SPECKIT_HOOK_PAYLOAD:-}" ]; then
  payload="$SPECKIT_HOOK_PAYLOAD"
elif [ ! -t 0 ]; then
  payload="$(cat)"
fi

if [ -z "$payload" ] || ! printf '%s' "$payload" | jq -e . > /dev/null 2>&1; then
  # Cannot parse payload -> skip (telemetry uses fallback cwd).
  fallback_cwd="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." 2> /dev/null && pwd || echo ".")"
  log_telemetry "bad_payload" "skipped" "payload missing or not valid JSON" "" "$fallback_cwd"
  exit 0
fi

cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
spec_id="$(printf '%s' "$payload" | jq -r '.spec_id // ""')"
spec_path_rel="$(printf '%s' "$payload" | jq -r '.spec_path // ""')"

if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  fallback_cwd="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." 2> /dev/null && pwd || echo ".")"
  log_telemetry "bad_cwd" "skipped" "payload.cwd missing or not a directory" "$spec_id" "$fallback_cwd"
  exit 0
fi

if [ -z "$spec_path_rel" ] || [ "$spec_path_rel" = "null" ]; then
  skip "no_spec_path" "payload.spec_path missing"
fi

spec_path="$cwd/$spec_path_rel"
if [ ! -f "$spec_path" ]; then
  skip "spec_not_found" "spec_path does not resolve to a file: $spec_path_rel"
fi

# --- Condition 1: gh auth ---
if ! command -v gh > /dev/null 2>&1; then
  skip "no_gh" "gh CLI not installed"
fi

if ! gh auth status > /dev/null 2>&1; then
  skip "gh_auth_failed" "gh auth status exited non-zero"
fi

# --- Resolve owner/repo for current working directory's git remote ---
repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2> /dev/null || true)"
if [ -z "$repo_slug" ]; then
  skip "no_repo_slug" "gh could not resolve owner/repo for cwd"
fi

# --- Condition 2: Issues enabled ---
has_issues="$(gh api "repos/$repo_slug" --jq .has_issues 2> /dev/null || true)"
if [ "$has_issues" != "true" ]; then
  skip "issues_disabled" "repo $repo_slug has has_issues=$has_issues"
fi

# --- Condition 3: viewer permission >= write ---
viewer_login="$(gh api user --jq .login 2> /dev/null || true)"
if [ -z "$viewer_login" ]; then
  skip "no_viewer" "gh api user --jq .login returned empty"
fi

permission="$(gh api "repos/$repo_slug/collaborators/$viewer_login/permission" --jq .permission 2> /dev/null || true)"
case "$permission" in
  admin | write)
    : # ok
    ;;
  *)
    skip "no_write_permission" "viewer=$viewer_login permission=$permission on $repo_slug"
    ;;
esac

# --- All three conditions passed - build title and create the issue ---
# Title = "<spec-id>: <intent first line>". Pull the intent first non-blank line
# from the SPEC frontmatter (a literal block under `intent: |`).
intent_first_line="$(awk '
  /^intent:[[:space:]]*\|/ { in_intent = 1; next }
  in_intent {
    # End of intent block when we hit a top-level YAML key (column-1 letter
    # followed by a colon) or the closing frontmatter marker.
    if (/^[A-Za-z_][A-Za-z0-9_]*:/ || /^---[[:space:]]*$/) { exit }
    line = $0
    sub(/^[[:space:]]+/, "", line)
    if (line != "") { print line; exit }
  }
' "$spec_path")"

if [ -z "$intent_first_line" ]; then
  intent_first_line="(no intent captured)"
fi

# Truncate the title at a sensible length; GitHub allows 256 chars but shorter
# reads better.
title_text="${spec_id:-SPEC}: $intent_first_line"
if [ "${#title_text}" -gt 200 ]; then
  title_text="${title_text:0:197}..."
fi

issue_url="$(gh issue create --title "$title_text" --body-file "$spec_path" 2> /dev/null || true)"
if [ -z "$issue_url" ]; then
  skip "issue_create_failed" "gh issue create returned empty url"
fi

# --- Stamp gh_issue_url into the SPEC frontmatter ---
# Insert the field just before the closing `---` of the frontmatter, replacing
# any existing gh_issue_url line in place to keep the stamp idempotent.
tmp_spec="$(mktemp)"
awk -v url="$issue_url" '
  BEGIN { in_fm = 0; fm_closed = 0; stamped = 0 }
  /^---[[:space:]]*$/ {
    if (in_fm == 0 && fm_closed == 0) {
      in_fm = 1
      print
      next
    }
    if (in_fm == 1) {
      if (stamped == 0) {
        print "gh_issue_url: " url
        stamped = 1
      }
      in_fm = 0
      fm_closed = 1
      print
      next
    }
  }
  in_fm == 1 && /^gh_issue_url:[[:space:]]/ {
    if (stamped == 0) {
      print "gh_issue_url: " url
      stamped = 1
    }
    next
  }
  { print }
' "$spec_path" > "$tmp_spec" && mv "$tmp_spec" "$spec_path"

log_telemetry "mirrored" "mirrored" "$issue_url" "$spec_id" "$cwd"
exit 0
