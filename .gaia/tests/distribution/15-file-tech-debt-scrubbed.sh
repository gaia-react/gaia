#!/usr/bin/env bash
# 15-file-tech-debt-scrubbed.sh
#
# Marker-strip SEMANTIC coverage: exercises a marker-bearing, adopter-facing
# skill (`file-tech-debt`) against the bundle-SCRUBBED staging tree and
# asserts the scrubbed prose is still complete enough for an adopter-side
# agent to finish the recipe. 03-marker-strip.sh proves the markers are
# gone STRUCTURALLY (no fragments survive, every marker-bearing file
# shrank, none to zero bytes); it does NOT prove a load-bearing STEP did
# not sit inside a stripped block. This scenario closes that gap for the
# sharpest case: `file-tech-debt` is a recipe an adopter agent follows
# literally, and it carries a `gaia:maintainer-only` block.
#
# `/gaia-wiki lint` was the other candidate but does NOT exercise this gap:
# the `gaia-wiki` skill files staged for it carry ZERO markers, so scrubbed
# == unscrubbed there. `file-tech-debt` is the only adopter-facing skill
# whose scrubbed shape actually differs.
#
# TWO parts, deliberately split:
#
#   1. DETERMINISTIC, side-effect-free, GATING (always runs, no Docker):
#      on the scrubbed skill, assert the maintainer-only block is gone AND
#      the load-bearing adopter steps survived. If a future scrub over-
#      strips (removes a step the adopter path needs), this fails at PR
#      time, which is exactly the release-time-only gap #899 closes. This
#      is the checkable, side-effect-free post-condition; it gates.
#
#   2. ADVISORY model probe (Docker + CLAUDE_CODE_OAUTH_TOKEN gated, NEVER
#      gates): drive `claude --print` in the container against the scrubbed
#      tree to reproduce the dedup key from the scrubbed skill text, and log
#      whether it succeeded. Like the wiki-sync scenarios this depends on
#      free-form model output, so it is observational only: a miss logs a
#      warning and the scenario still passes. The scenario's exit code is
#      governed solely by part 1.
#
# NO EXTERNAL SIDE EFFECTS. `file-tech-debt` normally files a real GitHub
# issue via `gh`. This scenario never reaches that sink: (a) the probe
# prompt instructs the model to answer from the skill text and stop before
# any `gh` command; (b) the Layer-2 image has no `gh` binary and no GitHub
# auth, so a create is not possible; (c) docker.sh bind-mounts the staged
# tree READ-ONLY, so no write to the tree is possible either.
#
# Note on the deviation from a pure "gate the whole scenario behind
# Docker+token" shape: a deterministic, Docker-free, side-effect-free
# semantic-survival assertion exists, so it is used as the gate and runs in
# every lane (PR included). The free-form model drive stays Docker+token-
# gated and strictly advisory, matching the wiki-sync non-gating posture.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/docker.sh"

SKILL_REL=".claude/skills/file-tech-debt/SKILL.md"

STAGING="$(mktemp -d -t gaia-dist-ftd-stage-XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

SCRUBBED="$STAGING/$SKILL_REL"
SOURCE="$PROJECT_ROOT/$SKILL_REL"
[ -f "$SCRUBBED" ] \
  || { fail "scrubbed tree missing $SKILL_REL (release-exclude drift?)"; exit 1; }

# --- Part 1: deterministic semantic-survival (GATING) --------------------

# The maintainer-only block must be gone. Its sole content is a
# contract-note test-path line naming release-excluded .gaia/tests/ paths;
# leaving it would also trip the scrub's own maintainer-paths leak-check.
if grep -qF 'gaia:maintainer-only' "$SCRUBBED"; then
  fail "scrubbed $SKILL_REL still contains a gaia:maintainer-only marker"
  exit 1
fi
if grep -qF 'debt-sentinel-touch.bats' "$SCRUBBED"; then
  fail "scrubbed $SKILL_REL still contains the stripped maintainer-only test-path line"
  exit 1
fi

# A block was actually removed from THIS file: scrubbed strictly smaller.
src_bytes="$(wc -c < "$SOURCE")"
scr_bytes="$(wc -c < "$SCRUBBED")"
[ "$scr_bytes" -lt "$src_bytes" ] \
  || { fail "scrubbed $SKILL_REL ($scr_bytes B) not smaller than source ($src_bytes B); marker block not stripped"; exit 1; }

# The load-bearing adopter steps must SURVIVE the strip. Each literal below
# lives OUTSIDE the maintainer-only block and is load-bearing for the
# adopter path: an agent that reaches this recipe with any of these missing
# could not build the key, run the dedup check, or make the file/skip
# decision.
assert_survives() {
  grep -qF "$1" "$SCRUBBED" \
    || { fail "scrubbed $SKILL_REL lost a load-bearing step: missing \"$1\""; exit 1; }
}
assert_survives 'gaia-debt-key: v1 class='                 # step 1: dedup-key format
assert_survives '## 2. Check for an existing match (dedup)' # step 2: dedup check
assert_survives '## 3. Idempotency: skip if a match exists' # step 3: skip-if-match
assert_survives 'stop, do not file'                         # step 3: the skip instruction
assert_survives 'wontfix'                                   # step 2: declined-closed condition
assert_survives '## 4. Otherwise, file the issue'           # step 4: file path

# --- Part 2: advisory model probe (Docker + token; NEVER gates) ----------

if ! docker_available; then
  log "docker daemon not reachable; advisory model probe skipped (deterministic checks above passed)"
  pass "scrubbed file-tech-debt skill kept every load-bearing step (advisory model probe skipped: no Docker)"
  exit 0
fi
if ! docker_token_available; then
  log "CLAUDE_CODE_OAUTH_TOKEN unset; advisory model probe skipped (deterministic checks above passed)"
  pass "scrubbed file-tech-debt skill kept every load-bearing step (advisory model probe skipped: no Claude auth)"
  exit 0
fi

if ! docker_build_image; then
  log "advisory model probe skipped: docker build failed (deterministic checks above passed)"
  pass "scrubbed file-tech-debt skill kept every load-bearing step (advisory model probe skipped: docker build failed)"
  exit 0
fi

# Drive the model against the scrubbed tree. It must build the dedup key for
# a synthetic finding using ONLY the scrubbed skill text, and stop before any
# sink. `gh` is absent from the image and the mount is read-only, so no issue
# can be filed regardless of what the model does.
PROMPT="Read the file ${SKILL_REL} in this repo. Do NOT run any commands or tools, and do NOT create any GitHub issue; answer only from that file's text. Following step 1 of that skill, build the single dedup-key HTML comment line for this finding: class=holistic/unclassified, path=app/foo.ts, line=42. Output exactly that one line, then on the next line write the two conditions under which the skill says you must NOT file the issue."

RESPONSE="$(docker_run_claude "$STAGING" --print "$PROMPT" 2>/dev/null || true)"

if printf '%s' "$RESPONSE" | grep -qF 'gaia-debt-key: v1' \
   && printf '%s' "$RESPONSE" | grep -qF 'path=app/foo.ts' \
   && printf '%s' "$RESPONSE" | grep -qF 'line=42'; then
  log "advisory: model reproduced a well-formed dedup key from the scrubbed skill; post-scrub prose is followable"
else
  log "advisory WARNING: model did not reproduce a well-formed dedup key from the scrubbed skill (free-form output; non-gating). Response follows:"
  printf '%s\n' "$RESPONSE" >&2
fi

pass "scrubbed file-tech-debt skill kept every load-bearing step; advisory model probe ran against the scrubbed tree"
