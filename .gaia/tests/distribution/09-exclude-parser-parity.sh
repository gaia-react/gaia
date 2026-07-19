#!/usr/bin/env bash
# SC2016 is intentional file-wide: single-quoted sed program where $ is a regex
# anchor, not a shell variable.
# shellcheck disable=SC2016
# 09-exclude-parser-parity.sh
#
# Regression test for #839 (the #679 remainder): three surfaces
# independently parse `.gaia/release-exclude` and, as of #679, all agree
# (literal paths only, no glob rewriting). Nothing previously proved
# they'd stay in sync. This proves two of the three agree on a small
# fixture: the awk|sed|awk compile stage followed by a `grep -vE` filter
# that release.yml and build-staging.sh both carry, and the literal
# `[ -e ]` presence check in 01-files-present.sh. (The third leg, CLI
# compiler vs the same shell pipeline, is proven in the CLI's own vitest
# suite: .gaia/cli/src/release/exclude-parser-parity.test.ts.)
#
# The pipeline below is a literal copy of build-staging.sh's compile
# stage (lines ~51-53), byte-identity of which against release.yml is
# proven by the vitest test above, not here. Deliberately does not shell
# out to build-staging.sh or the gaia-maintainer binary: this is a fast,
# isolated check of the exclude-filtering logic against a synthetic
# fixture, not a full staging build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd rsync "rsync required for fixture staging"
require_cmd git "git required to build the fixture tracked-file list"

FIXTURE="$(mktemp -d -t gaia-dist-exclude-parity-XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT
SRC="$FIXTURE/src"
STAGING="$FIXTURE/staging"
mkdir -p "$SRC" "$STAGING"

# Fixture tracked-file tree. Covers: a plain excluded file (CHANGELOG.md),
# an excluded directory with children (.gaia/scripts), a `.`-bearing
# excluded literal (wiki/hot.md; proves `.` is escaped, not treated as
# regex any-char), and a `+`-bearing excluded literal (mirrors GAIA's own
# app/routes/_public+/; proves `+` is escaped, not "one-or-more"). Decoys
# (.gaia/scriptsOOPS, wiki/hotXmd, app/keep.ts) share a prefix or a
# near-miss with an excluded pattern and must survive, proving the
# pipeline does not over-exclude.
mkdir -p "$SRC/app" "$SRC/.gaia/scripts" "$SRC/wiki" "$SRC/app/routes/_public+"
touch "$SRC/CHANGELOG.md" \
  "$SRC/app/keep.ts" \
  "$SRC/.gaia/scripts/foo.mjs" \
  "$SRC/.gaia/scripts/bar.mjs" \
  "$SRC/.gaia/scriptsOOPS" \
  "$SRC/wiki/hot.md" \
  "$SRC/wiki/hotXmd" \
  "$SRC/app/routes/_public+/index.tsx"

EXCLUDE_FILE="$FIXTURE/release-exclude"
cat > "$EXCLUDE_FILE" <<'FIXTURE_EOF'
# fixture exclude list for #839 parity test
CHANGELOG.md

.gaia/scripts
wiki/hot.md
app/routes/_public+
FIXTURE_EOF

# Build ALL_TRACKED the same way build-staging.sh does (git ls-files),
# scoped to the fixture tree.
git -C "$SRC" init -q
git -C "$SRC" add -A
ALL_TRACKED="$FIXTURE/all-tracked.txt"
git -C "$SRC" ls-files > "$ALL_TRACKED"

# Phase 1: the compile-and-filter pipeline (literal copy; see header note).
EXCLUDE_REGEX="$FIXTURE/exclude-regex.txt"
awk '/^[[:space:]]*#/ {next} NF==0 {next} {print}' "$EXCLUDE_FILE" \
  | sed 's|[][\\.*^$()+?{}|]|\\&|g' \
  | awk '{print "^"$0"(/|$)"}' \
  > "$EXCLUDE_REGEX"

INCLUDE="$FIXTURE/include.txt"
if [ -s "$EXCLUDE_REGEX" ]; then
  grep -vE -f "$EXCLUDE_REGEX" "$ALL_TRACKED" > "$INCLUDE"
else
  cp "$ALL_TRACKED" "$INCLUDE"
fi

rsync -a --files-from="$INCLUDE" "$SRC/" "$STAGING/"

# Phase 2: the literal `[ -e ]` presence check, same shape as
# 01-files-present.sh's release-exclude leak check.
LEAKED=()
while IFS= read -r raw; do
  case "$raw" in ''|\#*) continue ;; esac
  if [ -e "$STAGING/$raw" ]; then
    LEAKED+=("$raw")
  fi
done < "$EXCLUDE_FILE"

if [ "${#LEAKED[@]}" -gt 0 ]; then
  log "Release-excluded fixture path(s) leaked into staging:"
  for p in "${LEAKED[@]}"; do log "  $p"; done
  fail "${#LEAKED[@]} release-excluded fixture path(s) leaked; pipeline and literal check disagree"
  exit 1
fi

# Decoys must survive: proves the pipeline did not over-exclude.
for decoy in app/keep.ts .gaia/scriptsOOPS wiki/hotXmd; do
  [ -e "$STAGING/$decoy" ] || { fail "decoy fixture path missing from staging: $decoy (pipeline over-excluded)"; exit 1; }
done

# Positive control: prove the literal check can actually catch a leak
# rather than vacuously passing. Reintroduce one excluded path into
# staging (simulating a broken exclusion) and confirm the same check
# flags it.
mkdir -p "$STAGING/.gaia/scripts"
cp "$SRC/.gaia/scripts/foo.mjs" "$STAGING/.gaia/scripts/foo.mjs"

CAUGHT=0
while IFS= read -r raw; do
  case "$raw" in ''|\#*) continue ;; esac
  if [ -e "$STAGING/$raw" ]; then
    if [ "$raw" = ".gaia/scripts" ]; then
      CAUGHT=1
    fi
  fi
done < "$EXCLUDE_FILE"

if [ "$CAUGHT" -ne 1 ]; then
  fail "literal check failed to catch a deliberately reintroduced leak (positive control)"
  exit 1
fi

pass "shell compile-and-filter pipeline and literal presence check agree on the fixture (#839)"
