#!/bin/bash
# GAIA SessionStart update checker.
#
# Writes .gaia/cache/update-check.json with:
#   - outdatedCount  (from `pnpm outdated --json | jq length`)
#   - gaiaCurrent    (from .gaia/VERSION)
#   - gaiaLatest     (from `gh release list` or curl GitHub API)
#   - gaiaHasUpdate  (semver comparison)
#   - checkedAt      (Unix epoch seconds)
#
# TTL is 6 hours (21600s). Re-runs within the TTL exit immediately so the
# SessionStart hook can fire this in the background without paying the cost
# on every session.
#
# Partial failures are tolerated — exit 0 even if some fields could not be
# refreshed. Do NOT add `set -e`.

TTL=21600

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
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  prev_checked_at=$(jq -r '.checkedAt // 0' "$CACHE_FILE" 2>/dev/null)
  prev_outdated_count=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
  prev_gaia_current=$(jq -r '.gaiaCurrent // ""' "$CACHE_FILE" 2>/dev/null)
  prev_gaia_latest=$(jq -r '.gaiaLatest // ""' "$CACHE_FILE" 2>/dev/null)
  prev_gaia_has_update=$(jq -r '.gaiaHasUpdate // false' "$CACHE_FILE" 2>/dev/null)
  case "$prev_checked_at" in
    ''|*[!0-9]*) prev_checked_at=0 ;;
  esac
fi

# TTL gate.
age=$((now - prev_checked_at))
if [ "$age" -lt "$TTL" ]; then
  exit 0
fi

mkdir -p "$CACHE_DIR" 2>/dev/null

# ---------- outdatedCount ----------
outdated_count=0
if [ -f "$PROJECT_ROOT/package.json" ] && command -v pnpm >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  raw=$(cd "$PROJECT_ROOT" && pnpm outdated --json 2>/dev/null)
  if [ -n "$raw" ]; then
    # Drop packages that /update-deps cannot update:
    # - `eslint` / `@eslint/js` capped at 9.x while latest is 10.x
    #   (matches the ESLint-cap rule in .claude/commands/update-deps.md)
    parsed=$(printf '%s' "$raw" | jq '
      [to_entries[]
       | select(
           ((.key == "eslint" or .key == "@eslint/js")
            and ((.value.latest | split(".") | .[0] | tonumber) >= 10)) | not
         )]
      | length
    ' 2>/dev/null)
    case "$parsed" in
      ''|*[!0-9]*) outdated_count="$prev_outdated_count" ;;
      *) outdated_count="$parsed" ;;
    esac
  fi
fi
case "$outdated_count" in
  ''|*[!0-9]*) outdated_count=0 ;;
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
    '{checkedAt: $checkedAt, outdatedCount: $outdatedCount, gaiaCurrent: $gaiaCurrent, gaiaLatest: $gaiaLatest, gaiaHasUpdate: $gaiaHasUpdate}' \
    > "$tmp_file" 2>/dev/null
else
  # jq not available — emit valid JSON via printf.
  printf '{"checkedAt":%s,"outdatedCount":%s,"gaiaCurrent":"%s","gaiaLatest":"%s","gaiaHasUpdate":%s}\n' \
    "$now" "$outdated_count" "$gaia_current" "$gaia_latest" "$gaia_has_update" \
    > "$tmp_file" 2>/dev/null
fi

if [ -s "$tmp_file" ]; then
  mv "$tmp_file" "$CACHE_FILE" 2>/dev/null
else
  rm -f "$tmp_file" 2>/dev/null
fi

exit 0
