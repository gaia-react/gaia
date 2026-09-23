#!/usr/bin/env bash
# 01-files-present.sh
#
# Asserts the staged tarball matches the manifest contract:
#  1. Every path in .gaia/manifest.json files{} exists in the staging tree.
#  2. Every path in .gaia/release-exclude is ABSENT from the staging tree.
#  3. Adopter-owned sentinels (wiki/hot.md, wiki/log.md, .gaia/VERSION,
#     .gaia/manifest.json) exist and contain release-baseline content
#     (not maintainer dev content).
#  4. .gaia/scripts/check-hook-scope-manifest.sh ships and passes against the
#     staged tree, so running it by hand on an adopter clone does not red on
#     a release-excluded hook the staging step already stripped.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd jq "jq required for manifest parsing; install via 'brew install jq'"
require_cmd rsync "rsync required for staging build"

STAGING="$(mktemp -d -t gaia-dist-presence-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# 1. Every manifest path exists in staging.
MISSING=()
while IFS= read -r p; do
  [ -e "$STAGING/$p" ] || MISSING+=("$p")
done < <(jq -r '.files | keys[]' "$STAGING/.gaia/manifest.json")

if [ "${#MISSING[@]}" -gt 0 ]; then
  log "Manifest claims paths missing from staging tree:"
  for p in ${MISSING[@]+"${MISSING[@]}"}; do log "  $p"; done
  fail "${#MISSING[@]} manifest path(s) missing from staging"
  exit 1
fi

# 2. Every release-exclude path is ABSENT from staging.
# Every entry is a literal path, file or directory; skip comments and
# blanks, then assert the literal path does not exist in staging via
# `[ -e ]`, which covers both file and directory entries without needing
# to distinguish them.
LEAKED=()
while IFS= read -r raw; do
  # Skip blanks and comments
  case "$raw" in ''|\#*) continue ;; esac
  pat="$raw"
  if [ -e "$STAGING/$pat" ]; then
    LEAKED+=("$pat")
  fi
done < "$PROJECT_ROOT/.gaia/release-exclude"

if [ "${#LEAKED[@]}" -gt 0 ]; then
  log "Release-excluded paths present in staging tree:"
  for p in ${LEAKED[@]+"${LEAKED[@]}"}; do log "  $p"; done
  fail "${#LEAKED[@]} release-excluded path(s) leaked into staging"
  exit 1
fi

# 3. Adopter-owned sentinels present with release-baseline content.
for sentinel in wiki/hot.md wiki/log.md .gaia/VERSION .gaia/manifest.json; do
  [ -e "$STAGING/$sentinel" ] || { fail "sentinel missing: $sentinel"; exit 1; }
done

# .gaia/VERSION should be a single line ending with a newline,
# matching the package.json `version` field.
PKG_VER="$(jq -r '.version' "$STAGING/package.json")"
FILE_VER="$(tr -d '[:space:]' < "$STAGING/.gaia/VERSION")"
[ "$PKG_VER" = "$FILE_VER" ] \
  || { fail ".gaia/VERSION ($FILE_VER) != package.json version ($PKG_VER)"; exit 1; }

# wiki/hot.md and wiki/log.md should carry the release-marker strings
# that `gaia-maintainer release scrub-wiki` writes (Step 8 + 9 of
# `/gaia-release`).
# Asserting on the actual rendered content is stricter than a line-count
# proxy; it catches "scrub-wiki didn't run" AND "scrub-wiki wrote the
# wrong version". Marker shapes are pinned to scrub-wiki.ts:renderHotMd /
# renderLogMd.
grep -qF "## [v$PKG_VER]" "$STAGING/wiki/log.md" \
  || { fail "wiki/log.md missing '## [v$PKG_VER]' release marker; scrub-wiki did not run or wrote a wrong version"; exit 1; }
grep -qF "GAIA v$PKG_VER" "$STAGING/wiki/hot.md" \
  || { fail "wiki/hot.md missing 'GAIA v$PKG_VER' release marker; scrub-wiki did not run or wrote a wrong version"; exit 1; }

# 4. Hook-scope check, run the way an adopter runs it: the staged copy
# against the staged tree. It scans every staged hook for a bare .gaia/local
# literal, so a release-excluded hook left out of staging cannot fail it, and
# a staged hook reaching .gaia/local without a resolved root does.
HOOKSCOPE_CHECKER=".gaia/scripts/check-hook-scope-manifest.sh"
if [ ! -e "$STAGING/$HOOKSCOPE_CHECKER" ]; then
  fail "missing from staging: $HOOKSCOPE_CHECKER"
  exit 1
fi
if ! HOOKSCOPE_OUT="$(bash "$STAGING/$HOOKSCOPE_CHECKER" "$STAGING" 2>&1)"; then
  log "hook-scope check fails against the staged tree:"
  log "$HOOKSCOPE_OUT"
  fail "staged $HOOKSCOPE_CHECKER reds on the staged tree"
  exit 1
fi

pass "manifest, exclude list, sentinels, and hook-scope check all consistent with staging"
