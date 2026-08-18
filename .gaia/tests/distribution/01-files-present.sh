#!/usr/bin/env bash
# 01-files-present.sh
#
# Asserts the staged tarball matches the manifest contract:
#  1. Every path in .gaia/manifest.json files{} exists in the staging tree.
#  2. Every path in .gaia/release-exclude is ABSENT from the staging tree.
#  3. Adopter-owned sentinels (wiki/hot.md, wiki/log.md, .gaia/VERSION,
#     .gaia/manifest.json) exist and contain release-baseline content
#     (not maintainer dev content).
#  4. .gaia/script-capabilities.json and its schema ship; the capability
#     checker itself does not; and every script-capabilities.json entry's
#     maintainer_only marking agrees with the script's presence in staging.
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

# 4. Script-capabilities distribution boundary: the manifest and its schema
# ship, the checker that reads them does not, and every entry's
# maintainer_only marking agrees with what actually landed in staging. This
# reads the same release-exclude authority that built $STAGING in the first
# place, through its effect on the staged tree, rather than a second,
# independent source; its value is catching a marking that disagrees with
# what actually shipped.
BOUNDARY_ERRORS=()

for shipped in .gaia/script-capabilities.json .gaia/script-capabilities.schema.json; do
  [ -e "$STAGING/$shipped" ] || BOUNDARY_ERRORS+=("missing from staging: $shipped")
done

if [ -e "$STAGING/.gaia/scripts/check-script-capabilities.sh" ]; then
  BOUNDARY_ERRORS+=("leaked into staging: .gaia/scripts/check-script-capabilities.sh")
fi

if [ -e "$STAGING/.gaia/script-capabilities.json" ]; then
  jq empty "$STAGING/.gaia/script-capabilities.json" 2>/dev/null \
    || BOUNDARY_ERRORS+=("staged .gaia/script-capabilities.json is not valid JSON")
fi

if [ "${#BOUNDARY_ERRORS[@]}" -eq 0 ] && [ -e "$STAGING/.gaia/script-capabilities.json" ]; then
  while IFS=$'\t' read -r script mo_type mo_bool; do
    if [ "$mo_type" != boolean ]; then
      BOUNDARY_ERRORS+=("$script: maintainer_only is not a boolean (type=$mo_type)")
      continue
    fi
    if [ "$mo_bool" = true ] && [ -e "$STAGING/$script" ]; then
      BOUNDARY_ERRORS+=("$script: maintainer_only=true but present in staging")
    elif [ "$mo_bool" = false ] && [ ! -e "$STAGING/$script" ]; then
      BOUNDARY_ERRORS+=("$script: maintainer_only=false but absent from staging")
    fi
  done < <(jq -r '.scripts[] | [.script, (.maintainer_only | type), (.maintainer_only | tostring)] | @tsv' "$STAGING/.gaia/script-capabilities.json")
fi

if [ "${#BOUNDARY_ERRORS[@]}" -gt 0 ]; then
  log "script-capabilities distribution boundary violated:"
  for e in ${BOUNDARY_ERRORS[@]+"${BOUNDARY_ERRORS[@]}"}; do log "  $e"; done
  fail "${#BOUNDARY_ERRORS[@]} script-capabilities boundary violation(s)"
  exit 1
fi

pass "manifest, exclude list, sentinels, and script-capabilities boundary all consistent with staging"
