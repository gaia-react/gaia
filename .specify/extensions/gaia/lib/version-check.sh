#!/usr/bin/env bash
# version-check.sh: Verify spec-kit's installed version against GAIA's pin.
#
# Usage:
#   version-check.sh [<repo_root>]
#
# When <repo_root> is omitted, $PWD is used. Reads requires.speckit_version
# from <repo_root>/.specify/extensions/gaia/extension.yml and compares it to the
# runtime spec-kit version, resolved from a PATH-resident `specify` when one
# exists and otherwise from a uvx-mediated `specify` pinned at the pin floor,
# which is the install route GAIA documents and one that never puts `specify` on
# PATH. Caches the result for the calendar day at
# .gaia/local/cache/version-check.lock so the uvx route resolves once a day
# rather than on every hook.
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

# Read one `"<key>":"<value>"` pair out of the cache. The cache is single-line
# JSON, so every key is scoped by name here; a positional field index would
# resolve each key to the same first value on that one line.
cache_field() {
  sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' "$cache_file" 2>/dev/null | head -n 1
}

if [ -f "$cache_file" ]; then
  cached_pin="$(cache_field pinned || echo "")"
  cached_day="$(cache_field day || echo "")"
  if [ "$cached_pin" = "$pinned_spec" ] && [ "$cached_day" = "$today" ]; then
    exit 0
  fi
fi

# --- Resolve runtime spec-kit version ---
# Two routes, tried in order.
#
# A PATH-resident `specify` (a persistent install: `uv tool install`, pipx) is
# authoritative. Its version is whatever the machine actually carries, so it can
# genuinely drift from the pin, and that is the drift this check exists to catch.
#
# Otherwise fall back to the uvx route. That is the install route GAIA documents
# (`/setup-gaia`, `/gaia-init`) and the only one present on most machines: it is
# uvx-mediated and never puts `specify` on PATH, so without this fallback a
# correctly installed, in-pin spec-kit resolves as <unresolved> and the
# `before_specify` hook blocks /gaia-spec. Note what this route can and cannot
# prove: it names the ref at call time, so the version it reports is the one
# asked for. It confirms the documented route works end to end (uvx present,
# pinned ref fetchable, its self-reported version inside the pin, which catches a
# pin naming a bad ref) rather than detecting a drifting install, which cannot
# happen when every invocation pins the ref.
speckit_ref="git+https://github.com/github/spec-kit.git@v$floor"

installed=""
if command -v specify > /dev/null 2>&1; then
  installed="$(specify --version 2>/dev/null | head -n 1 | awk '{print $NF}' | tr -d '[:space:]' || true)"
  if [ -z "$installed" ]; then
    installed="$(specify version 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  fi
fi

if [ -z "$installed" ] && command -v uvx > /dev/null 2>&1; then
  # This is the one route that touches the network, and it runs inside the check
  # gating the `before_specify` hook, so an unbounded call stalls /gaia-spec on a
  # degraded network (captive portal, slow DNS). Bound it without `timeout(1)`,
  # which macOS does not ship, by setting both sides' own knobs:
  #
  #   - UV_HTTP_TIMEOUT bounds uv's HTTP reads (interpreter and PyPI downloads).
  #   - GIT_HTTP_LOW_SPEED_* bounds the `git+https://` fetch, which uv performs
  #     by shelling out to the system git, out of reach of uv's HTTP timeout.
  #     git aborts a transfer that stays under LIMIT bytes/sec for TIME seconds.
  #
  # Neither is a hard wall-clock cap on the whole invocation; together they cap
  # the stalls that actually strand this call. Operator-set values win.
  export UV_HTTP_TIMEOUT="${UV_HTTP_TIMEOUT:-30}"
  export GIT_HTTP_LOW_SPEED_LIMIT="${GIT_HTTP_LOW_SPEED_LIMIT:-1000}"
  export GIT_HTTP_LOW_SPEED_TIME="${GIT_HTTP_LOW_SPEED_TIME:-30}"

  installed="$(uvx --from "$speckit_ref" specify --version 2>/dev/null | head -n 1 | awk '{print $NF}' | tr -d '[:space:]' || true)"
  # Same second chance the PATH route takes above: a pinned spec-kit exposing
  # only the bare `version` subcommand must resolve here too, not just for the
  # rarer PATH-resident user. The ref is already fetched, so this costs a
  # warm-cache uvx run, not a second network round trip.
  if [ -z "$installed" ]; then
    installed="$(uvx --from "$speckit_ref" specify version 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  fi
fi

if [ -z "$installed" ]; then
  cat >&2 <<EOF
spec-kit version check failed: could not determine installed version.
  Pinned:    $pinned_spec (from $extension_yml)
  Installed: <unresolved>
  Checked:   a PATH-resident \`specify\`, then \`uvx --from $speckit_ref specify\`
  Install:   uvx --from $speckit_ref specify --help
             (uvx ships with uv: https://docs.astral.sh/uv/)
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
