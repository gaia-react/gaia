#!/bin/bash
# GAIA SessionStart update checker.
#
# Writes .gaia/cache/update-check.json with:
#   - outdatedCount  (actionable updates from `gaia update-deps run`, which
#                     applies the ESLint 9.x cap and the minimumReleaseAge
#                     cooldown, so it never counts updates the skill skips)
#   - gaiaCurrent    (from .gaia/VERSION)
#   - gaiaLatest     (from `gh release list` or curl GitHub API)
#   - gaiaHasUpdate  (semver comparison)
#   - hardenCandidateCount (recurring code-review findings ready to harden)
#   - auditNudge / auditNudgeReason / auditLastAppliedAt / auditMemoryCount /
#                  auditMemoryBaseline (knowledge-audit drift signals)
#   - checkedAt      (Unix epoch seconds)
#
# TTL is 6 hours (21600s). Re-runs within the TTL exit immediately so the
# SessionStart hook can fire this in the background without paying the cost
# on every session.
#
# Partial failures are tolerated; exit 0 even if some fields could not be
# refreshed. Do NOT add `set -e`.

TTL=21600

# Knowledge-audit nudge thresholds. Tunable starting values:
#   - AUDIT_DRIFT_DAYS: days since the last `applied` audit before signal (a) fires.
#   - AUDIT_MEMORY_DELTA: memory entries gained since the last `applied` audit
#                         before signal (a) fires.
#   - AUDIT_HOT_BUDGET / AUDIT_CLAUDEMD_BUDGET: auto-load word budgets for
#     wiki/hot.md and root CLAUDE.md (signal b).
#   - AUDIT_RULE_BUDGET: max lines for any .claude/rules/*.md (signal b).
AUDIT_DRIFT_DAYS=30
AUDIT_MEMORY_DELTA=10
AUDIT_HOT_BUDGET=200
AUDIT_CLAUDEMD_BUDGET=400
AUDIT_RULE_BUDGET=200

# Resolve project root (parent of .gaia/) so the script works regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$GAIA_DIR/.." && pwd)"
CACHE_DIR="$GAIA_DIR/cache"
CACHE_FILE="$CACHE_DIR/update-check.json"
VERSION_FILE="$GAIA_DIR/VERSION"

now=$(date +%s)

# Read previous cache values (used as fallbacks on partial failure).
prev_checked_at=0
prev_outdated_count=0
prev_gaia_current=""
prev_gaia_latest=""
prev_gaia_has_update=false
prev_harden_count=0
prev_audit_last_applied_at=0
prev_audit_memory_count=0
prev_audit_memory_baseline=0
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  prev_checked_at=$(jq -r '.checkedAt // 0' "$CACHE_FILE" 2>/dev/null)
  prev_outdated_count=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_gaia_current=$(jq -r '.gaiaCurrent // ""' "$CACHE_FILE" 2>/dev/null)
  prev_gaia_latest=$(jq -r '.gaiaLatest // ""' "$CACHE_FILE" 2>/dev/null)
  prev_gaia_has_update=$(jq -r '.gaiaHasUpdate // false' "$CACHE_FILE" 2>/dev/null)
  prev_harden_count=$(jq -r '.hardenCandidateCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_last_applied_at=$(jq -r '.auditLastAppliedAt // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_memory_count=$(jq -r '.auditMemoryCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_audit_memory_baseline=$(jq -r '.auditMemoryBaseline // 0' "$CACHE_FILE" 2>/dev/null)
  case "$prev_checked_at" in
    ''|*[!0-9]*) prev_checked_at=0 ;;
  esac
  case "$prev_audit_last_applied_at" in
    ''|*[!0-9]*) prev_audit_last_applied_at=0 ;;
  esac
  case "$prev_audit_memory_count" in
    ''|*[!0-9]*) prev_audit_memory_count=0 ;;
  esac
  case "$prev_audit_memory_baseline" in
    ''|*[!0-9]*) prev_audit_memory_baseline=0 ;;
  esac
fi

# TTL gate.
age=$((now - prev_checked_at))
if [ "$age" -lt "$TTL" ]; then
  exit 0
fi

mkdir -p "$CACHE_DIR" 2>/dev/null

# ---------- outdatedCount ----------
# Count only the updates /update-deps will actually apply. The `update-deps
# run` primitive runs the same Phase 1-3 filtering the skill does; the ESLint
# 9.x cap and the minimumReleaseAge cooldown (pnpm 11 rejects lockfile entries
# younger than the cooldown, so the flow skips them). Counting its emitted plan
# (wave members that are genuine upgrades) keeps the nudge from prodding for
# updates that would be skipped. Falls back to the previous cached count on any
# failure: missing binary, network error, parse error.
outdated_count="$prev_outdated_count"
GAIA_BIN="$GAIA_DIR/cli/gaia"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  updates_tmp="$(mktemp "$CACHE_DIR/.updates.XXXXXX" 2>/dev/null)"
  if [ -n "$updates_tmp" ]; then
    if (cd "$PROJECT_ROOT" && "$GAIA_BIN" update-deps run --emit-updates "$updates_tmp") >/dev/null 2>&1 && [ -s "$updates_tmp" ]; then
      # Prefer the payload's `actionable_count`: it already excludes packages
      # the human snoozed via /update-deps (the gitignored decline ledger) and
      # counts only genuine upgrades. Older payloads without the field fall back
      # to the inline recount, keeping the statusline backward-safe.
      parsed=$(jq '
        if (.actionable_count | type) == "number" then .actionable_count
        else
          ([.wave_a[]?, (.wave_b[]?.packages[]?)]
           | map(select(.current != .latest))
           | length)
        end
      ' "$updates_tmp" 2>/dev/null)
      case "$parsed" in
        ''|*[!0-9]*) ;;
        *) outdated_count="$parsed" ;;
      esac
    fi
    rm -f "$updates_tmp" 2>/dev/null
  fi
fi
case "$outdated_count" in
  ''|*[!0-9]*) outdated_count=0 ;;
esac

# ---------- hardenCandidateCount ----------
# Recurring-finding tally for the policy-memory loop. `harden-tally` reads the
# rolling 90-day merged-PR window via gh, counts distinct PRs per finding_class
# at error/warning severity, drops promoted/suppressed classes, and emits the
# candidate_count plus a gh_ok flag. Runs in this same TTL pass; network is
# non-fatal: on a gh/network failure harden-tally exits 0 emitting
# candidate_count 0 with gh_ok false, so this consumer honors gh_ok and keeps
# the previous cached count rather than resetting the nudge to 0. Falls back to
# the previous cached count on any failure: missing binary, gh/network error
# (gh_ok false), parse error.
harden_count="$prev_harden_count"
if [ -x "$GAIA_BIN" ] && command -v jq >/dev/null 2>&1; then
  tally_json="$(cd "$PROJECT_ROOT" && "$GAIA_BIN" harden-tally 2>/dev/null)"
  if [ -n "$tally_json" ]; then
    parsed=$(printf '%s' "$tally_json" | jq -r '.candidate_count // empty' 2>/dev/null)
    gh_ok=$(printf '%s' "$tally_json" | jq -r '.gh_ok // false' 2>/dev/null)
    if [ "$gh_ok" = "true" ]; then
      case "$parsed" in
        ''|*[!0-9]*) ;;
        *) harden_count="$parsed" ;;
      esac
    fi
  fi
fi
case "$harden_count" in
  ''|*[!0-9]*) harden_count=0 ;;
esac

# ---------- auditNudge ----------
# Three conservative knowledge-audit drift signals, computed here (never on the
# statusline hot path) into one verbatim reason string + the raw counters the
# debounce needs. All local file IO; missing dirs/files fall back to prev/zero,
# never fatal. Priority when several fire: draft-pending > machine drift >
# project drift (keeps the segment to one line).
#
# Last-audit anchor: the newest .gaia/local/audit/KNOWLEDGE-*.md whose frontmatter
# `status:` is `applied` (gitignored, machine-local). Its mtime is "last audit on
# this machine". The newest whose `status:` is `draft` sets the resume signal.
audit_last_applied_at="$prev_audit_last_applied_at"
audit_memory_count="$prev_audit_memory_count"
audit_memory_baseline="$prev_audit_memory_baseline"
audit_nudge=false
audit_nudge_reason=""

# (a) Memory entry count proxy: number of *.md files under the machine-local
# memory dir (same derivation /gaia-audit uses).
MEMORY_DIR="$HOME/.claude/projects/$(echo "$PROJECT_ROOT" | sed 's|/|-|g')/memory"
if [ -d "$MEMORY_DIR" ]; then
  mem_count=$(find "$MEMORY_DIR" -type f -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$mem_count" in
    ''|*[!0-9]*) ;;
    *) audit_memory_count="$mem_count" ;;
  esac
fi

# Newest `applied` audit report → its mtime is the last-audit timestamp.
applied_at=0
draft_pending=false
AUDIT_DIR="$PROJECT_ROOT/.gaia/local/audit"
if [ -d "$AUDIT_DIR" ]; then
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    fm_status=$(sed -n '1,/^---[[:space:]]*$/p' "$f" 2>/dev/null \
      | grep -m1 -E '^status:[[:space:]]*' 2>/dev/null \
      | sed 's/^status:[[:space:]]*//' | tr -d '[:space:]')
    if [ "$fm_status" = "applied" ] || [ "$fm_status" = "applied-partial" ]; then
      if [ "$applied_at" -eq 0 ] 2>/dev/null; then
        m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
        case "$m" in
          ''|*[!0-9]*) ;;
          *) applied_at="$m" ;;
        esac
      fi
    elif [ "$fm_status" = "draft" ]; then
      draft_pending=true
    fi
  done < <(ls -t "$AUDIT_DIR"/KNOWLEDGE-*.md 2>/dev/null)
fi
# Advance the last-applied anchor (and reset the memory baseline to the count at
# that audit) only when a newer applied report appears. This is the debounce:
# running an audit writes a fresh applied report, moving the anchor forward and
# resetting the baseline, which clears signal (a).
if [ "$applied_at" -gt "$audit_last_applied_at" ] 2>/dev/null; then
  audit_last_applied_at="$applied_at"
  audit_memory_baseline="$audit_memory_count"
fi

# (a) Per-machine drift: memory grew by >= AUDIT_MEMORY_DELTA since the last
# applied audit, OR >= AUDIT_DRIFT_DAYS elapsed since it.
mem_delta=$((audit_memory_count - audit_memory_baseline))
drift_secs=$((AUDIT_DRIFT_DAYS * 86400))
machine_drift=false
if [ "$mem_delta" -ge "$AUDIT_MEMORY_DELTA" ] 2>/dev/null; then
  machine_drift=true
fi
if [ "$audit_last_applied_at" -gt 0 ] 2>/dev/null \
  && [ "$((now - audit_last_applied_at))" -ge "$drift_secs" ] 2>/dev/null; then
  machine_drift=true
fi

# (b) Project drift: any committed auto-load file over budget. Budget-only, no
# committed marker; clears for everyone once a dev fixes + commits.
project_drift=false
hot_words=$(wc -w < "$PROJECT_ROOT/wiki/hot.md" 2>/dev/null | tr -d '[:space:]')
case "$hot_words" in
  ''|*[!0-9]*) hot_words=0 ;;
esac
if [ "$hot_words" -gt "$AUDIT_HOT_BUDGET" ] 2>/dev/null; then
  project_drift=true
fi
claudemd_words=$(wc -w < "$PROJECT_ROOT/CLAUDE.md" 2>/dev/null | tr -d '[:space:]')
case "$claudemd_words" in
  ''|*[!0-9]*) claudemd_words=0 ;;
esac
if [ "$claudemd_words" -gt "$AUDIT_CLAUDEMD_BUDGET" ] 2>/dev/null; then
  project_drift=true
fi
for rule in "$PROJECT_ROOT"/.claude/rules/*.md; do
  [ -f "$rule" ] || continue
  rule_lines=$(wc -l < "$rule" 2>/dev/null | tr -d '[:space:]')
  case "$rule_lines" in
    ''|*[!0-9]*) continue ;;
  esac
  if [ "$rule_lines" -gt "$AUDIT_RULE_BUDGET" ] 2>/dev/null; then
    project_drift=true
    break
  fi
done

# Pick the single highest-priority reason.
if [ "$draft_pending" = "true" ]; then
  audit_nudge=true
  audit_nudge_reason="resume draft"
elif [ "$machine_drift" = "true" ]; then
  audit_nudge=true
  audit_nudge_reason="machine drift"
elif [ "$project_drift" = "true" ]; then
  audit_nudge=true
  audit_nudge_reason="over budget"
fi

case "$audit_last_applied_at" in
  ''|*[!0-9]*) audit_last_applied_at=0 ;;
esac
case "$audit_memory_count" in
  ''|*[!0-9]*) audit_memory_count=0 ;;
esac
case "$audit_memory_baseline" in
  ''|*[!0-9]*) audit_memory_baseline=0 ;;
esac

# ---------- gaiaCurrent ----------
gaia_current=""
if [ -f "$VERSION_FILE" ]; then
  gaia_current=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null)
fi

# ---------- gaiaLatest ----------
gaia_latest=""
if command -v gh >/dev/null 2>&1; then
  gaia_latest=$(gh release list --repo gaia-react/gaia --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null)
fi
if [ -z "$gaia_latest" ] && command -v curl >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    gaia_latest=$(curl -fsSL --max-time 5 https://api.github.com/repos/gaia-react/gaia/releases/latest 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null)
  else
    # Last-resort: grep the tag_name out of the JSON without jq.
    gaia_latest=$(curl -fsSL --max-time 5 https://api.github.com/repos/gaia-react/gaia/releases/latest 2>/dev/null \
      | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 \
      | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  fi
fi
# Strip leading 'v'.
gaia_latest="${gaia_latest#v}"
# Fall back to previous value if both fetchers failed (don't blank it).
if [ -z "$gaia_latest" ]; then
  gaia_latest="$prev_gaia_latest"
fi

# ---------- gaiaHasUpdate ----------
gaia_has_update=false
if [ -n "$gaia_current" ] && [ -n "$gaia_latest" ] && [ "$gaia_current" != "$gaia_latest" ]; then
  highest=$(printf '%s\n%s\n' "$gaia_current" "$gaia_latest" | sort -V | tail -1)
  if [ "$highest" = "$gaia_latest" ]; then
    gaia_has_update=true
  fi
fi

# ---------- Write cache atomically ----------
tmp_file="$(mktemp "$CACHE_DIR/.update-check.XXXXXX" 2>/dev/null)"
if [ -z "$tmp_file" ]; then
  tmp_file="$CACHE_FILE.tmp.$$"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --argjson checkedAt "$now" \
    --argjson outdatedCount "$outdated_count" \
    --arg gaiaCurrent "$gaia_current" \
    --arg gaiaLatest "$gaia_latest" \
    --argjson gaiaHasUpdate "$gaia_has_update" \
    --argjson hardenCandidateCount "$harden_count" \
    --argjson auditNudge "$audit_nudge" \
    --arg auditNudgeReason "$audit_nudge_reason" \
    --argjson auditLastAppliedAt "$audit_last_applied_at" \
    --argjson auditMemoryCount "$audit_memory_count" \
    --argjson auditMemoryBaseline "$audit_memory_baseline" \
    '{checkedAt: $checkedAt, outdatedCount: $outdatedCount, gaiaCurrent: $gaiaCurrent, gaiaLatest: $gaiaLatest, gaiaHasUpdate: $gaiaHasUpdate, hardenCandidateCount: $hardenCandidateCount, auditNudge: $auditNudge, auditNudgeReason: $auditNudgeReason, auditLastAppliedAt: $auditLastAppliedAt, auditMemoryCount: $auditMemoryCount, auditMemoryBaseline: $auditMemoryBaseline}' \
    > "$tmp_file" 2>/dev/null
else
  # jq not available; emit valid JSON via printf.
  printf '{"checkedAt":%s,"outdatedCount":%s,"gaiaCurrent":"%s","gaiaLatest":"%s","gaiaHasUpdate":%s,"hardenCandidateCount":%s,"auditNudge":%s,"auditNudgeReason":"%s","auditLastAppliedAt":%s,"auditMemoryCount":%s,"auditMemoryBaseline":%s}\n' \
    "$now" "$outdated_count" "$gaia_current" "$gaia_latest" "$gaia_has_update" "$harden_count" "$audit_nudge" "$audit_nudge_reason" "$audit_last_applied_at" "$audit_memory_count" "$audit_memory_baseline" \
    > "$tmp_file" 2>/dev/null
fi

if [ -s "$tmp_file" ]; then
  mv "$tmp_file" "$CACHE_FILE" 2>/dev/null
else
  rm -f "$tmp_file" 2>/dev/null
fi

exit 0
