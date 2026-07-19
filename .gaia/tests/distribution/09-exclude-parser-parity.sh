#!/usr/bin/env bash
# SC2016 is intentional file-wide: the independent reference oracle is a
# single-quoted sed program where $ is a regex anchor, not a shell variable.
# shellcheck disable=SC2016
# 09-exclude-parser-parity.sh
#
# Regression guard for #839 (the #679 remainder): the maintainer CLI is the
# single compiler of .gaia/release-exclude into anchored regexes. This proves
# that compiler's output is byte-identical to an INDEPENDENT reference
# awk|sed|awk pipeline kept here as the oracle (the only surviving second
# implementation, in a test), and that a staging tree filtered by the CLI's
# output leaks no release-excluded path.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd rsync "rsync required for fixture staging"
require_cmd git "git required to build the fixture tracked-file list"

CLI="$PROJECT_ROOT/.gaia/cli/gaia-maintainer"
if [ ! -x "$CLI" ]; then
  fail "maintainer CLI binary missing or not executable: $CLI (run 'pnpm -C .gaia/cli bundle')"
  exit 1
fi

FIXTURE="$(mktemp -d -t gaia-dist-exclude-parity-XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT
SRC="$FIXTURE/src"
STAGING="$FIXTURE/staging"
mkdir -p "$SRC" "$STAGING"

# Fixture tracked-file tree. Covers: a plain excluded file (CHANGELOG.md), an
# excluded directory with children (.gaia/scripts), a `.`-bearing excluded
# literal (wiki/hot.md; proves `.` is escaped, not regex any-char), and a
# `+`-bearing excluded literal (mirrors GAIA's own app/routes/_public+/; proves
# `+` is escaped, not "one-or-more"). Decoys (.gaia/scriptsOOPS, wiki/hotXmd,
# app/keep.ts) share a prefix or near-miss with an excluded pattern and must
# survive, proving the pipeline does not over-exclude.
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

# Build ALL_TRACKED the same way build-staging.sh does (git ls-files), scoped
# to the fixture tree.
git -C "$SRC" init -q
git -C "$SRC" add -A
ALL_TRACKED="$FIXTURE/all-tracked.txt"
git -C "$SRC" ls-files > "$ALL_TRACKED"

# The shared compiler: the single production source every executable surface
# now invokes. Fail-closed.
CLI_REGEX="$FIXTURE/cli-regex.txt"
if ! "$CLI" release exclude-regex --exclude-file "$EXCLUDE_FILE" > "$CLI_REGEX"; then
  fail "release exclude-regex compile failed on fixture"
  exit 1
fi

# The INDEPENDENT reference oracle: a byte-for-byte copy of the retired
# awk|sed|awk compile, kept here purely to check the shared compiler against.
# Never invoked in production; this is the sole surviving second implementation.
REF_REGEX="$FIXTURE/ref-regex.txt"
awk '/^[[:space:]]*#/ {next} NF==0 {next} {print}' "$EXCLUDE_FILE" \
  | sed 's|[][\\.*^$()+?{}|]|\\&|g' \
  | awk '{print "^"$0"(/|$)"}' \
  > "$REF_REGEX"

# Byte-equality: the shared compiler must equal the independent reference,
# character for character, not merely produce a set-equivalent exclusion.
if ! cmp -s "$CLI_REGEX" "$REF_REGEX"; then
  log "CLI exclude-regex output differs from the independent reference pipeline:"
  diff "$REF_REGEX" "$CLI_REGEX" >&2 || true
  fail "CLI compiler and reference oracle disagree byte-for-byte (#839)"
  exit 1
fi

# Filter the tracked set through the SHARED compiler's output, then stage, so
# the leak check below exercises the real CLI output, not the reference.
INCLUDE="$FIXTURE/include.txt"
if [ -s "$CLI_REGEX" ]; then
  grep -vE -f "$CLI_REGEX" "$ALL_TRACKED" > "$INCLUDE"
else
  cp "$ALL_TRACKED" "$INCLUDE"
fi

rsync -a --files-from="$INCLUDE" "$SRC/" "$STAGING/"

# Leak backstop: every release-excluded fixture path must be ABSENT from
# staging (same shape as 01-files-present.sh's `[ -e ]` check).
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
  fail "${#LEAKED[@]} release-excluded fixture path(s) leaked; CLI compiler and literal check disagree"
  exit 1
fi

# Decoys must survive: proves the pipeline did not over-exclude.
for decoy in app/keep.ts .gaia/scriptsOOPS wiki/hotXmd; do
  [ -e "$STAGING/$decoy" ] || { fail "decoy fixture path missing from staging: $decoy (over-excluded)"; exit 1; }
done

# Positive control: prove the literal check can actually catch a leak rather
# than vacuously passing. Reintroduce one excluded path and confirm it flags.
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

# Fail-closed negative control (UAT-003): a non-literal-path offender must make
# the shared compiler exit nonzero AND emit no stdout, so the `if ! <cli> …;
# then abort` guard every executable staging path uses aborts loudly instead of
# taking the `[ -s ]` copy-everything branch. This exercises the failed-compile
# scenario through the exact shared-compiler invocation the staging surfaces use
# (build-staging.sh hardcodes the real exclude file, so the injectable failure
# is proven here against the same CLI + fail-closed contract).
BAD_EXCLUDE="$FIXTURE/bad-release-exclude"
printf 'app/*\n' > "$BAD_EXCLUDE"
BAD_REGEX="$FIXTURE/bad-regex.txt"
if "$CLI" release exclude-regex --exclude-file "$BAD_EXCLUDE" > "$BAD_REGEX" 2>/dev/null; then
  fail "release exclude-regex accepted a glob metacharacter; fail-closed contract broken"
  exit 1
fi
if [ -s "$BAD_REGEX" ]; then
  fail "release exclude-regex emitted output on a rejected input (copy-everything leak risk)"
  exit 1
fi

pass "CLI compiler matches the independent reference, the staged tree has no leaks, and a bad compile fails closed (#839)"
