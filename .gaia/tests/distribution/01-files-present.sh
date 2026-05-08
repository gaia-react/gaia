#!/usr/bin/env bash
# 01-files-present.sh
#
# Asserts the staged tarball matches the manifest contract:
#  1. Every path in .gaia/manifest.json files{} exists in the staging tree.
#  2. Every path in .gaia/release-exclude is ABSENT from the staging tree.
#  3. Adopter-owned sentinels (wiki/hot.md, wiki/log.md, .gaia/VERSION,
#     .gaia/manifest.json) exist and contain release-baseline content
#     (not maintainer dev content).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd jq "jq required for manifest parsing — install via 'brew install jq'"
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
  for p in "${MISSING[@]}"; do log "  $p"; done
  fail "${#MISSING[@]} manifest path(s) missing from staging"
  exit 1
fi

# 2. Every release-exclude path is ABSENT from staging.
# Read literal patterns; skip comments and blanks. For directory entries
# (no trailing wildcard), assert the directory does not exist. For file
# entries, assert the file does not exist. Glob-shaped entries (`**`,
# trailing `*`) are checked via `find … -path` once.
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
  for p in "${LEAKED[@]}"; do log "  $p"; done
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
# proxy — it catches "scrub-wiki didn't run" AND "scrub-wiki wrote the
# wrong version". Marker shapes are pinned to scrub-wiki.ts:renderHotMd /
# renderLogMd.
grep -qF "## [v$PKG_VER]" "$STAGING/wiki/log.md" \
  || { fail "wiki/log.md missing '## [v$PKG_VER]' release marker — scrub-wiki did not run or wrote a wrong version"; exit 1; }
grep -qF "GAIA v$PKG_VER" "$STAGING/wiki/hot.md" \
  || { fail "wiki/hot.md missing 'GAIA v$PKG_VER' release marker — scrub-wiki did not run or wrote a wrong version"; exit 1; }

pass "manifest, exclude list, and sentinels all consistent with staging"
