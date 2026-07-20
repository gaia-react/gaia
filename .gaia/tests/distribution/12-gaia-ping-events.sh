#!/usr/bin/env bash
# 12-gaia-ping-events.sh
#
# Adopter-flow regression: runs `gaia ping` (all three events plus the
# argument-parsing error and help paths) against the bundled CLI binary in
# a staged release tree. `gaia ping` is the shared adoption-ping entry the
# `/gaia-init`, `/setup-gaia`, and `/update-gaia` skills fire; it had zero
# bundled-binary coverage anywhere before this scenario.
#
# Why it exists: the ping handler and its `postPing` core are bundled into
# the single-file `.gaia/cli/gaia` by esbuild. A bundling defect (a
# tree-shaken module, a broken import that resolves in source but not in
# the bundle) would reach adopters on their very first `/gaia-init`, and no
# test in the release path exercises it. This runs the real bundled binary.
#
# NO NETWORK. Every ping call sets GAIA_TELEMETRY_PING_DISABLE=1, the
# documented suppression switch (`gaia ping --help`): `postPing` returns
# before it reads the project id, the manifest, or opens a socket, so the
# scenario is self-contained and fires no real telemetry.
#
# Asserts:
#   init / setup / update events  exit 0, no stdout (fire-and-forget).
#   --event bogus                 exit 1 (invalid enum).
#   (no --event)                  exit 1 (--event is required).
#   --event init --mode nonsense  exit 1 (invalid field enum).
#   --help                        exit 0, usage banner on stdout.
#
# Layer 0.5: runs on the host or runner, no Docker. Cheap (~1s after
# build-staging); no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

STAGING="$(mktemp -d -t gaia-dist-ping-stage-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

GAIA="$STAGING/.gaia/cli/gaia"
[ -x "$GAIA" ] \
  || { fail "staged tree missing or non-executable .gaia/cli/gaia (bundled CLI)"; exit 1; }

# --- valid events: exit 0, no stdout -------------------------------------
# Run each from inside the staged tree so cwd resolves there, mirroring an
# adopter clone. Suppression short-circuits before any read, so the cwd is
# never actually touched; keeping it faithful anyway.
run_ping_ok() {
  local label="$1"; shift
  local stdout
  stdout="$(cd "$STAGING" && GAIA_TELEMETRY_PING_DISABLE=1 "$GAIA" ping "$@" 2>/dev/null)" || {
    log "gaia ping $* exited non-zero; rerunning with stderr:"
    ( cd "$STAGING" && GAIA_TELEMETRY_PING_DISABLE=1 "$GAIA" ping "$@" ) || :
    fail "gaia ping $* exited non-zero on staged tree (event: $label)"
    exit 1
  }
  if [ -n "$stdout" ]; then
    log "unexpected stdout from ping $label (fire-and-forget: no stdout on success):"
    printf '%s\n' "$stdout" >&2
    fail "gaia ping $label wrote to stdout (contract violation)"
    exit 1
  fi
}

run_ping_ok "init" --event init --mode interactive --i18n 0 --ci ci
run_ping_ok "setup" --event setup --type init --repo create --ci on --audit ci --sandbox on
run_ping_ok "update" --event update --from 1.0.0 --to 1.1.0

# --- error paths: exit 1 -------------------------------------------------
assert_ping_fails() {
  local label="$1"; shift
  if ( cd "$STAGING" && GAIA_TELEMETRY_PING_DISABLE=1 "$GAIA" ping "$@" >/dev/null 2>&1 ); then
    fail "gaia ping $label exited 0 but a non-zero arg-parse failure was expected"
    exit 1
  fi
}

assert_ping_fails "invalid --event" --event bogus
assert_ping_fails "missing --event" --mode interactive
assert_ping_fails "invalid field enum" --event init --mode nonsense

# --- help path -----------------------------------------------------------
HELP_OUT="$(cd "$STAGING" && "$GAIA" ping --help)" \
  || { fail "gaia ping --help exited non-zero"; exit 1; }
printf '%s' "$HELP_OUT" | grep -q "Usage: gaia ping" \
  || { fail "gaia ping --help did not print its usage banner"; exit 1; }

pass "gaia ping fired all three events (suppressed), rejected malformed args, and printed help on staged tree"
