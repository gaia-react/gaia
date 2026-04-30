#!/bin/bash
# GAIA SessionStart update-prompt hook.
# Reads .gaia/cache/update-check.json and emits a system reminder asking
# whether to run the update-deps / update-gaia skill. Snoozes 6h after each
# emit (state in update-prompt-state.json). Sequences deps before gaia: when
# deps has updates we never emit a gaia prompt in the same session, but if
# deps is snoozed we fall through to gaia. Background-fires
# .gaia/scripts/check-updates.sh when the cache is stale.
# Silent on missing cache or missing jq. Never blocks.

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE_FILE="$PROJECT_ROOT/.gaia/cache/update-check.json"
STATE_FILE="$PROJECT_ROOT/.gaia/cache/update-prompt-state.json"
REFRESH_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"

TTL=21600
SNOOZE=21600

now=$(date +%s)

checked_at=0
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  checked_at=$(jq -r '.checkedAt // 0' "$CACHE_FILE" 2>/dev/null)
  case "$checked_at" in
    ''|*[!0-9]*) checked_at=0 ;;
  esac
fi
if [ "$((now - checked_at))" -ge "$TTL" ] && [ -x "$REFRESH_SCRIPT" ]; then
  (nohup bash "$REFRESH_SCRIPT" >/dev/null 2>&1 &) >/dev/null 2>&1
fi

[ -f "$CACHE_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

outdated=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
gaia_latest=$(jq -r '.gaiaLatest // ""' "$CACHE_FILE" 2>/dev/null)
gaia_has_update=$(jq -r '.gaiaHasUpdate // false' "$CACHE_FILE" 2>/dev/null)

case "$outdated" in
  ''|*[!0-9]*) outdated=0 ;;
esac

deps_prompted_at=0
gaia_prompted_at=0
if [ -f "$STATE_FILE" ]; then
  deps_prompted_at=$(jq -r '.depsPromptedAt // 0' "$STATE_FILE" 2>/dev/null)
  gaia_prompted_at=$(jq -r '.gaiaPromptedAt // 0' "$STATE_FILE" 2>/dev/null)
  case "$deps_prompted_at" in ''|*[!0-9]*) deps_prompted_at=0 ;; esac
  case "$gaia_prompted_at" in ''|*[!0-9]*) gaia_prompted_at=0 ;; esac
fi

deps_snoozed=0
gaia_snoozed=0
[ "$((now - deps_prompted_at))" -lt "$SNOOZE" ] && deps_snoozed=1
[ "$((now - gaia_prompted_at))" -lt "$SNOOZE" ] && gaia_snoozed=1

deps_should=0
gaia_should=0
if [ "$outdated" -gt 0 ] 2>/dev/null && [ "$deps_snoozed" -eq 0 ]; then
  deps_should=1
fi
if [ "$gaia_has_update" = "true" ] && [ -n "$gaia_latest" ] && [ "$gaia_snoozed" -eq 0 ]; then
  gaia_should=1
fi

emit_kind=""
if [ "$deps_should" -eq 1 ]; then
  emit_kind="deps"
elif [ "$gaia_should" -eq 1 ]; then
  emit_kind="gaia"
fi

[ -z "$emit_kind" ] && exit 0

mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null

if [ "$emit_kind" = "deps" ]; then
  printf '<system-reminder>\n%s outdated dependencies detected. Update?\n</system-reminder>\n' "$outdated"
  deps_prompted_at="$now"
else
  printf '<system-reminder>\nGAIA v%s available. Update?\n</system-reminder>\n' "$gaia_latest"
  gaia_prompted_at="$now"
fi

tmp_state="$(mktemp "$(dirname "$STATE_FILE")/.update-prompt-state.XXXXXX" 2>/dev/null)"
if [ -z "$tmp_state" ]; then
  tmp_state="$STATE_FILE.tmp.$$"
fi
jq -n \
  --argjson depsPromptedAt "$deps_prompted_at" \
  --argjson gaiaPromptedAt "$gaia_prompted_at" \
  '{depsPromptedAt: $depsPromptedAt, gaiaPromptedAt: $gaiaPromptedAt}' \
  > "$tmp_state" 2>/dev/null
if [ -s "$tmp_state" ]; then
  mv "$tmp_state" "$STATE_FILE" 2>/dev/null
else
  rm -f "$tmp_state" 2>/dev/null
fi

exit 0
