#!/usr/bin/env bash
# 07-gaia-init-strip-branding.sh
#
# Adopter-flow regression: runs `gaia init strip-branding --title <T>`
# against a writable copy of the staged release tree. The staged tree is
# what an adopter receives via `npx create-gaia`; this scenario asserts
# the bundled CLI binary actually executes its first user-facing step on
# that tree.
#
# Why it exists: 06-claude-runs-staged.sh proves Claude can talk to
# Anthropic from a Linux container, but does NOT prove the shipped CLI
# works on a tree adopters receive. If release-exclude strips a file
# strip-branding needs (e.g. .gaia/templates/README.md), Layers 0+1+2
# stay green and only this scenario fails.
#
# Asserts (post-conditions of strip-branding --title "Test Project"):
#   - Exit code 0, no stdout (per the subcommand contract).
#   - README.md exists at scaffold root and contains "Test Project"
#     (regenerated from .gaia/templates/README.md, which ships).
#
# Layer 0.5: runs on the host or runner, no Docker. Cheap (~1s after
# build-staging); no pnpm install, just file-level transforms.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd rsync "rsync required for adopter-flow scaffold copy"

STAGING="$(mktemp -d -t gaia-dist-init-stage-XXXXXX)"
SCAFFOLD="$(mktemp -d -t gaia-dist-init-scaffold-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCAFFOLD"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Copy staging into a writable scaffold (strip-branding mutates files).
rsync -a "$STAGING"/ "$SCAFFOLD"/

# Pre-conditions on the staged tree. Each check is something
# release-exclude guarantees; if any fails, release-exclude has drifted
# and strip-branding will fail downstream.
[ -f "$SCAFFOLD/.gaia/templates/README.md" ] \
  || { fail "staged tree missing .gaia/templates/README.md (strip-branding template source)"; exit 1; }
if [ -f "$SCAFFOLD/README.md" ]; then
  log "warning: README.md already in scaffold; release-exclude category 11 may have drifted"
fi
[ -x "$SCAFFOLD/.gaia/cli/gaia" ] \
  || { fail "staged tree missing or non-executable .gaia/cli/gaia (bundled CLI)"; exit 1; }

# Run strip-branding from inside $SCAFFOLD via a subshell so the CLI's
# default `process.cwd()` resolves there. The parent scenario keeps its
# own pwd; never `cd "$SCAFFOLD"` at scenario scope, since other
# scenarios sourced or invoked from `run-all.sh` may rely on $PWD.
TITLE="Test Project"
STDOUT="$(cd "$SCAFFOLD" && "$SCAFFOLD/.gaia/cli/gaia" init strip-branding --title "$TITLE" 2>/dev/null)" || {
  # Re-run with stderr unsuppressed for diagnosis. The `fail; exit 1`
  # below runs unconditionally; the diagnostic re-run's exit code is
  # intentionally ignored (`|| :`).
  log "gaia init strip-branding exited non-zero; rerunning with stderr:"
  ( cd "$SCAFFOLD" && "$SCAFFOLD/.gaia/cli/gaia" init strip-branding --title "$TITLE" ) || :
  fail "gaia init strip-branding exited non-zero on staged tree"
  exit 1
}

if [ -n "$STDOUT" ]; then
  log "unexpected stdout from strip-branding (contract: no stdout on success):"
  printf '%s\n' "$STDOUT" >&2
  fail "gaia init strip-branding wrote to stdout (contract violation)"
  exit 1
fi

# Post-condition assertions.
[ -f "$SCAFFOLD/README.md" ] \
  || { fail "strip-branding did not create README.md from .gaia/templates/README.md"; exit 1; }

grep -q "$TITLE" "$SCAFFOLD/README.md" \
  || { fail "strip-branding did not substitute '$TITLE' into README.md"; exit 1; }

pass "gaia init strip-branding produced expected post-conditions on staged tree"
