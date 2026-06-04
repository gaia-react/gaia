#!/usr/bin/env bash
# 03-marker-strip.sh
#
# Asserts the marker-strip transform fired correctly:
#   1. No marker fragments (`gaia:maintainer-only:start/end`) survive in
#      the staged tree.
#   2. Every source file containing a marker block has a smaller staged
#      counterpart (file-size delta > 0).
#   3. No staged counterpart shrunk to zero bytes (would indicate the
#      whole file was inside a marker block; almost certainly wrong).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

STAGING="$(mktemp -d -t gaia-dist-marker-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# 1. No marker fragments survive in staging tree.
SURVIVING=$(grep -rln 'gaia:maintainer-only' "$STAGING" 2>/dev/null || true)
if [ -n "$SURVIVING" ]; then
  log "Marker fragments survived strip in staging:"
  printf '%s\n' "$SURVIVING" >&2
  fail "marker fragments present in staging"
  exit 1
fi

# 2. Every source file with a marker block must have a smaller staged
# counterpart. Walk the source tree (only release-shipped paths; i.e.
# files NOT in release-exclude). Use the same exclude mechanism as
# build-staging.sh so we don't grep maintainer-only files.

# Build the include list the same way build-staging.sh does, then
# filter to files that contained a start marker.
ALL_TRACKED="$(mktemp)"
EXCLUDE_REGEX="$(mktemp)"
INCLUDE="$(mktemp)"
trap 'rm -rf "$STAGING" "$ALL_TRACKED" "$EXCLUDE_REGEX" "$INCLUDE"' EXIT

git -C "$PROJECT_ROOT" ls-files > "$ALL_TRACKED"
awk '/^[[:space:]]*#/ {next} NF==0 {next} {print}' "$PROJECT_ROOT/.gaia/release-exclude" \
  | sed 's|[][\\.*^$()+?{}|]|\\&|g' \
  | awk '{print "^"$0"(/|$)"}' \
  > "$EXCLUDE_REGEX"
if [ -s "$EXCLUDE_REGEX" ]; then
  grep -vE -f "$EXCLUDE_REGEX" "$ALL_TRACKED" > "$INCLUDE"
else
  cp "$ALL_TRACKED" "$INCLUDE"
fi

MISSING_DELTA=()
ZERO_BYTE=()
while IFS= read -r rel; do
  src="$PROJECT_ROOT/$rel"
  staged="$STAGING/$rel"
  [ -f "$src" ] || continue
  grep -q 'gaia:maintainer-only:start' "$src" 2>/dev/null || continue

  # Source had a marker block; staged counterpart must exist and be smaller.
  if [ ! -f "$staged" ]; then
    log "Source has marker block but staged counterpart missing: $rel"
    MISSING_DELTA+=("$rel:missing")
    continue
  fi
  src_size=$(wc -c < "$src")
  staged_size=$(wc -c < "$staged")
  if [ "$staged_size" -ge "$src_size" ]; then
    MISSING_DELTA+=("$rel: src=$src_size staged=$staged_size (no shrink)")
    continue
  fi
  if [ "$staged_size" -eq 0 ]; then
    ZERO_BYTE+=("$rel")
    continue
  fi
done < "$INCLUDE"

if [ "${#MISSING_DELTA[@]}" -gt 0 ]; then
  log "Files with marker blocks that did not shrink in staging:"
  for entry in "${MISSING_DELTA[@]}"; do log "  $entry"; done
  fail "${#MISSING_DELTA[@]} marker-bearing file(s) not stripped"
  exit 1
fi

if [ "${#ZERO_BYTE[@]}" -gt 0 ]; then
  log "Files reduced to zero bytes by marker strip; likely whole-file blocks:"
  for entry in "${ZERO_BYTE[@]}"; do log "  $entry"; done
  fail "${#ZERO_BYTE[@]} file(s) became empty after strip"
  exit 1
fi

pass "marker-strip transform verified; all marker-bearing files shrunk"
