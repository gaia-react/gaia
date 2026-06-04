#!/usr/bin/env bash
# version-check.sh: Verify spec-kit's installed version against GAIA's pin.
#
# Usage:
#   version-check.sh [<repo_root>]
#
# When <repo_root> is omitted, $PWD is used. Reads requires.speckit_version
# from <repo_root>/.specify/extensions/gaia/extension.yml and compares it to
# the runtime spec-kit version reported by `specify --version` (or `specify
# version`). Caches the result for the calendar day at
# .gaia/local/cache/version-check.lock to avoid re-running on every hook.
#
# Behavior:
#   - Match: exit 0, no stdout, refresh cache.
#   - Drift: exit 1, clear stderr message naming both versions and the
#            upgrade command.
#   - Tooling problem: exit 1, stderr explains.
#
# Caller (commands/constitution-check.md, fired via the before_specify hook)
# surfaces stderr verbatim to the user and halts.
#
# Pin format: `requires.speckit_version: ">=X.Y.Z[,<X.Y.Z+1.0]"` per the real
# extension schema. `==X.Y.Z` is also accepted (legacy form). The script
# resolves the floor and the optional exclusive ceiling of the specifier set
# and enforces both: drift below the floor *or* at-or-above the ceiling fails.
set -euo pipefail

repo_root="${1:-$PWD}"
extension_yml="$repo_root/.specify/extensions/gaia/extension.yml"

if [ ! -f "$extension_yml" ]; then
  echo "version-check.sh: extension manifest missing at $extension_yml" >&2
  exit 1
fi

# --- Extract pinned version (specifier-set string) ---
pinned_raw="$(grep -E '^[[:space:]]*speckit_version:' "$extension_yml" | head -n 1 || true)"
if [ -z "$pinned_raw" ]; then
  echo "version-check.sh: requires.speckit_version not found in $extension_yml" >&2
  exit 1
fi

# Strip everything up to and including the first colon, surrounding whitespace,
# wrapping quotes.
pinned_spec="${pinned_raw#*:}"
pinned_spec="${pinned_spec// /}"
pinned_spec="${pinned_spec//\"/}"
pinned_spec="${pinned_spec//\'/}"

if [ -z "$pinned_spec" ]; then
  echo "version-check.sh: pinned spec-kit version parses to empty string from $extension_yml" >&2
  exit 1
fi

# Resolve the floor of the specifier set. Accept either `>=X.Y.Z[,<...]` or
# the legacy `==X.Y.Z`.
floor=""
case "$pinned_spec" in
  '>='*)
    floor="${pinned_spec#>=}"
    floor="${floor%%,*}"
    ;;
  '=='*)
    floor="${pinned_spec#==}"
    ;;
  *)
    floor="$pinned_spec"
    ;;
esac
floor="${floor#v}"

if [ -z "$floor" ]; then
  echo "version-check.sh: could not resolve pin floor from '$pinned_spec'" >&2
  exit 1
fi

# Resolve the optional exclusive ceiling (`,<X.Y.Z`). Empty when absent.
ceiling=""
case "$pinned_spec" in
  *,'<'*)
    ceiling="${pinned_spec#*,<}"
    ceiling="${ceiling%%,*}"
    ceiling="${ceiling#v}"
    ;;
esac

# --- Cache short-circuit ---
cache_dir="$repo_root/.gaia/local/cache"
cache_file="$cache_dir/version-check.lock"
today="$(date -u +%Y-%m-%d)"

if [ -f "$cache_file" ]; then
  cached_pin="$(awk -F'"' '/"pinned":/ {print $4; exit}' "$cache_file" 2>/dev/null || echo "")"
  cached_day="$(awk -F'"' '/"day":/ {print $4; exit}' "$cache_file" 2>/dev/null || echo "")"
  if [ "$cached_pin" = "$pinned_spec" ] && [ "$cached_day" = "$today" ]; then
    exit 0
  fi
fi

# --- Resolve runtime spec-kit version ---
installed=""
if command -v specify > /dev/null 2>&1; then
  installed="$(specify --version 2>/dev/null | head -n 1 | awk '{print $NF}' | tr -d '[:space:]' || true)"
  if [ -z "$installed" ]; then
    installed="$(specify version 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  fi
fi

if [ -z "$installed" ]; then
  cat >&2 <<EOF
spec-kit version check failed: could not determine installed version.
  Pinned:    $pinned_spec (from $extension_yml)
  Installed: <unresolved>
  Upgrade:   uvx --from git+https://github.com/github/spec-kit.git@v$floor specify --help
EOF
  exit 1
fi

installed_n="${installed#v}"
floor_n="$floor"

# --- Compare. For exact pins we require equality; for `>=` we require
#     installed >= floor. We do a coarse semver compare via sort -V, which is
#     adequate for the spec-kit release cadence (no pre-release tags). ---
case "$pinned_spec" in
  '=='*)
    if [ "$installed_n" != "$floor_n" ]; then
      cat >&2 <<EOF
spec-kit version drift detected.
  Pinned:    $pinned_spec (exact, from $extension_yml)
  Installed: $installed
  Upgrade:   uvx --from git+https://github.com/github/spec-kit.git@v$floor_n specify --help
EOF
      exit 1
    fi
    ;;
  *)
    lower="$(printf '%s\n%s\n' "$installed_n" "$floor_n" | sort -V | head -n 1)"
    if [ "$lower" != "$floor_n" ]; then
      cat >&2 <<EOF
spec-kit version drift detected.
  Pinned:    $pinned_spec (from $extension_yml)
  Installed: $installed (below pin floor)
  Upgrade:   uvx --from git+https://github.com/github/spec-kit.git@v$floor_n specify --help
EOF
      exit 1
    fi
    if [ -n "$ceiling" ]; then
      below_ceiling="$(printf '%s\n%s\n' "$installed_n" "$ceiling" | sort -V | head -n 1)"
      if [ "$below_ceiling" = "$ceiling" ]; then
        cat >&2 <<EOF
spec-kit version drift detected.
  Pinned:    $pinned_spec (from $extension_yml)
  Installed: $installed (at or above exclusive pin ceiling <$ceiling)
  Upgrade:   uvx --from git+https://github.com/github/spec-kit.git@v$floor_n specify --help
EOF
        exit 1
      fi
    fi
    ;;
esac

# --- Match, refresh cache ---
mkdir -p "$cache_dir"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
cat > "$cache_file" <<EOF
{"pinned":"$pinned_spec","installed":"$installed","day":"$today","verified_at":"$ts"}
EOF

exit 0
