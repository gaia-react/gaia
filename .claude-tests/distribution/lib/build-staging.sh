#!/usr/bin/env bash
# Build a release-staging tree from the source repo into <output-dir>.
# Pure replication of `.github/workflows/release.yml` Stage + Scrub +
# Runtime-deps phases. Read-only on the source repo.
#
# Usage: build-staging.sh <output-dir>
#
# Exit codes:
#   0 — staged tree clean (scrub passed, runtime-deps passed)
#   1 — bad usage, missing binary, scrub leak, runtime-deps leak
#   2 — unexpected (rsync/git failure, IO error)
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <output-dir>\n' "$0" >&2
  exit 1
fi
OUTPUT_DIR="$1"
PROJECT_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"

# Sanity: <output-dir> must exist and be empty.
if [ ! -d "$OUTPUT_DIR" ]; then
  printf 'Output dir does not exist: %s\n' "$OUTPUT_DIR" >&2
  exit 1
fi
if [ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]; then
  printf 'Output dir not empty: %s\n' "$OUTPUT_DIR" >&2
  exit 1
fi

# Sanity: bundled CLI binary must exist. Maintainer runs
# `pnpm -C .gaia/cli bundle` if stale; we don't rebuild here.
if [ ! -x "$PROJECT_ROOT/.gaia/cli/gaia" ]; then
  printf 'Bundled CLI binary missing or not executable: %s/.gaia/cli/gaia\n' "$PROJECT_ROOT" >&2
  printf 'Run `pnpm -C .gaia/cli bundle` first.\n' >&2
  exit 1
fi

# Phase 1 — Stage. Mirror release.yml lines 56-77.
SCRATCH="$(mktemp -d -t gaia-dist-stage-XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
ALL_TRACKED="$SCRATCH/all-tracked.txt"
EXCLUDE_REGEX="$SCRATCH/exclude-regex.txt"
INCLUDE="$SCRATCH/include.txt"

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

rsync -a --files-from="$INCLUDE" "$PROJECT_ROOT/" "$OUTPUT_DIR/"

# Phase 2 — Scrub. Same invocation as release.yml line 82.
"$PROJECT_ROOT/.gaia/cli/gaia" release scrub "$OUTPUT_DIR"

# Phase 3 — Runtime-deps. Same invocation as release.yml line 87.
"$PROJECT_ROOT/.gaia/cli/gaia" release runtime-deps --staging "$OUTPUT_DIR"
