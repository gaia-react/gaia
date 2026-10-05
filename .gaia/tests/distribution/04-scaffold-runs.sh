#!/usr/bin/env bash
# 04-scaffold-runs.sh
#
# Extracts the staged tarball into a tmp dir, runs `pnpm install` and
# the project's own quality gate. End-to-end smoke that the scaffold
# the adopter receives compiles and tests green without further setup.
#
# This is Layer 0; host pnpm available. For Layer 1 (no pnpm on PATH),
# see `05-clean-env.sh` (validates the bootstrap path differently).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command pnpm "pnpm required for scaffold-runs scenario (Layer 0)"

STAGING="$(mktemp -d -t gaia-dist-scaffold-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Drop in a fresh `node_modules` and run the project's own quality gate.
cd "$STAGING"

# `pnpm install` reads packageManager + lockfile from the staged tree.
# `--frozen-lockfile` asserts the lockfile is sufficient; drift would
# fail loudly. The staging tree is post-scrub so the lockfile is the one
# adopters get.
log "pnpm install (this takes a minute)"
if ! pnpm install --frozen-lockfile >/dev/null 2>&1; then
  log "pnpm install failed; rerunning with output for diagnosis:"
  pnpm install --frozen-lockfile || true
  fail "pnpm install failed in staged scaffold"
  exit 1
fi

# Verify the bundled CLI binary is executable from the extracted tree.
if [ ! -x ".gaia/cli/gaia" ]; then
  fail ".gaia/cli/gaia not executable in staging"
  exit 1
fi

# Vitest's browser and storybook projects launch headless Chromium, so install
# it with the staged tree's own Playwright (the version always matches the
# lockfile) before `test:ci`. CI runners also need the OS libraries
# (`--with-deps`); a local run skips them to avoid a sudo prompt.
log "playwright install chromium"
install_chromium() {
  if [ -n "${CI:-}" ]; then
    pnpm -C frontend exec playwright install --with-deps chromium
  else
    pnpm -C frontend exec playwright install chromium
  fi
}
if ! install_chromium >/dev/null 2>&1; then
  log "playwright install failed; rerunning with output:"
  install_chromium || true
  fail "playwright install chromium failed in staged scaffold"
  exit 1
fi

# Project's own quality gate. Each step must succeed; first failure halts.
for step in "typecheck" "lint" "test:ci" "build"; do
  log "pnpm $step"
  if ! pnpm "$step" >/dev/null 2>&1; then
    log "pnpm $step failed; rerunning with output:"
    pnpm "$step" || true
    fail "pnpm $step failed in staged scaffold"
    exit 1
  fi
done

pass "scaffold install + typecheck + lint + test:ci + build all green"
