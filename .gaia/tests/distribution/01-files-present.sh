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
#  5. .gaia/hook-capabilities.json and its schema ship; the capability checker
#     itself does not; the staged entry set equals the staged
#     .claude/settings.json's own hook registrations, with
#     distribution-preflight-check.sh absent from both; and every entry
#     marked maintainer_only:false agrees with the hook's presence in staging.
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

for withheld in .gaia/scripts/check-script-capabilities.sh .gaia/scripts/capability-oracle-lib.sh; do
  [ -e "$STAGING/$withheld" ] && BOUNDARY_ERRORS+=("leaked into staging: $withheld")
done

if [ -e "$STAGING/.gaia/script-capabilities.json" ]; then
  jq empty "$STAGING/.gaia/script-capabilities.json" 2>/dev/null \
    || BOUNDARY_ERRORS+=("staged .gaia/script-capabilities.json is not valid JSON")
fi

if [ "${#BOUNDARY_ERRORS[@]}" -eq 0 ] && [ -e "$STAGING/.gaia/script-capabilities.json" ]; then
  # Read jq's status before the loop, not through a process substitution: a
  # staged manifest that parses but carries no `scripts` array makes jq exit
  # non-zero and print nothing, and `set -e` does not see that inside `<( )`.
  # The loop would then run zero times and this block would report a clean
  # reconciliation having reconciled nothing, which is the failure it exists
  # to catch.
  if ! MARKING_ROWS="$(jq -r '.scripts[] | [.script, (.maintainer_only | type), (.maintainer_only | tostring)] | @tsv' "$STAGING/.gaia/script-capabilities.json" 2>/dev/null)"; then
    BOUNDARY_ERRORS+=("staged .gaia/script-capabilities.json has no readable scripts[] array")
    MARKING_ROWS=""
  fi
  while IFS=$'\t' read -r script mo_type mo_bool; do
    [ -n "$script" ] || continue
    if [ "$mo_type" != boolean ]; then
      BOUNDARY_ERRORS+=("$script: maintainer_only is not a boolean (type=$mo_type)")
      continue
    fi
    if [ "$mo_bool" = true ] && [ -e "$STAGING/$script" ]; then
      BOUNDARY_ERRORS+=("$script: maintainer_only=true but present in staging")
    elif [ "$mo_bool" = false ] && [ ! -e "$STAGING/$script" ]; then
      BOUNDARY_ERRORS+=("$script: maintainer_only=false but absent from staging")
    fi
  done <<MARKING
$MARKING_ROWS
MARKING
fi

if [ "${#BOUNDARY_ERRORS[@]}" -gt 0 ]; then
  log "script-capabilities distribution boundary violated:"
  for e in ${BOUNDARY_ERRORS[@]+"${BOUNDARY_ERRORS[@]}"}; do log "  $e"; done
  fail "${#BOUNDARY_ERRORS[@]} script-capabilities boundary violation(s)"
  exit 1
fi

# 5. Hook-capabilities distribution boundary: the manifest and its schema
# ship, the checker that reads them does not, the staged manifest's entry set
# equals the staged .claude/settings.json's own hook registrations (with
# distribution-preflight-check.sh absent from both, each independently
# stripped by the release scrub), and every entry marked maintainer_only:false
# agrees with what actually landed in staging.
HOOKCAP_ERRORS=()

for shipped in .gaia/hook-capabilities.json .gaia/hook-capabilities.schema.json; do
  [ -e "$STAGING/$shipped" ] || HOOKCAP_ERRORS+=("missing from staging: $shipped")
done

[ -e "$STAGING/.gaia/scripts/check-hook-capabilities.sh" ] \
  && HOOKCAP_ERRORS+=("leaked into staging: .gaia/scripts/check-hook-capabilities.sh")

if [ -e "$STAGING/.gaia/hook-capabilities.json" ]; then
  jq empty "$STAGING/.gaia/hook-capabilities.json" 2>/dev/null \
    || HOOKCAP_ERRORS+=("staged .gaia/hook-capabilities.json is not valid JSON")
fi

if [ "${#HOOKCAP_ERRORS[@]}" -eq 0 ] && [ -e "$STAGING/.gaia/hook-capabilities.json" ]; then
  # Read jq's status before the loop, not through a process substitution: a
  # staged manifest that parses but carries no `hooks` array makes jq exit
  # non-zero and print nothing, and `set -e` does not see that inside `<( )`.
  # The loop would then run zero times and this block would report a clean
  # reconciliation having reconciled nothing, which is the failure it exists
  # to catch.
  if ! HOOKCAP_ROWS="$(jq -r '.hooks[] | [.hook, (.maintainer_only | type), (.maintainer_only | tostring)] | @tsv' "$STAGING/.gaia/hook-capabilities.json" 2>/dev/null)"; then
    HOOKCAP_ERRORS+=("staged .gaia/hook-capabilities.json has no readable hooks[] array")
    HOOKCAP_ROWS=""
  fi

  # Assertion 4: the staged entry set equals the hook paths the staged
  # .claude/settings.json registers, with distribution-preflight-check.sh
  # absent from both.
  MANIFEST_HOOKS="$(jq -r '.hooks[]? | .hook // empty' "$STAGING/.gaia/hook-capabilities.json" 2>/dev/null | LC_ALL=C sort -u)"
  REGISTERED_HOOKS="$(jq -r '(.hooks // {}) | to_entries[]? | (.value // [])[]? | (.hooks // [])[]? | .command // empty' "$STAGING/.claude/settings.json" 2>/dev/null | LC_ALL=C sort -u)"

  if [ "$MANIFEST_HOOKS" != "$REGISTERED_HOOKS" ]; then
    HOOKCAP_ERRORS+=("staged hook-capabilities.json entry set != staged settings.json hook registrations")
  fi
  if grep -qxF ".claude/hooks/distribution-preflight-check.sh" <<<"$MANIFEST_HOOKS"; then
    HOOKCAP_ERRORS+=("distribution-preflight-check.sh still present in staged hook-capabilities.json")
  fi
  if grep -qxF ".claude/hooks/distribution-preflight-check.sh" <<<"$REGISTERED_HOOKS"; then
    HOOKCAP_ERRORS+=("distribution-preflight-check.sh still registered in staged settings.json")
  fi

  # Assertion 5, one direction only: every staged entry marked
  # maintainer_only:false is present in staging. Assertion 4 above already
  # removes the sole maintainer_only:true entry from the staged manifest, so
  # the true-direction branch mirroring section 4's MARKING_ROWS loop is
  # unreachable by design here; mirroring both directions would dress a
  # one-direction check as two. The type check stays in both cases, since
  # that can fire regardless.
  while IFS=$'\t' read -r hook mo_type mo_bool; do
    [ -n "$hook" ] || continue
    if [ "$mo_type" != boolean ]; then
      HOOKCAP_ERRORS+=("$hook: maintainer_only is not a boolean (type=$mo_type)")
      continue
    fi
    if [ "$mo_bool" = false ] && [ ! -e "$STAGING/$hook" ]; then
      HOOKCAP_ERRORS+=("$hook: maintainer_only=false but absent from staging")
    fi
  done <<HOOKCAP
$HOOKCAP_ROWS
HOOKCAP
fi

if [ "${#HOOKCAP_ERRORS[@]}" -gt 0 ]; then
  log "hook-capabilities distribution boundary violated:"
  for e in ${HOOKCAP_ERRORS[@]+"${HOOKCAP_ERRORS[@]}"}; do log "  $e"; done
  fail "${#HOOKCAP_ERRORS[@]} hook-capabilities boundary violation(s)"
  exit 1
fi

pass "manifest, exclude list, sentinels, script-capabilities boundary, and hook-capabilities boundary all consistent with staging"
