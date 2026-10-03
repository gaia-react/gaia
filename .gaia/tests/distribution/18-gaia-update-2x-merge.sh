#!/usr/bin/env bash
# 18-gaia-update-2x-merge.sh
#
# Adopter-flow regression for a 2.x to 2.x /update-gaia (SPEC-092, COV-010).
# From 2.0.0 the app lives under frontend/, so the update has two package.json
# files to merge and one generated settings file to rebuild:
#
#   1. Step 7a runs once per package.json (root plus each package in
#      .gaia/packages.json). The merge is SKILL prose with an inline jq program,
#      so this scenario extracts that program from merge-execution.md and runs
#      it, instead of re-implementing it: an upstream pin change to the root and
#      to frontend/package.json yields an `apply` verdict, and an adopter
#      re-pin of another key yields `conflict`.
#   2. Step 7e regenerates frontend/.claude/settings.json after the root
#      settings merge. A root settings change that the generated file lacks is
#      drift (the check exits 1); `gaia packages sync-settings` repairs it and
#      the drift check goes clean.
#
# The staged tree is the shipped file set (the same one an adopter extracts),
# so the CLI, the drift script, and the registry are the release's own.
#
# Layer 0.5: runs on the host or runner, no Docker, no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command jq "jq is required to merge package.json files"

STAGING="$(mktemp -d -t gaia-dist-update-2x-stage-XXXXXX)"
WORK="$(mktemp -d -t gaia-dist-update-2x-work-XXXXXX)"
trap 'rm -rf "$STAGING" "$WORK"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

MERGE_EXECUTION="$PROJECT_ROOT/.claude/skills/update-gaia/references/merge-execution.md"
[ -f "$MERGE_EXECUTION" ] \
  || { fail "merge-execution.md is missing from the source tree"; exit 1; }

BASELINE="$WORK/baseline"
ADOPTER="$WORK/adopter"
mkdir -p "$BASELINE" "$ADOPTER"
cp -R "$STAGING/." "$BASELINE/"
cp -R "$STAGING/." "$ADOPTER/"
# An adopter project is a git repository; the CLI resolves the repo root from it.
git -C "$ADOPTER" init -q

capture_cli_stderr "$WORK/cli-stderr.txt"

# The fenced bash block following the first line that starts with $2.
extract_block() {
  awk -v marker="$2" '
    index($0, marker) == 1 { seen = 1; next }
    seen && /^```bash$/ { inside = 1; next }
    seen && inside && /^```$/ { exit }
    seen && inside { print }
  ' "$1"
}

# The first fenced bash block whose first line starts with $2.
extract_block_starting() {
  awk -v marker="$2" '
    /^```bash$/ { buffer = ""; capture = 1; first = 1; next }
    capture && /^```$/ { if (match_found) { printf "%s", buffer; exit } capture = 0; match_found = 0; next }
    capture {
      if (first) { first = 0; if (index($0, marker) == 1) match_found = 1 }
      buffer = buffer $0 "\n"
    }
  ' "$1"
}

# The marker is literal markdown with backticks, not a shell expansion.
# shellcheck disable=SC2016
VERDICT_MARKER='**Compute the per-key verdicts** with `jq`'
VERDICT_BLOCK="$(extract_block "$MERGE_EXECUTION" "$VERDICT_MARKER")"
[ -n "$VERDICT_BLOCK" ] \
  || { fail "could not extract the Step 7a verdict program from merge-execution.md"; exit 1; }
DIRS_BLOCK="$(extract_block_starting "$MERGE_EXECUTION" 'PKG_DIRS=')"
[ -n "$DIRS_BLOCK" ] \
  || { fail "could not extract the Step 7a package-directory list from merge-execution.md"; exit 1; }

# --- Scenario 1: the registry yields the root and frontend ------------------
PKG_DIRS="$(cd "$ADOPTER" && bash -c "$DIRS_BLOCK; printf '%s\n' \"\$PKG_DIRS\"")" \
  || { fail "scenario 1: the PKG_DIRS program failed on the staged registry"; exit 1; }
[ "$PKG_DIRS" = "$(printf '.\nfrontend')" ] \
  || { fail "scenario 1: expected '.' and 'frontend', got: $PKG_DIRS"; exit 1; }
log "scenario 1 (registry yields root and frontend): OK"

# --- Scenario 2: upstream pin changes merge in both package.json files -------
ROOT_KEY="$(jq -r '.devDependencies | keys_unsorted[0]' "$STAGING/package.json")"
FRONTEND_KEY_A="$(jq -r '.devDependencies | keys_unsorted[0]' "$STAGING/frontend/package.json")"
FRONTEND_KEY_B="$(jq -r '.devDependencies | keys_unsorted[1]' "$STAGING/frontend/package.json")"
[ -n "$ROOT_KEY" ] && [ -n "$FRONTEND_KEY_A" ] && [ -n "$FRONTEND_KEY_B" ] \
  || { fail "scenario 2: the staged package.json files have too few devDependencies to stage a merge"; exit 1; }

# Baseline holds an older pin for each key; the staged (latest) tree holds the
# current one. The adopter sits at the baseline pin for ROOT_KEY and
# FRONTEND_KEY_A, and has independently re-pinned FRONTEND_KEY_B.
set_dev_dependency() {
  local file="$1" key="$2" value="$3" scratch
  scratch="$(mktemp "$WORK/pkg-XXXXXX")"
  jq --arg k "$key" --arg v "$value" '.devDependencies[$k] = $v' "$file" > "$scratch"
  mv "$scratch" "$file"
}
set_dev_dependency "$BASELINE/package.json" "$ROOT_KEY" "0.0.1-baseline"
set_dev_dependency "$BASELINE/frontend/package.json" "$FRONTEND_KEY_A" "0.0.1-baseline"
set_dev_dependency "$BASELINE/frontend/package.json" "$FRONTEND_KEY_B" "0.0.2-baseline"
set_dev_dependency "$ADOPTER/package.json" "$ROOT_KEY" "0.0.1-baseline"
set_dev_dependency "$ADOPTER/frontend/package.json" "$FRONTEND_KEY_A" "0.0.1-baseline"
set_dev_dependency "$ADOPTER/frontend/package.json" "$FRONTEND_KEY_B" "9.9.9-adopter"

verdicts_for() {
  (cd "$ADOPTER" && PKG_DIR="$1" BASELINE_DIR="$BASELINE" LATEST_DIR="$STAGING" bash -c "$VERDICT_BLOCK")
}

ROOT_VERDICTS="$(verdicts_for .)" \
  || { fail "scenario 2: the verdict program failed for the root package.json"; exit 1; }
FRONTEND_VERDICTS="$(verdicts_for frontend)" \
  || { fail "scenario 2: the verdict program failed for frontend/package.json"; exit 1; }

verdict_of() {
  printf '%s' "$1" | jq -r --arg k "$2" '[.[] | select(.section == "devDependencies" and .key == $k)][0].verdict // "none"'
}

[ "$(verdict_of "$ROOT_VERDICTS" "$ROOT_KEY")" = "apply" ] \
  || { fail "scenario 2: root $ROOT_KEY should be apply, got $(verdict_of "$ROOT_VERDICTS" "$ROOT_KEY")"; exit 1; }
[ "$(verdict_of "$FRONTEND_VERDICTS" "$FRONTEND_KEY_A")" = "apply" ] \
  || { fail "scenario 2: frontend $FRONTEND_KEY_A should be apply, got $(verdict_of "$FRONTEND_VERDICTS" "$FRONTEND_KEY_A")"; exit 1; }
[ "$(verdict_of "$FRONTEND_VERDICTS" "$FRONTEND_KEY_B")" = "conflict" ] \
  || { fail "scenario 2: frontend $FRONTEND_KEY_B (adopter re-pin) should be conflict, got $(verdict_of "$FRONTEND_VERDICTS" "$FRONTEND_KEY_B")"; exit 1; }
# The root program must not see frontend keys: a package's verdicts stay its own.
[ "$(verdict_of "$ROOT_VERDICTS" "$FRONTEND_KEY_A")" != "apply" ] \
  || { fail "scenario 2: the root verdicts carried a frontend-only change"; exit 1; }
log "scenario 2 (apply and conflict verdicts per package.json): OK"

# --- Scenario 3: generated settings drift, then regenerate -------------------
GENERATED="$ADOPTER/frontend/.claude/settings.json"
[ -f "$GENERATED" ] \
  || { fail "scenario 3: the staged tree ships no frontend/.claude/settings.json"; exit 1; }

# Start drift-clean: what a fresh 2.x scaffold looks like.
bash "$ADOPTER/.gaia/scripts/check-settings-drift.sh" "$ADOPTER" > /dev/null 2>&1 \
  || { fail "scenario 3: the shipped tree is not drift-clean before the update"; exit 1; }

# The Step 7 walk merges a new root deny rule into .claude/settings.json.
NEW_DENY='Edit(zz-new-deny-from-update)'
scratch="$(mktemp "$WORK/settings-XXXXXX")"
jq --arg d "$NEW_DENY" '.permissions.deny += [$d]' "$ADOPTER/.claude/settings.json" > "$scratch"
mv "$scratch" "$ADOPTER/.claude/settings.json"

# Failing state: the generated file lacks the new deny, so the drift check refuses.
if bash "$ADOPTER/.gaia/scripts/check-settings-drift.sh" "$ADOPTER" > /dev/null 2>&1; then
  fail "scenario 3: the drift check passed although the generated settings lack the new root deny"
  exit 1
fi

# Step 7e: regenerate, then the same check goes clean.
(cd "$ADOPTER" && run_cli ./.gaia/cli/gaia packages sync-settings) \
  || fail_with_stderr "scenario 3: gaia packages sync-settings exited non-zero on the staged tree"
bash "$ADOPTER/.gaia/scripts/check-settings-drift.sh" "$ADOPTER" > /dev/null 2>&1 \
  || { fail "scenario 3: the drift check still fails after sync-settings"; exit 1; }
jq -e --arg d "Edit(../zz-new-deny-from-update)" '.permissions.deny | index($d) != null' "$GENERATED" > /dev/null \
  || { fail "scenario 3: the regenerated file lacks the re-anchored new deny"; exit 1; }
log "scenario 3 (settings drift, regenerate, drift-clean): OK"

pass "2.x to 2.x update merges both package.json files and regenerates frontend settings"
