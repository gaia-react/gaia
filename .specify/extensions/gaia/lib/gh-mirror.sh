#!/usr/bin/env bash
# gh-mirror.sh — Optionally mirror a saved SPEC to a GitHub Issue.
#
# Usage:
#   gh-mirror.sh <repo_root> <spec_id> <spec_path_relative_to_repo_root>
#
# Mirrors the SPEC body to a GitHub Issue ONLY when ALL THREE conditions hold:
#   1. `gh auth status` exits 0 (authenticated).
#   2. `gh api repos/{owner}/{repo} --jq .has_issues` is true.
#   3. The viewer has admin or write permission on the repo.
#
# On any conditional failure: log to <repo_root>/.gaia/local/telemetry/gh-mirror.jsonl
# and exit 0. Absence does not block save.
#
# On success: `gh issue create --title "<spec-id>: <intent first line>"
# --body-file <spec_path>`, then write the issue URL into the SPEC frontmatter
# under a new `gh_issue_url` field, and emit a success telemetry record.
set -uo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: gh-mirror.sh <repo_root> <spec_id> <spec_path_relative>" >&2
  exit 0
fi

repo_root="$1"
spec_id="$2"
spec_path_rel="$3"

log_telemetry() {
  # $1=event, $2=status, $3=detail
  local event="$1" status="$2" detail="$3"
  local telemetry_dir="$repo_root/.gaia/local/telemetry"
  local telemetry_file="$telemetry_dir/gh-mirror.jsonl"
  mkdir -p "$telemetry_dir" 2>/dev/null || return 0
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # Escape detail for JSON (double-quote and backslash only).
  local d_esc
  d_esc="${detail//\\/\\\\}"
  d_esc="${d_esc//\"/\\\"}"
  printf '{"ts":"%s","event":"%s","status":"%s","detail":"%s","spec_id":"%s"}\n' \
    "$ts" "$event" "$status" "$d_esc" "$spec_id" \
    >> "$telemetry_file" 2>/dev/null || true
}

skip() {
  log_telemetry "$1" "skipped" "$2"
  exit 0
}

if [ ! -d "$repo_root" ]; then
  echo "gh-mirror.sh: repo_root is not a directory: $repo_root" >&2
  exit 0
fi

spec_path="$repo_root/$spec_path_rel"
if [ ! -f "$spec_path" ]; then
  skip "spec_not_found" "spec_path does not resolve to a file: $spec_path_rel"
fi

# --- Condition 1: gh availability + auth ---
if ! command -v gh > /dev/null 2>&1; then
  skip "no_gh" "gh CLI not installed"
fi

if ! gh auth status > /dev/null 2>&1; then
  skip "gh_auth_failed" "gh auth status exited non-zero"
fi

repo_slug="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
if [ -z "$repo_slug" ]; then
  skip "no_repo_slug" "gh could not resolve owner/repo for repo_root"
fi

# --- Condition 2: Issues enabled ---
has_issues="$(gh api "repos/$repo_slug" --jq .has_issues 2>/dev/null || true)"
if [ "$has_issues" != "true" ]; then
  skip "issues_disabled" "repo $repo_slug has has_issues=$has_issues"
fi

# --- Condition 3: viewer permission >= write ---
viewer_login="$(gh api user --jq .login 2>/dev/null || true)"
if [ -z "$viewer_login" ]; then
  skip "no_viewer" "gh api user --jq .login returned empty"
fi

permission="$(gh api "repos/$repo_slug/collaborators/$viewer_login/permission" --jq .permission 2>/dev/null || true)"
case "$permission" in
  admin | write) : ;;
  *) skip "no_write_permission" "viewer=$viewer_login permission=$permission on $repo_slug" ;;
esac

# --- All three conditions passed — build title and create the issue ---
intent_first_line="$(awk '
  /^intent:[[:space:]]*\|/ { in_intent = 1; next }
  in_intent {
    if (/^[A-Za-z_][A-Za-z0-9_]*:/ || /^---[[:space:]]*$/) { exit }
    line = $0
    sub(/^[[:space:]]+/, "", line)
    if (line != "") { print line; exit }
  }
' "$spec_path")"

if [ -z "$intent_first_line" ]; then
  intent_first_line="(no intent captured)"
fi

title_text="$spec_id: $intent_first_line"
if [ "${#title_text}" -gt 200 ]; then
  title_text="${title_text:0:197}..."
fi

issue_url="$(gh issue create --title "$title_text" --body-file "$spec_path" 2>/dev/null || true)"
if [ -z "$issue_url" ]; then
  skip "issue_create_failed" "gh issue create returned empty url"
fi

# --- Stamp gh_issue_url into the SPEC frontmatter (idempotent) ---
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

log_telemetry "mirrored" "mirrored" "$issue_url"
exit 0
