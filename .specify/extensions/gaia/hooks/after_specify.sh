#!/usr/bin/env bash
# after_specify.sh - Immutability lint + write-surface audit.
#
# Reads JSON payload from stdin (or $SPECKIT_HOOK_PAYLOAD env var).
#
# Returns:
#   {"action": "proceed"}                                       on lint pass
#   {"action": "block", "reason": "<lint findings or audit>"}   on lint or audit fail
#
# UATs: UAT-008 (immutability lint), UAT-011 (reopen ceremony enforcement),
# UAT-015 backstop (write-surface audit).
set -euo pipefail

# --- jq availability ---
if ! command -v jq > /dev/null 2>&1; then
  printf '{"action":"block","reason":"after_specify.sh requires jq; install jq and retry."}\n'
  exit 0
fi

# --- Read payload ---
payload=""
if [ -n "${SPECKIT_HOOK_PAYLOAD:-}" ]; then
  payload="$SPECKIT_HOOK_PAYLOAD"
elif [ ! -t 0 ]; then
  payload="$(cat)"
fi

if [ -z "$payload" ]; then
  printf '{"action":"block","reason":"after_specify.sh: empty payload (expected JSON on stdin or $SPECKIT_HOOK_PAYLOAD)."}\n'
  exit 0
fi

if ! printf '%s' "$payload" | jq -e . > /dev/null 2>&1; then
  printf '{"action":"block","reason":"after_specify.sh: payload is not valid JSON."}\n'
  exit 0
fi

cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
draft_path="$(printf '%s' "$payload" | jq -r '.draft_path // ""')"
spec_path="$(printf '%s' "$payload" | jq -r '.spec_path // ""')"

if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  printf '{"action":"block","reason":"after_specify.sh: payload.cwd is missing or not a directory."}\n'
  exit 0
fi

# Pick the artifact under audit. Prefer draft_path; fall back to spec_path.
audit_target=""
if [ -n "$draft_path" ] && [ "$draft_path" != "null" ]; then
  audit_target="$cwd/$draft_path"
elif [ -n "$spec_path" ] && [ "$spec_path" != "null" ]; then
  audit_target="$cwd/$spec_path"
fi

if [ -z "$audit_target" ] || [ ! -f "$audit_target" ]; then
  jq -n --arg p "${draft_path:-${spec_path:-<none>}}" \
    '{action:"block", reason:("after_specify.sh: draft/spec path missing or not found: " + $p)}'
  exit 0
fi

# --- Step 2: Immutability lint via lib/lint.sh ---
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
lint="$script_dir/../lib/lint.sh"

if [ ! -x "$lint" ]; then
  printf '{"action":"block","reason":"after_specify.sh: lib/lint.sh is not executable or missing."}\n'
  exit 0
fi

# Run lint; capture stdout (JSON) and exit status. lint.sh exits 0 on pass, 1 on fail.
set +e
lint_out="$("$lint" "$audit_target" 2>/dev/null)"
lint_rc=$?
set -e

if [ -z "$lint_out" ]; then
  printf '{"action":"block","reason":"after_specify.sh: lint produced no output."}\n'
  exit 0
fi

if [ "$lint_rc" -ne 0 ]; then
  # Build a human-readable reason from findings.
  reason="$(printf '%s' "$lint_out" | jq -r '
    if .findings | length == 0 then
      "Lint failed (no findings reported)."
    else
      "Lint failed: " + ([.findings[] | (.code + " — " + .message + (if .where != "" then " (" + .where + ")" else "" end))] | join("; "))
    end
  ')"
  jq -n --arg r "$reason" '{action:"block", reason:$r}'
  exit 0
fi

# --- Step 3: Write-surface audit (UAT-015 backstop) ---
# Compare files modified since session start against the allowlist:
#   .gaia/local/specs/**
#   .specify/**
#   .gaia/local/cache/**
#   .gaia/local/telemetry/**
cache_dir="$cwd/.gaia/local/cache"
active_pointer="$cache_dir/active-session"

session_started=""
if [ -f "$active_pointer" ]; then
  session_file="$(cat "$active_pointer" 2>/dev/null || true)"
  if [ -n "$session_file" ] && [ -f "$session_file" ]; then
    session_started="$(jq -r '.started_at // ""' "$session_file" 2>/dev/null || true)"
  fi
fi

# If we have no session marker, skip the audit but record a soft note in the lint
# pass result. The backstop is opportunistic; the primary defense is the wrapper.
if [ -n "$session_started" ]; then
  # Convert the ISO-ish UTC stamp (YYYYMMDDTHHMMSSZ) to a `find -newer` reference
  # by recreating an empty file with that mtime. Use Python or touch -t for portability.
  ref_file="$(mktemp)"
  trap 'rm -f "$ref_file"' EXIT

  # Parse YYYYMMDDTHHMMSSZ to YYYYMMDDhhmm.ss (touch -t format, UTC).
  if [[ "$session_started" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]]; then
    yyyy="${BASH_REMATCH[1]}"
    mm="${BASH_REMATCH[2]}"
    dd="${BASH_REMATCH[3]}"
    hh="${BASH_REMATCH[4]}"
    mi="${BASH_REMATCH[5]}"
    ss="${BASH_REMATCH[6]}"
    # macOS and GNU touch both accept [[CC]YY]MMDDhhmm[.SS].
    if ! touch -t "${yyyy}${mm}${dd}${hh}${mi}.${ss}" "$ref_file" 2>/dev/null; then
      # Fallback: skip audit if touch -t syntax is unsupported.
      ref_file=""
    fi
  else
    ref_file=""
  fi

  if [ -n "$ref_file" ] && [ -f "$ref_file" ]; then
    # Find files newer than the reference under cwd, excluding noise.
    violations=()
    while IFS= read -r -d '' f; do
      # Make repo-relative.
      rel="${f#$cwd/}"
      # Skip the reference file itself if it landed in cwd (it won't; mktemp is /tmp).
      [ "$f" = "$ref_file" ] && continue
      # Skip directories we never care about.
      case "$rel" in
        .git/*|node_modules/*|.DS_Store|*.swp) continue ;;
      esac
      # Allowlist check.
      case "$rel" in
        .gaia/local/specs/*|.specify/*|.gaia/local/cache/*|.gaia/local/telemetry/*) ;;
        *)
          violations+=("$rel")
          ;;
      esac
    done < <(find "$cwd" -type f -newer "$ref_file" -not -path '*/.git/*' -not -path '*/node_modules/*' -print0 2>/dev/null)

    if [ "${#violations[@]}" -gt 0 ]; then
      # Cap reported violations to keep the message readable.
      cap=10
      sample=("${violations[@]:0:$cap}")
      n="${#violations[@]}"
      list="$(printf '%s; ' "${sample[@]}")"
      list="${list%; }"
      extra=""
      if [ "$n" -gt "$cap" ]; then
        extra=" (and $((n - cap)) more)"
      fi
      reason="Write-surface audit failed: files modified outside the wrapper allowlist (.gaia/local/specs/**, .specify/**, .gaia/local/cache/**, .gaia/local/telemetry/**): $list$extra"
      jq -n --arg r "$reason" '{action:"block", reason:$r}'
      exit 0
    fi
  fi
fi

# --- Step 4: proceed ---
printf '{"action":"proceed"}\n'
exit 0
