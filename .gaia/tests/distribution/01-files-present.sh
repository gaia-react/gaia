#!/usr/bin/env bash
# 01-files-present.sh
#
# Asserts the staged tarball matches the manifest contract:
#  1. Every path in .gaia/manifest.json files{} exists in the staging tree.
#  2. Every path in .gaia/release-exclude is ABSENT from the staging tree.
#  3. Adopter-owned sentinels (wiki/log.md, .gaia/VERSION,
#     .gaia/manifest.json) exist and contain release-baseline content
#     (not maintainer dev content).
#  4. .gaia/scripts/check-hook-scope-manifest.sh ships and passes against the
#     staged tree, so running it by hand on an adopter clone does not red on
#     a release-excluded hook the staging step already stripped.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command jq "jq required for manifest parsing; install via 'brew install jq'"
require_command rsync "rsync required for staging build"

STAGING="$(mktemp -d -t gaia-dist-presence-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# 1. Every manifest path exists in staging.
MISSING=()
while IFS= read -r entry_path; do
  [ -e "$STAGING/$entry_path" ] || MISSING+=("$entry_path")
done < <(jq -r '.files | keys[]' "$STAGING/.gaia/manifest.json")

if [ "${#MISSING[@]}" -gt 0 ]; then
  log "Manifest claims paths missing from staging tree:"
  for entry_path in ${MISSING[@]+"${MISSING[@]}"}; do log "  $entry_path"; done
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
  release_exclude_path="$raw"
  if [ -e "$STAGING/$release_exclude_path" ]; then
    LEAKED+=("$release_exclude_path")
  fi
done < "$PROJECT_ROOT/.gaia/release-exclude"

if [ "${#LEAKED[@]}" -gt 0 ]; then
  log "Release-excluded paths present in staging tree:"
  for entry_path in ${LEAKED[@]+"${LEAKED[@]}"}; do log "  $entry_path"; done
  fail "${#LEAKED[@]} release-excluded path(s) leaked into staging"
  exit 1
fi

# 3. Adopter-owned sentinels present with release-baseline content.
for sentinel in wiki/log.md .gaia/VERSION .gaia/manifest.json; do
  [ -e "$STAGING/$sentinel" ] || { fail "sentinel missing: $sentinel"; exit 1; }
done

# .gaia/VERSION should be a single line ending with a newline,
# matching the package.json `version` field.
PACKAGE_VERSION="$(jq -r '.version' "$STAGING/package.json")"
FILE_VERSION="$(tr -d '[:space:]' < "$STAGING/.gaia/VERSION")"
[ "$PACKAGE_VERSION" = "$FILE_VERSION" ] \
  || { fail ".gaia/VERSION ($FILE_VERSION) != package.json version ($PACKAGE_VERSION)"; exit 1; }

# wiki/log.md should carry the release-marker string
# that `gaia-maintainer release scrub-wiki` writes (Step 8 + 9 of
# `/gaia-release`).
# Asserting on the actual rendered content is stricter than a line-count
# proxy; it catches "scrub-wiki didn't run" AND "scrub-wiki wrote the
# wrong version". The marker shape is pinned to scrub-wiki.ts:renderLogMd.
grep -qF "## [v$PACKAGE_VERSION]" "$STAGING/wiki/log.md" \
  || { fail "wiki/log.md missing '## [v$PACKAGE_VERSION]' release marker; scrub-wiki did not run or wrote a wrong version"; exit 1; }

# 4. Hook-scope check, run the way an adopter runs it: the staged copy
# against the staged tree. It scans every staged hook for a bare .gaia/local
# literal, so a release-excluded hook left out of staging cannot fail it, and
# a staged hook reaching .gaia/local without a resolved root does.
HOOKSCOPE_CHECKER=".gaia/scripts/check-hook-scope-manifest.sh"
if [ ! -e "$STAGING/$HOOKSCOPE_CHECKER" ]; then
  fail "missing from staging: $HOOKSCOPE_CHECKER"
  exit 1
fi
if ! HOOKSCOPE_OUTPUT="$(bash "$STAGING/$HOOKSCOPE_CHECKER" "$STAGING" 2>&1)"; then
  log "hook-scope check fails against the staged tree:"
  log "$HOOKSCOPE_OUTPUT"
  fail "staged $HOOKSCOPE_CHECKER reds on the staged tree"
  exit 1
fi

pass "manifest, exclude list, sentinels, and hook-scope check all consistent with staging"
