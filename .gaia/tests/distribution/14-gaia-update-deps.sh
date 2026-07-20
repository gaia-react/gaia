#!/usr/bin/env bash
# 14-gaia-update-deps.sh
#
# Adopter-flow regression: runs `gaia update-deps` against the bundled CLI
# binary in a staged release tree. `gaia update-deps` mutates an adopter's
# tree (the local snooze ledger) and had zero bundled-binary coverage.
#
# Why it exists: the same bundling-defect risk as `gaia update` (both are
# on the upgrade path, both bundled by esbuild into `.gaia/cli/gaia`).
#
# What is and is NOT exercised here, and why:
#   - `decline` is the deterministic, side-effect-free post-condition. It
#     reads a synthetic emitted-updates payload and writes only the
#     gitignored `.gaia/local/declined-updates.json` inside a throwaway
#     scaffold copy, so it exercises the real bundled decline path
#     (declines.ts + groups.ts) with no network and nothing durable.
#   - `run --emit-updates` is exercised only at the arg-parse/dispatch
#     level (missing-flag -> exit 1). Its success path shells out to
#     `pnpm outdated --json` and `pnpm view` against the registry, which is
#     network-dependent and non-deterministic, so it is deliberately not
#     driven end-to-end in this self-contained harness.
#
# Asserts:
#   decline --source --skip react-router  exit 0; stdout snoozed=[react-router];
#                                          ledger file written.
#   decline --clear                        exit 0; stdout {"cleared":true}; ledger written.
#   decline --skip foo (no --source)       exit 1 (--source is required).
#   run (no --emit-updates)                exit 1 (arg parse; no pnpm/network).
#   --help                                 exit 0, usage banner on stdout.
#
# Layer 0.5: runs on the host or runner, no Docker. Cheap (~1s after
# build-staging); no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd rsync "rsync required for adopter-flow scaffold copy"

STAGING="$(mktemp -d -t gaia-dist-udeps-stage-XXXXXX)"
SCAFFOLD="$(mktemp -d -t gaia-dist-udeps-scaffold-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCAFFOLD"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Copy staging into a writable scaffold (decline writes .gaia/local/).
rsync -a "$STAGING"/ "$SCAFFOLD"/
GAIA="$SCAFFOLD/.gaia/cli/gaia"
[ -x "$GAIA" ] \
  || { fail "staged tree missing or non-executable .gaia/cli/gaia (bundled CLI)"; exit 1; }

# Synthetic emitted-updates payload: one Wave A group (`react-router`) with a
# genuine upgrade, so `--skip react-router` resolves an outstanding group.
cat > "$SCAFFOLD/updates.json" <<'JSON'
{
  "schema_version": 1,
  "wave_a": [
    {"name": "react-router", "group": "react-router", "current": "7.0.0", "latest": "7.1.0", "wanted": "7.1.0", "kind": "minor", "bucket": "minor", "is_pinned": false}
  ],
  "wave_b": []
}
JSON

LEDGER="$SCAFFOLD/.gaia/local/declined-updates.json"

# --- decline --source --skip --------------------------------------------
DECLINE_OUT="$(cd "$SCAFFOLD" && "$GAIA" update-deps decline --source updates.json --skip react-router 2>/dev/null)" || {
  log "gaia update-deps decline exited non-zero; rerunning with stderr:"
  ( cd "$SCAFFOLD" && "$GAIA" update-deps decline --source updates.json --skip react-router ) || :
  fail "gaia update-deps decline exited non-zero on staged tree"
  exit 1
}
printf '%s' "$DECLINE_OUT" | node -e "
  const r = JSON.parse(require('node:fs').readFileSync(0,'utf8'));
  if (!Array.isArray(r.snoozed) || !r.snoozed.includes('react-router')) {
    throw new Error('expected snoozed to include react-router, got ' + JSON.stringify(r.snoozed));
  }
" || { fail "gaia update-deps decline did not report react-router snoozed"; exit 1; }
[ -f "$LEDGER" ] \
  || { fail "gaia update-deps decline did not write .gaia/local/declined-updates.json"; exit 1; }

# --- decline --clear -----------------------------------------------------
CLEAR_OUT="$(cd "$SCAFFOLD" && "$GAIA" update-deps decline --clear 2>/dev/null)" \
  || { fail "gaia update-deps decline --clear exited non-zero"; exit 1; }
printf '%s' "$CLEAR_OUT" | node -e "
  const r = JSON.parse(require('node:fs').readFileSync(0,'utf8'));
  if (r.cleared !== true) throw new Error('expected {cleared:true}, got ' + JSON.stringify(r));
" || { fail "gaia update-deps decline --clear did not report cleared:true"; exit 1; }
[ -f "$LEDGER" ] \
  || { fail "gaia update-deps decline --clear did not write the (emptied) ledger"; exit 1; }

# --- error paths: exit 1 (no network reached) ----------------------------
if ( cd "$SCAFFOLD" && "$GAIA" update-deps decline --skip foo >/dev/null 2>&1 ); then
  fail "gaia update-deps decline --skip without --source exited 0 (expected non-zero)"
  exit 1
fi
if ( cd "$SCAFFOLD" && "$GAIA" update-deps run >/dev/null 2>&1 ); then
  fail "gaia update-deps run without --emit-updates exited 0 (expected non-zero arg-parse failure)"
  exit 1
fi

# --- help path -----------------------------------------------------------
HELP_OUT="$("$GAIA" update-deps --help)" \
  || { fail "gaia update-deps --help exited non-zero"; exit 1; }
printf '%s' "$HELP_OUT" | grep -q "Usage: gaia update-deps" \
  || { fail "gaia update-deps --help did not print its usage banner"; exit 1; }

pass "gaia update-deps decline snoozed and cleared a group, rejected malformed args, and printed help on staged tree"
