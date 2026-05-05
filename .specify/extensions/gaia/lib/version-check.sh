#!/usr/bin/env bash
# version-check.sh - Verify spec-kit's installed version matches the GAIA pin.
#
# Reads the JSON hook payload from stdin (or $SPECKIT_HOOK_PAYLOAD), extracts
# requires.speckit_version from .specify/extensions/gaia/extension.yml, and
# compares it to the runtime version (payload.speckit_version, or `specify
# version` as fallback).
#
# Behavior:
#   - Match  -> exit 0, no stdout, refresh cache file with timestamp.
#   - Drift  -> exit non-zero, clear stderr message naming both versions and
#               the upgrade command.
#   - Cache  -> first successful check writes
#               .gaia/local/cache/version-check.lock (timestamped). Subsequent
#               calls within the same wall-clock day reuse the cache and
#               short-circuit (avoids re-running on every hook).
#
# Caller (before_specify.sh) wraps a non-zero exit into
#   {"action": "block", "reason": "<stderr>"}.
#
# UAT: UAT-018.
set -euo pipefail

# --- jq availability ---
if ! command -v jq > /dev/null 2>&1; then
  echo "version-check.sh requires jq; install jq and retry." >&2
  exit 1
fi

# --- Read payload from stdin or env var fallback ---
payload=""
if [ -n "${SPECKIT_HOOK_PAYLOAD:-}" ]; then
  payload="$SPECKIT_HOOK_PAYLOAD"
elif [ ! -t 0 ]; then
  payload="$(cat)"
fi

if [ -z "$payload" ]; then
  echo "version-check.sh: empty payload (expected JSON on stdin or \$SPECKIT_HOOK_PAYLOAD)." >&2
  exit 1
fi

if ! printf '%s' "$payload" | jq -e . > /dev/null 2>&1; then
  echo "version-check.sh: payload is not valid JSON." >&2
  exit 1
fi

cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
runtime_version="$(printf '%s' "$payload" | jq -r '.speckit_version // ""')"

if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  echo "version-check.sh: payload.cwd is missing or not a directory." >&2
  exit 1
fi

extension_yml="$cwd/.specify/extensions/gaia/extension.yml"
if [ ! -f "$extension_yml" ]; then
  echo "version-check.sh: extension manifest missing at .specify/extensions/gaia/extension.yml." >&2
  exit 1
fi

# --- Extract pinned version from extension.yml (no yq dependency) ---
# Match `speckit_version: "==vX.Y.Z"` or `speckit_version: ==vX.Y.Z`. Strip
# quotes and the `==` operator so we are left with the bare version string.
pinned_raw="$(grep -E '^[[:space:]]*speckit_version:' "$extension_yml" | head -n 1 || true)"
if [ -z "$pinned_raw" ]; then
  echo "version-check.sh: requires.speckit_version not found in extension.yml." >&2
  exit 1
fi

pinned="${pinned_raw#*:}"
pinned="${pinned// /}"
pinned="${pinned//\"/}"
pinned="${pinned//\'/}"
pinned="${pinned#==}"

if [ -z "$pinned" ]; then
  echo "version-check.sh: pinned spec-kit version parses to empty string from extension.yml." >&2
  exit 1
fi

# --- Cache short-circuit ---
# Skip re-running if the cache file is from today and matches the pinned version.
cache_dir="$cwd/.gaia/local/cache"
cache_file="$cache_dir/version-check.lock"
today="$(date -u +%Y-%m-%d)"

if [ -f "$cache_file" ]; then
  cached_pin="$(jq -r '.pinned // ""' "$cache_file" 2>/dev/null || echo "")"
  cached_day="$(jq -r '.day // ""' "$cache_file" 2>/dev/null || echo "")"
  if [ "$cached_pin" = "$pinned" ] && [ "$cached_day" = "$today" ]; then
    exit 0
  fi
fi

# --- Resolve runtime version ---
# Prefer payload.speckit_version (the wrapper resolves spec-kit and stamps it
# in). Fall back to `specify version` if the binary is on PATH. If neither
# resolves, treat as drift (cannot verify pin -> block).
installed=""
if [ -n "$runtime_version" ] && [ "$runtime_version" != "null" ]; then
  installed="$runtime_version"
elif command -v specify > /dev/null 2>&1; then
  installed="$(specify version 2> /dev/null | head -n 1 | tr -d '[:space:]' || true)"
fi

if [ -z "$installed" ]; then
  cat >&2 <<EOF
spec-kit version check failed: could not determine installed version.
  Pinned: $pinned (from .specify/extensions/gaia/extension.yml)
  Installed: <unresolved>
  Upgrade: uvx --from git+https://github.com/github/spec-kit.git@$pinned specify --help
EOF
  exit 1
fi

# Normalize: strip a leading `v` from both sides for comparison-friendliness.
norm() { printf '%s' "${1#v}"; }
pinned_n="$(norm "$pinned")"
installed_n="$(norm "$installed")"

if [ "$pinned_n" != "$installed_n" ]; then
  cat >&2 <<EOF
spec-kit version drift detected.
  Pinned:    $pinned (from .specify/extensions/gaia/extension.yml)
  Installed: $installed
  Upgrade:   uvx --from git+https://github.com/github/spec-kit.git@$pinned specify --help
The GAIA extension is pinned lockstep with a specific spec-kit release; aligning versions is required before /gaia spec can run.
EOF
  exit 1
fi

# --- Match - refresh cache ---
mkdir -p "$cache_dir"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
jq -n \
  --arg pinned "$pinned" \
  --arg installed "$installed" \
  --arg day "$today" \
  --arg ts "$ts" \
  '{pinned:$pinned, installed:$installed, day:$day, verified_at:$ts}' \
  > "$cache_file"

exit 0
