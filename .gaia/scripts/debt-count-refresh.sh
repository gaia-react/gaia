#!/bin/bash
# GAIA tech-debt count refresher.
#
# Recomputes the number of open `tech-debt` GitHub issues into a pinned cache
# (.gaia/local/debt/count.json) consumed by the statusline `Run /gaia-debt`
# segment.
#
# This refresh is INDEPENDENT of the 6h aggregate update-check refresher
# (check-updates.sh). The two debt-invalidation events (the audit filing a
# tech-debt issue; a /gaia-debt PR merging) drop a staleness sentinel
# (.gaia/local/debt/refresh-requested); this script honors it on the next tick
# so the count refreshes promptly instead of waiting up to the aggregate TTL.
#
# Recompute trigger (any one):
#   - the staleness sentinel is present (ALWAYS forces a recompute, the TTL
#     bypass the SPEC requires); OR
#   - the cache is missing; OR
#   - the cache is older than this script's own TTL.
# Otherwise exit immediately (the no-network statusline hot path stays fast;
# this runs detached in the background).
#
# Partial failures are tolerated: on any gh failure the previous cached count
# is preserved (never blanked). Backend absent (no gh / unauthenticated) with
# no prior cache seeds openCount 0 so no segment renders. Do NOT add `set -e`.

TTL=21600

# Resolve project root (parent of .gaia/) so the script works regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$GAIA_DIR/.." && pwd)"
DEBT_DIR="$PROJECT_ROOT/.gaia/local/debt"
CACHE_FILE="$DEBT_DIR/count.json"
SENTINEL="$DEBT_DIR/refresh-requested"

now=$(date +%s)

# Read previous cache values (used as fallbacks on partial failure).
prev_computed_at=0
prev_open_count=0
have_prev_cache=false
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  have_prev_cache=true
  prev_computed_at=$(jq -r '.computedAt // 0' "$CACHE_FILE" 2>/dev/null)
  prev_open_count=$(jq -r '.openCount // 0' "$CACHE_FILE" 2>/dev/null)
  case "$prev_computed_at" in
    ''|*[!0-9]*) prev_computed_at=0 ;;
  esac
  case "$prev_open_count" in
    ''|*[!0-9]*) prev_open_count=0 ;;
  esac
fi

# Decide whether to recompute. The sentinel ALWAYS forces a recompute,
# regardless of the TTL (this is the SPEC's prompt-invalidation bypass).
should_recompute=false
if [ -e "$SENTINEL" ]; then
  should_recompute=true
elif [ ! -f "$CACHE_FILE" ]; then
  should_recompute=true
else
  age=$((now - prev_computed_at))
  if [ "$age" -ge "$TTL" ]; then
    should_recompute=true
  fi
fi
if [ "$should_recompute" != "true" ]; then
  exit 0
fi

# Directory creation is this writer's own responsibility: on a fresh clone or
# in CI no statusline tick has run, so .gaia/local/debt/ may not exist yet.
mkdir -p "$DEBT_DIR" 2>/dev/null

# ---------- Recompute openCount ----------
# Count open issues carrying the FC-1 `tech-debt` label via gh. Guarded on gh
# presence + auth + network; on ANY failure keep the previous cached count
# (never blank it).
open_count="$prev_open_count"
recompute_ok=false
if command -v gh >/dev/null 2>&1; then
  count_out=$(gh issue list --label tech-debt --state open --json number --jq 'length' --limit 1000 2>/dev/null)
  case "$count_out" in
    ''|*[!0-9]*) ;;
    *) open_count="$count_out"; recompute_ok=true ;;
  esac
fi

# Backend absent / unauthenticated / network failure with a prior cache: leave
# the cache untouched and keep the sentinel so the next tick retries. Only when
# there is NO prior cache do we seed a definite openCount 0, so the statusline
# reads 0 and renders nothing rather than inventing a count (UAT-020).
if [ "$recompute_ok" != "true" ] && [ "$have_prev_cache" = "true" ]; then
  exit 0
fi
if [ "$recompute_ok" != "true" ]; then
  open_count=0
fi

# ---------- Write cache atomically ----------
tmp_file="$(mktemp "$DEBT_DIR/.count.XXXXXX" 2>/dev/null)"
if [ -z "$tmp_file" ]; then
  tmp_file="$CACHE_FILE.tmp.$$"
fi

if command -v jq >/dev/null 2>&1; then
  jq -n \
    --argjson openCount "$open_count" \
    --argjson computedAt "$now" \
    '{schema: 1, openCount: $openCount, computedAt: $computedAt}' \
    > "$tmp_file" 2>/dev/null
else
  printf '{"schema":1,"openCount":%s,"computedAt":%s}\n' "$open_count" "$now" > "$tmp_file" 2>/dev/null
fi

if [ -s "$tmp_file" ]; then
  mv "$tmp_file" "$CACHE_FILE" 2>/dev/null
else
  rm -f "$tmp_file" 2>/dev/null
fi

# Clear the sentinel only after a genuine recompute (not the zero-seed
# fallback): a backend-absent zero-seed keeps the sentinel so the next tick
# retries once gh becomes available again.
if [ "$recompute_ok" = "true" ]; then
  rm -f "$SENTINEL" 2>/dev/null
fi

exit 0
