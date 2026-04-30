#!/bin/bash
# GAIA SessionStart update-prompt hook.
# Reads .gaia/cache/statusline-update-check.json (already maintained by the
# statusline background refresher) and emits a system reminder asking the
# user whether to run the update-deps / update-gaia skills.
# Silent on missing cache. Never blocks. No git ops, no file writes.

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CACHE_FILE="$PROJECT_ROOT/.gaia/cache/statusline-update-check.json"

[ -f "$CACHE_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

outdated=$(jq -r '.outdatedCount // 0' "$CACHE_FILE" 2>/dev/null)
gaia_current=$(jq -r '.gaiaCurrent // ""' "$CACHE_FILE" 2>/dev/null)
gaia_latest=$(jq -r '.gaiaLatest // ""' "$CACHE_FILE" 2>/dev/null)
gaia_has_update=$(jq -r '.gaiaHasUpdate // false' "$CACHE_FILE" 2>/dev/null)

case "$outdated" in
  ''|*[!0-9]*) outdated=0 ;;
esac

lines=()
if [ "$outdated" -gt 0 ] 2>/dev/null; then
  lines+=("GAIA: $outdated outdated dependencies detected (cache TTL 6h). Run the \`update-deps\` skill? (y/n)")
fi
if [ "$gaia_has_update" = "true" ] && [ -n "$gaia_latest" ]; then
  lines+=("GAIA: GAIA template v$gaia_latest is available (current v$gaia_current). Run the \`update-gaia\` skill? (y/n)")
fi

if [ "${#lines[@]}" -gt 0 ]; then
  printf '<system-reminder>\n'
  for line in "${lines[@]}"; do
    printf '%s\n' "$line"
  done
  printf '</system-reminder>\n'
fi

exit 0
