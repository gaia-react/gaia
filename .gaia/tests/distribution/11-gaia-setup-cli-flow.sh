#!/usr/bin/env bash
# 11-gaia-setup-cli-flow.sh
#
# Adopter-flow regression: runs the `gaia setup` subcommand family
# (mark-step -> status -> finalize -> link-worktree), the CLI primitives
# behind `/setup-gaia`, against a writable copy of the staged release
# tree. `gaia setup-ci` is out of scope here: its subcommands shell out to
# `gh` and the network (check-admin, enable-delete-branch, detect-remote),
# which this self-contained harness does not exercise.
#
# Why it exists: `gaia setup` is pure git + local-state logic (no shipped
# template dependency), so this scenario's value is different from
# 07/08/10: it proves the real bundled binary's `setup` subcommands still
# produce correct post-conditions against a scrubbed, staged tree, not
# just against source (already covered by setup.test.ts). Layers 0+1+2
# never invoke `gaia setup`, so a regression here (e.g. a scrub rule that
# mangles the CLI's own compiled logic) would otherwise reach a release
# undetected.
#
# Asserts (post-conditions per step):
#   status (before)   complete=false, all 6 steps pending, started_at=null.
#   mark-step (x6)     each call exits 0.
#   status (mid)       complete=false (completed_at still unset), 0 pending.
#   finalize           exits 0, completed_at is a non-null string.
#   status (after)     complete=true.
#   link-worktree      on a main checkout (not a linked worktree):
#                      is_worktree=false, actions=[], env_actions=[].
#
# Layer 0.5: runs on the host or runner, no Docker. Cheap (~1s after
# build-staging); file-level transforms only, no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_cmd rsync "rsync required for adopter-flow scaffold copy"

STAGING="$(mktemp -d -t gaia-dist-setup-stage-XXXXXX)"
SCAFFOLD="$(mktemp -d -t gaia-dist-setup-scaffold-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCAFFOLD"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Copy staging into a writable scaffold (setup mutates .gaia/local/).
rsync -a "$STAGING"/ "$SCAFFOLD"/
GAIA="$SCAFFOLD/.gaia/cli/gaia"

[ -x "$GAIA" ] \
  || { fail "staged tree missing or non-executable .gaia/cli/gaia (bundled CLI)"; exit 1; }

# `gaia setup` resolves the repo root via `git rev-parse --git-common-dir`
# (setup/util/state-file.ts); the staged tree carries no `.git` (git
# ls-files never lists it), so a real adopter clone is mirrored by
# initializing one here. No commit is needed: --git-common-dir only
# requires the `.git` directory to exist.
git -C "$SCAFFOLD" init -q

run_setup() {
  local label="$1"; shift
  local stdout
  stdout="$(cd "$SCAFFOLD" && "$GAIA" setup "$@" 2>/dev/null)" || {
    log "gaia setup $* exited non-zero; rerunning with stderr:"
    ( cd "$SCAFFOLD" && "$GAIA" setup "$@" ) || :
    fail "gaia setup $* exited non-zero on staged tree (step: $label)"
    exit 1
  }
  printf '%s' "$stdout"
}

json_field() {
  # $1: JSON on stdin's field name via node (avoids a jq dependency).
  node -e "console.log(JSON.stringify(JSON.parse(require('node:fs').readFileSync(0,'utf8'))['$1']))"
}

# --- status (before any step is recorded) -------------------------------
STATUS_BEFORE="$(run_setup "status (before)" status --json)"
[ "$(printf '%s' "$STATUS_BEFORE" | json_field complete)" = "false" ] \
  || { fail "status --json before mark-step: expected complete=false"; exit 1; }
[ "$(printf '%s' "$STATUS_BEFORE" | json_field started_at)" = "null" ] \
  || { fail "status --json before mark-step: expected started_at=null"; exit 1; }
[ "$(printf '%s' "$STATUS_BEFORE" | json_field pending_steps | node -e "process.stdout.write(String(JSON.parse(require('node:fs').readFileSync(0,'utf8')).length))")" = "6" ] \
  || { fail "status --json before mark-step: expected 6 pending_steps"; exit 1; }

# --- mark-step, one call per canonical step (state-file.ts SETUP_STEPS) --
for step in install-tools install-plugins init-speckit chmod-statusline bootstrap-env audit-mode-decision; do
  run_setup "mark-step $step" mark-step "$step" >/dev/null
done

# --- status (all steps recorded, not yet finalized) ---------------------
STATUS_MID="$(run_setup "status (mid)" status --json)"
[ "$(printf '%s' "$STATUS_MID" | json_field complete)" = "false" ] \
  || { fail "status --json after mark-step: expected complete=false (finalize not yet run)"; exit 1; }
[ "$(printf '%s' "$STATUS_MID" | json_field pending_steps | node -e "process.stdout.write(String(JSON.parse(require('node:fs').readFileSync(0,'utf8')).length))")" = "0" ] \
  || { fail "status --json after mark-step: expected 0 pending_steps"; exit 1; }

# --- finalize -------------------------------------------------------------
FINALIZE_OUT="$(run_setup "finalize" finalize)"
printf '%s' "$FINALIZE_OUT" | node -e "
  const out = JSON.parse(require('node:fs').readFileSync(0,'utf8'));
  if (out.code !== 'setup_finalized') throw new Error('unexpected code: ' + out.code);
  if (typeof out.completed_at !== 'string') throw new Error('completed_at not a string');
" || { fail "gaia setup finalize did not produce the expected setup_finalized payload"; exit 1; }

# --- status (after finalize) ---------------------------------------------
STATUS_AFTER="$(run_setup "status (after)" status --json)"
[ "$(printf '%s' "$STATUS_AFTER" | json_field complete)" = "true" ] \
  || { fail "status --json after finalize: expected complete=true"; exit 1; }

# --- link-worktree (main checkout, not a linked worktree) ----------------
LINK_OUT="$(run_setup "link-worktree" link-worktree --json)"
printf '%s' "$LINK_OUT" | node -e "
  const out = JSON.parse(require('node:fs').readFileSync(0,'utf8'));
  if (out.is_worktree !== false) throw new Error('expected is_worktree=false on a main checkout');
  if (out.actions.length !== 0) throw new Error('expected actions=[] on a main checkout');
  if (out.env_actions.length !== 0) throw new Error('expected env_actions=[] on a main checkout');
" || { fail "gaia setup link-worktree did not produce the expected main-checkout payload"; exit 1; }

pass "gaia setup mark-step/status/finalize/link-worktree produced expected post-conditions on staged tree"
