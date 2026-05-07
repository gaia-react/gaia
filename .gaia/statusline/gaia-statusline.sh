#!/bin/bash
# GAIA project-scoped statusline.
#
# Reads JSON from stdin (Claude Code convention), prints a single line.
# Left side is delegated; right side is the GAIA addons (outdated packages,
# GAIA release available) read from the TTL-cached refresher.
#
# Left-side resolution (first match wins):
#   1. Project sentinel `.gaia/statusline/.use-vendored-base` exists →
#      run `.gaia/statusline/preferred-base.sh` (project-only mode).
#   2. User has `statusLine.command` in `~/.claude/settings.json` → run that
#      (so the adopter's existing global statusline appears unchanged).
#   3. Fallback → `.gaia/statusline/preferred-base.sh` directly.
#
# The hot path stays fast (target <50ms): no network calls, no `pnpm` calls.
# A background refresher (.gaia/scripts/check-updates.sh) writes the cache.
#
# Partial failures are silent — a broken statusline disappears in Claude Code,
# which is the worst UX. Do NOT add `set -e`.

# Resolve script directory so cache lookups work regardless of caller cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$GAIA_DIR/.." && pwd)"
CACHE_FILE="$GAIA_DIR/cache/update-check.json"
CHECK_SCRIPT="$PROJECT_ROOT/.gaia/scripts/check-updates.sh"
SENTINEL="$SCRIPT_DIR/.use-vendored-base"
PREFERRED_BASE="$SCRIPT_DIR/preferred-base.sh"

# Read JSON input once.
input=$(cat)

# ---------- Left side (delegated) ----------
left=""
if [ -f "$SENTINEL" ] && [ -r "$PREFERRED_BASE" ]; then
  left=$(printf '%s' "$input" | bash "$PREFERRED_BASE" 2>/dev/null)
fi

if [ -z "$left" ] && [ "$GAIA_STATUSLINE_NESTED" != "1" ]; then
  user_cmd=""
  if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
    user_cmd=$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)
  fi
  # Skip if it points back at this wrapper (avoid recursion).
  case "$user_cmd" in
    *gaia-statusline.sh*) user_cmd="" ;;
  esac
  if [ -n "$user_cmd" ]; then
    left=$(printf '%s' "$input" | GAIA_STATUSLINE_NESTED=1 bash -c "$user_cmd" 2>/dev/null)
  fi
fi

if [ -z "$left" ] && [ -r "$PREFERRED_BASE" ]; then
  left=$(printf '%s' "$input" | bash "$PREFERRED_BASE" 2>/dev/null)
fi

[ -z "$left" ] && left="Claude Code"

# ---------- Right side from cache ----------
# Per-machine setup gate: when .gaia/local/setup-state.json is missing or
# its completed_at is null, the right side shows ONLY `Run /setup-gaia` —
# the other indicators are suppressed until the developer has run through
# the per-clone setup at least once. The setup file is gitignored, so each
# clone gets its own state.
SETUP_STATE_FILE="$PROJECT_ROOT/.gaia/local/setup-state.json"
setup_complete="false"
if [ -f "$SETUP_STATE_FILE" ]; then
  if command -v jq >/dev/null 2>&1; then
    if [ "$(jq -r '.completed_at // "null"' "$SETUP_STATE_FILE" 2>/dev/null)" != "null" ]; then
      setup_complete="true"
    fi
  else
    # Fallback: a complete state has a non-null completed_at value.
    if grep -q '"completed_at"[[:space:]]*:[[:space:]]*"' "$SETUP_STATE_FILE" 2>/dev/null; then
      setup_complete="true"
    fi
  fi
fi

right=""
if [ "$setup_complete" != "true" ]; then
  right="$(printf '\033[01;35mRun /setup-gaia (Required)\033[00m')"
elif [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  outdated_count=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
  gaia_has_update=$(jq -r '.gaiaHasUpdate // false' "$CACHE_FILE" 2>/dev/null)
  gaia_latest=$(jq -r '.gaiaLatest // empty' "$CACHE_FILE" 2>/dev/null)

  segments=()
  # 🧭 mentorship-active indicator (UAT-037/038)
  COACHING_FILE="$GAIA_DIR/cache/coaching-active.txt"
  if [ -f "$COACHING_FILE" ] && [ "$(cat "$COACHING_FILE" 2>/dev/null)" = "1" ]; then
    segments+=("🧭")
  fi
  if [ -n "$outdated_count" ] && [ "$outdated_count" -gt 0 ] 2>/dev/null; then
    segments+=("$(printf '\033[01;33mRun /update-deps (%d outdated)\033[00m' "$outdated_count")")
  fi
  if [ "$gaia_has_update" = "true" ] && [ -n "$gaia_latest" ]; then
    segments+=("$(printf '\033[01;36mRun /update-gaia (GAIA %s available)\033[00m' "$gaia_latest")")
  fi
  if [ "${#segments[@]}" -gt 0 ]; then
    right="${segments[0]}"
    for ((i=1; i<${#segments[@]}; i++)); do
      right="${right}  ${segments[$i]}"
    done
  fi
fi

# Fire the background refresher; never block.
if [ -x "$CHECK_SCRIPT" ]; then
  (cd "$PROJECT_ROOT" && nohup bash "$CHECK_SCRIPT" >/dev/null 2>&1 &) >/dev/null 2>&1
fi

# ---------- Compose with right-alignment ----------
if [ -z "$right" ]; then
  printf '%b' "$left"
  exit 0
fi

cols="${COLUMNS:-120}"
left_visible=$(printf '%b' "$left" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print length}')
right_visible=$(printf '%b' "$right" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print length}')
pad=$((cols - left_visible - right_visible))
if [ "$pad" -lt 2 ]; then
  pad=2
fi
spaces=$(printf '%*s' "$pad" '')
printf '%b%s%b' "$left" "$spaces" "$right"
