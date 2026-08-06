#!/bin/bash
# GAIA tech-debt count refresher.
#
# Recomputes the number of open `tech-debt` GitHub issues into a pinned cache
# (.gaia/local/debt/count.json) consumed by the statusline `Run /gaia-debt`
# segment.
#
# The same cache carries `coveredPaths`: the repo-relative paths that already
# have an open `tech-debt` issue, parsed out of each issue body's
# `gaia-debt-key` comment. check-updates.sh reads that list to suppress the
# audit nudge's `project_drift` arm for a file whose over-budget condition is
# already tracked, so a completed `/gaia-audit` that files rather than trims
# leaves the nudge clear instead of re-firing for work it just queued.
#
# `coveredPaths` and `openCount` deliberately apply DIFFERENT filters to the
# same fetch. `openCount` excludes claimed and parked issues so they do not
# inflate the nudge for a peer session; `coveredPaths` excludes nothing, because
# a claimed issue still covers its path and suppression must hold while someone
# is working on it.
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

# GitHub's issue-list index is eventually consistent: right after a /gaia-debt PR
# merges and its `Closes #N` fires, `gh issue list --state open` can keep counting
# the just-closed issue for a few seconds (observed: still 1 several seconds past
# the issue's closedAt). A sentinel-triggered recompute in that window caches a
# stale (too-high) count and, by clearing the sentinel, freezes it until the TTL,
# so the `Run /gaia-debt` nudge lingers for hours after the backlog is empty. A
# recompute fired by a sentinel younger than this settle grace therefore writes
# the fresh count but keeps the sentinel armed, forcing a later tick to re-read
# the now-consistent count before the sentinel clears. TTL/missing-cache
# recomputes are not racing a merge and clear normally.
SENTINEL_SETTLE_GRACE=120

# Resolve project root (parent of .gaia/) so the script works regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GAIA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$GAIA_DIR/.." && pwd)"

# debt/count.json and debt/refresh-requested are registry scope `shared`: one
# physical copy per clone, which the statusline reads by resolving the main
# checkout. This script's own location answers "which tree am I in", never
# "where does shared state live", so a copy running inside a worktree must ask
# the resolver the same question the reader asks. Degrade-to-local rather than
# fail (D-5.3-c), matching .gaia/statusline/gaia-statusline.sh: with no resolver
# to ask, the local root is the honest answer and the refresher still refreshes.
if [ -f "$GAIA_DIR/scripts/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$GAIA_DIR/scripts/main-root-lib.sh" 2>/dev/null || true
fi
STATE_ROOT=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  STATE_ROOT="$(gaia_resolve_main_root "$PROJECT_ROOT" 2>/dev/null || true)"
fi
[ -n "$STATE_ROOT" ] || STATE_ROOT="$PROJECT_ROOT"

DEBT_DIR="$STATE_ROOT/.gaia/local/debt"
CACHE_FILE="$DEBT_DIR/count.json"
SENTINEL="$DEBT_DIR/refresh-requested"

now=$(date +%s)

# Portable mtime of $1 as an integer, 0 when the file is absent or unreadable.
# Tries GNU `-c %Y` first, then BSD/macOS `-f %m`, validating the result is
# numeric BETWEEN the two attempts rather than chaining on exit code: GNU
# `stat -f %m` does NOT fail on an unknown filesystem directive, it exits 0
# printing `?`, so a `-f %m || -c %Y` chain silently wins with garbage on Linux.
# The numeric re-check defeats that. Both sentinel reads below go through this
# one helper so the two can never drift apart.
mtime_of() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null)
  case "$m" in
    ''|*[!0-9]*) m=$(stat -f %m "$1" 2>/dev/null) ;;
  esac
  case "$m" in
    ''|*[!0-9]*) m=0 ;;
  esac
  printf '%s' "$m"
}

# Read previous cache values (used as fallbacks on partial failure).
prev_computed_at=0
prev_open_count=0
prev_covered_paths='[]'
have_prev_cache=false
if [ -f "$CACHE_FILE" ] && command -v jq >/dev/null 2>&1; then
  have_prev_cache=true
  prev_computed_at=$(jq -r '.computedAt // 0' "$CACHE_FILE" 2>/dev/null)
  prev_open_count=$(jq -r '.openCount // 0' "$CACHE_FILE" 2>/dev/null)
  # Same never-blank posture as the count: a partial failure below keeps the
  # paths already cached rather than dropping suppression on a transient error.
  # Read once and validate that value, so the guard and the assignment cannot
  # disagree about what was read.
  covered_read=$(jq -c '.coveredPaths // []' "$CACHE_FILE" 2>/dev/null)
  case "$covered_read" in
    '['*) prev_covered_paths="$covered_read" ;;
  esac
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
sentinel_settled=true
# Sampled here, re-read at the clear below; 0 means "no sentinel at sample time".
# An unreadable mtime also reads as 0, i.e. "aged past the grace", so a stat
# failure reverts to clear-on-recompute rather than wedging the sentinel armed
# forever.
sentinel_mtime=0
if [ -e "$SENTINEL" ]; then
  should_recompute=true
  sentinel_mtime=$(mtime_of "$SENTINEL")
  if [ "$((now - sentinel_mtime))" -lt "$SENTINEL_SETTLE_GRACE" ]; then
    sentinel_settled=false
  fi
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
# Count open issues carrying the `tech-debt` label via gh, excluding any that
# also carry `debt:in-progress` (the /gaia-debt in-progress claim label) or
# `debt:spec-pending` (the parked design-first handoff label) so a claimed or
# parked issue does not inflate the nudge for a peer session. Guarded on gh
# presence + auth + network; on ANY failure keep the previous cached count
# (never blank it).
#
# ONE fetch answers both fields. With local jq the raw issue list is pulled once
# and filtered twice here; without it, gh's own `--jq` computes the count
# server-side exactly as before and `coveredPaths` carries forward unchanged.
# That degradation is safe in one direction only, and deliberately so: fewer
# covered paths means less suppression, so the nudge fires more often, never
# less. A missing jq can never silence a live over-budget condition.
open_count="$prev_open_count"
covered_paths="$prev_covered_paths"
recompute_ok=false
# One expression, used by whichever arm runs, so the two can never drift apart.
COUNT_FILTER='[.[] | select([.labels[].name] | (index("debt:in-progress") or index("debt:spec-pending")) | not)] | length'
if command -v gh >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    issues_json=$(gh issue list --label tech-debt --state open --json number,labels,body --limit 1000 2>/dev/null)
    count_out=$(printf '%s' "$issues_json" | jq "$COUNT_FILTER" 2>/dev/null)
    # Anchored on the whole `<!-- gaia-debt-key:` opener, not a bare `path=` and
    # not the bare key name, so body prose that merely mentions the key cannot
    # inject a path. That direction matters: a false match would ADD suppression,
    # which is the one direction the header's safety argument does not cover.
    # The lazy ` line=` terminator is what lets a path contain spaces, as
    # several filed issues do.
    paths_out=$(printf '%s' "$issues_json" | jq -c '[.[] | (.body // "") | scan("<!-- gaia-debt-key:[^>]*?path=(.+?) line=")] | flatten | unique' 2>/dev/null)
    case "$count_out" in
      ''|*[!0-9]*) ;;
      *) open_count="$count_out"; recompute_ok=true ;;
    esac
    case "$paths_out" in
      '['*) covered_paths="$paths_out" ;;
    esac
  else
    count_out=$(gh issue list --label tech-debt --state open --json number,labels --jq "$COUNT_FILTER" --limit 1000 2>/dev/null)
    case "$count_out" in
      ''|*[!0-9]*) ;;
      *) open_count="$count_out"; recompute_ok=true ;;
    esac
  fi
fi

# Backend absent / unauthenticated / network failure with a prior cache: leave
# the cache untouched and keep the sentinel so the next tick retries. Only when
# there is NO prior cache do we seed a definite openCount 0, so the statusline
# reads 0 and renders nothing rather than inventing a count.
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
    --argjson coveredPaths "$covered_paths" \
    '{schema: 1, openCount: $openCount, computedAt: $computedAt, coveredPaths: $coveredPaths}' \
    > "$tmp_file" 2>/dev/null
else
  # The no-jq branch hardcodes an empty list because deriving it requires jq;
  # readers treat a missing or empty list as "suppress nothing".
  printf '{"schema":1,"openCount":%s,"computedAt":%s,"coveredPaths":[]}\n' "$open_count" "$now" > "$tmp_file" 2>/dev/null
fi

if [ -s "$tmp_file" ]; then
  mv "$tmp_file" "$CACHE_FILE" 2>/dev/null
else
  rm -f "$tmp_file" 2>/dev/null
fi

# Clear the sentinel after a genuine recompute (not the zero-seed fallback: a
# backend-absent zero-seed keeps the sentinel so the next tick retries once gh
# is back). But hold a freshly-set sentinel armed through the settle grace so a
# later tick re-reads GitHub's now-consistent count before the sentinel clears;
# otherwise a recompute that raced the merge's `Closes #N` would freeze a stale
# count until the TTL. `sentinel_settled` is true when no sentinel exists or when
# it has aged past the grace.
#
# Compare-and-clear: the state registry classifies `.gaia/local/debt/` as a
# shared entry (shared across every linked worktree), so a peer's merge can arm
# the sentinel during the `gh` call above, minutes after `sentinel_mtime` was
# sampled. Clearing on that stale sample would delete an
# invalidation nothing has serviced, freezing the count until the next event or
# the TTL. Re-read the mtime so the clear acts on current state instead: a
# sentinel that is now absent, re-armed, or newly armed (sampled 0, present now)
# all read as a mismatch and survive.
#
# This narrows the race rather than closing it. POSIX shell has no atomic
# compare-and-unlink, so a peer arming the sentinel between this stat and the
# `rm` below still loses its invalidation. That residual window is accepted: it
# shrinks the exposure from a whole network round-trip to the gap between two
# adjacent statements, and the cost of losing the bet is one delayed count
# refresh, bounded by the TTL.
if [ "$recompute_ok" = "true" ] && [ "$sentinel_settled" = "true" ] &&
   [ "$(mtime_of "$SENTINEL")" = "$sentinel_mtime" ]; then
  rm -f "$SENTINEL" 2>/dev/null
fi

exit 0
