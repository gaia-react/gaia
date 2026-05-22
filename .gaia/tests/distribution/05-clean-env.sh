#!/usr/bin/env bash
# 05-clean-env.sh
#
# Layer 1 isolation: validates the create-gaia bootstrapper survives in
# a PATH-stripped environment with no pnpm/uv/claude pre-installed.
#
# What this DOES test:
#   - Tarball extraction works without dev tools.
#   - Corepack-driven pnpm bootstrap (the path adopters hit on first
#     run) succeeds.
#   - `pnpm install --frozen-lockfile` works after corepack provisions
#     pnpm.
#
# What this does NOT test:
#   - /gaia-init or /setup-cloned-gaia-project execution (would need Claude — see
#     `diagnostic/claude-auth-in-docker.md`).
#   - Full filesystem isolation (a true Docker run is the answer; deferred).
#   - Linux-only adopter environments (the host OS is what it is).
#
# Skipped automatically if `corepack` is not on PATH — the bootstrap path
# is unverifiable without it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

if ! command -v corepack >/dev/null 2>&1; then
  log "corepack not on PATH; skipping (Node 16.13+ ships corepack)"
  pass "corepack unavailable — scenario skipped (Node ships corepack since v16.13)"
  exit 0
fi

# We need a populated staging tree to extract; reuse the build helper
# in the OUTER environment (PATH-stripping happens for the bootstrap
# step, not the staging step — staging needs git/tar/rsync/jq/the CLI
# binary, all of which Layer 0 maintainers have).
STAGING="$(mktemp -d -t gaia-dist-cleanenv-stage-XXXXXX)"
SCAFFOLD="$(mktemp -d -t gaia-dist-cleanenv-scaffold-XXXXXX)"
FAKE_HOME="$(mktemp -d -t gaia-dist-cleanenv-home-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCAFFOLD" "$FAKE_HOME"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Tar the staged tree, then extract into SCAFFOLD — same shape as
# create-gaia's download+extract step. Bypasses the actual GitHub fetch
# (we have the staging dir locally).
TARBALL="$(mktemp -t gaia-dist-cleanenv-tar.XXXXXX).tar.gz"
trap 'rm -rf "$STAGING" "$SCAFFOLD" "$FAKE_HOME" "$TARBALL"' EXIT
tar -czf "$TARBALL" -C "$STAGING" .

# Resolve the corepack and node paths in the OUTER PATH (we'll stash
# them so the inner subshell can still find them — the test isn't about
# hiding Node itself, just dev tools the adopter wouldn't have).
NODE_BIN="$(command -v node)"
COREPACK_BIN="$(command -v corepack)"
TAR_BIN="$(command -v tar)"
GIT_BIN="$(command -v git)"
[ -n "$NODE_BIN" ]     || { fail "node unavailable on outer PATH"; exit 1; }
[ -n "$COREPACK_BIN" ] || { fail "corepack unavailable on outer PATH"; exit 1; }

# Run the bootstrap in a subshell with stripped PATH and isolated HOME.
# PATH includes only system binaries plus the directories holding node /
# corepack / tar / git that we resolved above. Nothing from
# /usr/local/bin or homebrew, so any pnpm/uv/claude on the maintainer's
# machine becomes invisible.
mkdir -p "$FAKE_HOME/bin"
ln -s "$NODE_BIN"     "$FAKE_HOME/bin/node"
ln -s "$COREPACK_BIN" "$FAKE_HOME/bin/corepack"
ln -s "$TAR_BIN"      "$FAKE_HOME/bin/tar"
ln -s "$GIT_BIN"      "$FAKE_HOME/bin/git"

(
  unset PNPM_HOME UV_HOME npm_config_prefix
  export HOME="$FAKE_HOME"
  export PATH="/usr/bin:/bin:$FAKE_HOME/bin"

  # Confirm pnpm is NOT visible — this is the test invariant.
  if command -v pnpm >/dev/null 2>&1; then
    printf 'pnpm IS visible in stripped subshell — PATH-strip failed\n' >&2
    exit 1
  fi

  cd "$SCAFFOLD"
  tar -xzf "$TARBALL" --strip-components=0 -C .
  git init --quiet --initial-branch=main
  git config user.email "test@example.com"
  git config user.name "Distribution Test"
  git config commit.gpgsign false
  git add . >/dev/null 2>&1

  # Mirror create-gaia's ensurePnpm() — corepack first, npm install -g
  # fallback. Only test the corepack path here (the npm fallback would
  # mutate the host's global npm, which we don't want in a test).
  corepack enable pnpm

  # Now pnpm should be visible (provisioned by corepack into ~/.local/...).
  command -v pnpm >/dev/null 2>&1 \
    || { printf 'corepack did not provision pnpm into PATH\n' >&2; exit 1; }

  pnpm --version >/dev/null
  pnpm install --frozen-lockfile >/dev/null 2>&1
)

pass "clean-env bootstrap (PATH-strip + corepack pnpm provision) succeeded"
