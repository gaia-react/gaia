#!/usr/bin/env bash
# 13-gaia-update-merge-workspace.sh
#
# Adopter-flow regression: runs `gaia update merge-workspace` against the
# bundled CLI binary in a staged release tree. This is the field-aware
# pnpm-workspace.yaml verdict oracle the `/update-gaia` skill invokes
# (Step 7b); `gaia update` had zero bundled-binary coverage before this.
#
# Why it exists: `update` is on every adopter's upgrade path (every
# `/update-gaia` run), so a bundling defect there is maximally load-bearing.
# The oracle parses YAML with a bundled `js-yaml`; an esbuild tree-shake
# that dropped that dependency would throw at runtime on an adopter's very
# next update, and Layers 0+1+2 never invoke `gaia update`.
#
# Read-only: `merge-workspace` never writes the workspace file, it only
# emits a JSON verdict, so no scaffold copy is needed. The three input
# YAML files are synthetic fixtures written to a scratch dir.
#
# Deterministic fixture (managed key `minimumReleaseAge`):
#   baseline 1440, latest 2880, adopter(current) 1440.
#   B and L present, B != L, A present, A == B  ->  verdict "apply".
# So `applied` carries exactly that one key; conflicts and suggestions empty.
#
# Asserts:
#   --json verdict   exit 0; applied=[minimumReleaseAge], conflicts=[], suggestions=[].
#   missing file     exit 1 (workspace_file_missing).
#   --help           exit 0, usage banner on stdout.
#
# Layer 0.5: runs on the host or runner, no Docker. Cheap (~1s after
# build-staging); no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

STAGING="$(mktemp -d -t gaia-dist-update-stage-XXXXXX)"
FIXTURES="$(mktemp -d -t gaia-dist-update-fix-XXXXXX)"
trap 'rm -rf "$STAGING" "$FIXTURES"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

GAIA="$STAGING/.gaia/cli/gaia"
[ -x "$GAIA" ] \
  || { fail "staged tree missing or non-executable .gaia/cli/gaia (bundled CLI)"; exit 1; }

printf 'minimumReleaseAge: 1440\n' > "$FIXTURES/baseline.yaml"
printf 'minimumReleaseAge: 2880\n' > "$FIXTURES/latest.yaml"
printf 'minimumReleaseAge: 1440\n' > "$FIXTURES/current.yaml"

# --- JSON verdict --------------------------------------------------------
VERDICT="$("$GAIA" update merge-workspace \
  --baseline "$FIXTURES/baseline.yaml" \
  --latest "$FIXTURES/latest.yaml" \
  --current "$FIXTURES/current.yaml" \
  --json 2>/dev/null)" || {
  log "gaia update merge-workspace exited non-zero; rerunning with stderr:"
  "$GAIA" update merge-workspace \
    --baseline "$FIXTURES/baseline.yaml" \
    --latest "$FIXTURES/latest.yaml" \
    --current "$FIXTURES/current.yaml" --json || :
  fail "gaia update merge-workspace exited non-zero on staged tree"
  exit 1
}

printf '%s' "$VERDICT" | node -e "
  const r = JSON.parse(require('node:fs').readFileSync(0,'utf8'));
  if (r.applied.length !== 1) throw new Error('expected 1 applied, got ' + r.applied.length);
  if (r.applied[0].key !== 'minimumReleaseAge') throw new Error('expected applied key minimumReleaseAge, got ' + r.applied[0].key);
  if (r.conflicts.length !== 0) throw new Error('expected 0 conflicts, got ' + r.conflicts.length);
  if (r.suggestions.length !== 0) throw new Error('expected 0 suggestions, got ' + r.suggestions.length);
" || { fail "gaia update merge-workspace verdict did not match the expected apply-one-key shape"; exit 1; }

# --- error path: a missing input file exits 1 ----------------------------
if "$GAIA" update merge-workspace \
    --baseline "$FIXTURES/does-not-exist.yaml" \
    --latest "$FIXTURES/latest.yaml" \
    --current "$FIXTURES/current.yaml" >/dev/null 2>&1; then
  fail "gaia update merge-workspace exited 0 on a missing baseline file (expected non-zero)"
  exit 1
fi

# --- help path -----------------------------------------------------------
HELP_OUT="$("$GAIA" update --help)" \
  || { fail "gaia update --help exited non-zero"; exit 1; }
printf '%s' "$HELP_OUT" | grep -q "Usage: gaia update" \
  || { fail "gaia update --help did not print its usage banner"; exit 1; }

pass "gaia update merge-workspace produced the expected verdict, rejected a missing file, and printed help on staged tree"
