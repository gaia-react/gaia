#!/usr/bin/env bash
# lint.sh - Pure-function immutability lint helper for SPEC artifacts.
#
# Usage:
#   lint.sh <spec_file>                # lint a SPEC artifact; prints findings JSON to stdout
#
# Exit codes:
#   0  - lint pass (stdout: {"ok": true, "findings": []})
#   1  - lint fail (stdout: {"ok": false, "findings": [...]})
#   2  - usage / IO error (stderr: message)
#
# Findings JSON shape (one element per issue):
#   { "code": "<symbolic>", "message": "<human>", "where": "<field/line>" }
#
# Pure: reads the file under audit only. No writes. No side effects.
#
# Checks performed:
#   - frontmatter present (--- ... ---)
#   - required frontmatter fields: spec_id, type, status, immutable, wiki_promote_default,
#     chain_trigger, intent, success_criteria, uats, scope_boundaries, clarifications,
#     research_summary, created, updated
#   - immutable: true
#   - status in {in-progress, reopened, closed}
#   - spec_id matches SPEC-NNN
#   - every UAT has a frozen uat_id matching UAT-NNN
#   - no placeholder text ([PLACEHOLDER], <TODO>, TBD, FIXME, <TBD>)
#   - reopen ceremony: when status == reopened, body must contain a UAT diff capture
#     and a rationale block (markers: "## Reopen rationale" and "## UAT diff" or
#     equivalent fenced sentinels)
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: lint.sh <spec_file>" >&2
  exit 2
fi

spec_file="$1"

if [ ! -f "$spec_file" ]; then
  echo "lint.sh: file not found: $spec_file" >&2
  exit 2
fi

# Collect findings as JSON-encoded strings; emit array at end.
findings=()

add_finding() {
  local code="$1"
  local message="$2"
  local where="${3:-}"
  # Escape double quotes and backslashes for JSON safety.
  local m_esc
  local w_esc
  m_esc=$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')
  w_esc=$(printf '%s' "$where" | sed 's/\\/\\\\/g; s/"/\\"/g')
  findings+=("{\"code\":\"$code\",\"message\":\"$m_esc\",\"where\":\"$w_esc\"}")
}

# --- Extract frontmatter block (between first two --- lines) ---
fm=""
body=""
state="pre"
fm_end_line=0
line_no=0
while IFS= read -r line; do
  line_no=$((line_no + 1))
  case "$state" in
    pre)
      if [ "$line" = "---" ]; then
        state="in_fm"
      else
        # Content before frontmatter is allowed only if it's empty; treat as missing FM.
        if [ -n "$line" ]; then
          state="no_fm"
          body+="$line"$'\n'
        fi
      fi
      ;;
    in_fm)
      if [ "$line" = "---" ]; then
        state="post"
        fm_end_line=$line_no
      else
        fm+="$line"$'\n'
      fi
      ;;
    post)
      body+="$line"$'\n'
      ;;
    no_fm)
      body+="$line"$'\n'
      ;;
  esac
done < "$spec_file"

if [ "$state" != "post" ]; then
  add_finding "no_frontmatter" "SPEC has no closed YAML frontmatter (--- ... ---)." "head"
fi

# --- Frontmatter field extraction (top-level keys only) ---
get_fm_field() {
  local key="$1"
  # Match top-level key (no leading whitespace), capture value on same line.
  printf '%s' "$fm" | awk -v k="$key" '
    BEGIN { found = 0 }
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
      # New top-level key; emit prior buffer if it matched k.
      if (found) { exit }
      split($0, parts, ":")
      curkey = parts[1]
      # Reconstruct value from the rest of the line.
      val = substr($0, length(curkey) + 2)
      sub(/^ /, "", val)
      if (curkey == k) {
        found = 1
        print val
      }
      next
    }
    found == 1 && /^[A-Za-z_][A-Za-z0-9_]*:/ { exit }
  '
}

# Whether a top-level key exists (even if value is block-scalar / list).
has_fm_key() {
  local key="$1"
  printf '%s' "$fm" | grep -qE "^${key}:" && return 0 || return 1
}

required_keys=(
  spec_id
  type
  status
  immutable
  wiki_promote_default
  chain_trigger
  intent
  success_criteria
  uats
  scope_boundaries
  clarifications
  research_summary
  created
  updated
)

for k in "${required_keys[@]}"; do
  if ! has_fm_key "$k"; then
    add_finding "missing_field" "Required frontmatter field missing: $k" "frontmatter.$k"
  fi
done

# --- Field-value checks ---
spec_id_val="$(get_fm_field spec_id || true)"
status_val="$(get_fm_field status || true)"
immutable_val="$(get_fm_field immutable || true)"

# spec_id must match SPEC-NNN (one or more digits, expecting zero-padded triple).
if [ -n "$spec_id_val" ]; then
  if ! [[ "$spec_id_val" =~ ^SPEC-[0-9]+$ ]]; then
    add_finding "bad_spec_id" "spec_id must match SPEC-NNN; got '$spec_id_val'" "frontmatter.spec_id"
  fi
fi

# status must be one of the enum.
case "$status_val" in
  in-progress|reopened|closed) ;;
  "") ;; # already reported as missing above
  *) add_finding "bad_status" "status must be one of in-progress|reopened|closed; got '$status_val'" "frontmatter.status" ;;
esac

# immutable must be true.
if [ -n "$immutable_val" ] && [ "$immutable_val" != "true" ]; then
  add_finding "not_immutable" "immutable must be true; got '$immutable_val'" "frontmatter.immutable"
fi

# --- UAT id check: every entry under uats: must have uat_id: UAT-NNN ---
# Extract the uats: block (lines from "uats:" up to next top-level key).
uats_block=$(printf '%s' "$fm" | awk '
  /^uats:/ { capture = 1; next }
  capture && /^[A-Za-z_][A-Za-z0-9_]*:/ { capture = 0 }
  capture { print }
')

if [ -n "$uats_block" ]; then
  # Count list entries (lines starting with "  - ") and uat_id occurrences.
  # uat_id can appear either inline on the dash line ("  - uat_id: UAT-001")
  # or on a continuation line ("    uat_id: UAT-001"). Match both.
  entry_count=$(printf '%s\n' "$uats_block" | grep -cE '^[[:space:]]*-[[:space:]]' || true)
  uat_id_count=$(printf '%s\n' "$uats_block" | grep -cE '^[[:space:]]*(-[[:space:]]+)?uat_id:[[:space:]]+UAT-[0-9]+' || true)
  if [ "$entry_count" -gt 0 ] && [ "$uat_id_count" -lt "$entry_count" ]; then
    add_finding "missing_uat_id" "Some UAT entries lack uat_id: UAT-NNN ($uat_id_count of $entry_count have ids)" "frontmatter.uats"
  fi
  # Detect malformed ids (uat_id present but not UAT-NNN shape).
  bad_ids=$(printf '%s\n' "$uats_block" | grep -E '^[[:space:]]*(-[[:space:]]+)?uat_id:' | grep -vE '^[[:space:]]*(-[[:space:]]+)?uat_id:[[:space:]]+UAT-[0-9]+[[:space:]]*$' || true)
  if [ -n "$bad_ids" ]; then
    add_finding "bad_uat_id" "UAT id(s) do not match UAT-NNN frozen format" "frontmatter.uats"
  fi
fi

# --- Placeholder text scan over the whole file ---
# Patterns: [PLACEHOLDER], <TODO>, <TBD>, FIXME, bare TBD as standalone token.
ph_patterns=(
  '\[PLACEHOLDER\]'
  '<TODO>'
  '<TBD>'
  'FIXME'
)
for pat in "${ph_patterns[@]}"; do
  if grep -nE "$pat" "$spec_file" > /dev/null; then
    # Capture first occurrence line for the finding.
    first_hit=$(grep -nE "$pat" "$spec_file" | head -n 1 | cut -d: -f1)
    add_finding "placeholder" "Placeholder text matching '$pat' detected" "line:$first_hit"
  fi
done
# Bare TBD as a standalone word (not part of <TBD>, already handled).
if grep -nE '(^|[^A-Za-z<])TBD([^A-Za-z>]|$)' "$spec_file" > /dev/null; then
  first_hit=$(grep -nE '(^|[^A-Za-z<])TBD([^A-Za-z>]|$)' "$spec_file" | head -n 1 | cut -d: -f1)
  add_finding "placeholder" "Placeholder token 'TBD' detected" "line:$first_hit"
fi

# --- Reopen ceremony check ---
# When status == reopened, body must include a rationale block AND a UAT diff capture.
if [ "$status_val" = "reopened" ]; then
  # Look for case-insensitive markers in the body.
  rationale_ok=0
  diff_ok=0
  if printf '%s' "$body" | grep -qiE '^##[[:space:]]+Reopen[[:space:]]+rationale'; then
    rationale_ok=1
  fi
  if printf '%s' "$body" | grep -qiE '^##[[:space:]]+UAT[[:space:]]+diff'; then
    diff_ok=1
  fi
  if [ "$rationale_ok" -eq 0 ]; then
    add_finding "reopen_missing_rationale" "Reopened SPEC must include a '## Reopen rationale' section before any UAT mutation." "body"
  fi
  if [ "$diff_ok" -eq 0 ]; then
    add_finding "reopen_missing_diff" "Reopened SPEC must include a '## UAT diff' section capturing the pre-mutation UAT state." "body"
  fi
fi

# --- Emit result ---
if [ "${#findings[@]}" -eq 0 ]; then
  printf '{"ok":true,"findings":[]}\n'
  exit 0
fi

# Join findings with commas.
joined=""
for f in "${findings[@]}"; do
  if [ -z "$joined" ]; then
    joined="$f"
  else
    joined="$joined,$f"
  fi
done
printf '{"ok":false,"findings":[%s]}\n' "$joined"
exit 1
