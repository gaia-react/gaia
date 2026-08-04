#!/usr/bin/env bash
# 17-gaia-update-merge-region.sh
#
# Adopter-flow regression: runs `gaia update merge-region` against the
# bundled CLI binary in a staged release tree. `merge-region` is the
# region-aware verdict oracle the `/update-gaia` skill invokes for a
# declared generated region inside an owned file, masking the region on
# each of the three merge sides so a divergence confined to it never reads
# as adopter drift.
#
# Why it exists: `update merge-region` is on every adopter's upgrade path
# (any release that declares a generated region), and it runs OUT OF THE
# STAGED RELEASE TREE rather than the adopter's already-installed binary
# (the `/update-gaia` skill resolves it as
# "$LATEST_DIR/.gaia/cli/gaia" update merge-region, never the working-tree
# copy, so a run whose installed binary predates the command can still
# reach it). That resolution rule is unobservable at any layer below this
# one: an in-process unit test exercises the same source tree the running
# process was started from, never a downloaded release copy.
#
# Read-only: `merge-region` never writes a file, it only emits a JSON
# verdict, so no scaffold copy is needed beyond the staged binary itself.
# The fixture files are synthetic, written to a scratch dir.
#
# Layer 0.5: runs on the host or runner, no Docker, no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

STAGING="$(mktemp -d -t gaia-dist-update-region-stage-XXXXXX)"
FIXTURES="$(mktemp -d -t gaia-dist-update-region-fix-XXXXXX)"
trap 'rm -rf "$STAGING" "$FIXTURES"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

GAIA="$STAGING/.gaia/cli/gaia"
[ -x "$GAIA" ] \
  || { fail "staged tree missing or non-executable .gaia/cli/gaia (bundled CLI)"; exit 1; }

START_MARKER='<!-- test-region:start -->'
END_MARKER='<!-- test-region:end -->'
PLACEHOLDER='<<<gaia:region>>>'

# Every invocation below that asserts SUCCESS captures the CLI's stderr here
# instead of discarding it, and its failure branch prints what it captured.
# `2>/dev/null` on a success-asserting call leaves the `||` branch with nothing
# to report but the exit code, which is the one fact the branch being taken
# already implies; on a runner nobody is sitting in front of, that costs a local
# reproduction to learn anything at all. Redirecting to a file rather than
# dropping the redirect keeps stdout clean for the JSON the caller parses.
#
# The discriminator is what the scenario asserts, not its number: scenario 7
# asserts FAILURE, so its diagnostic is expected noise and it keeps its own
# suppression.
#
# WHY NOT THE SIBLING IDIOM. Several other scenarios in this directory
# (07, 08, 10, 11, 12, 13, 14) solve the same problem the other way: keep
# `2>/dev/null`, and on failure re-run the identical command unsuppressed for a
# human to read. Capturing to a file is preferred here because it reports the
# bytes the FAILING run actually emitted, where a re-run reports a second,
# different execution: it can succeed, or fail differently, and it doubles the
# work on the one path that is already going wrong. This is also the fix the
# issue itself names. The cost is honest and worth stating: this directory now
# holds two mechanisms for one job and neither lives in `lib/lib.sh`, which is
# filed rather than fixed here, because converging the other seven scenarios is
# not this change's scope.
#
# CALL ORDER IS LOAD-BEARING, which is why `fail_with_stderr` exists rather
# than an inline group at each site. `report_cli_stderr` runs BEFORE `fail`,
# never after: `fail` returns 1 rather than exiting, and the `||` right-hand
# side is the LAST command of its AND-OR list, so `set -e` is NOT suppressed
# there and aborts the script the moment `fail` returns. Anything sequenced
# after `fail` is dead code that never runs, which is how a diagnostic that
# looks present prints nothing. (`fail_with_stderr`'s own trailing `exit 1` is
# unreachable for that reason and is kept as the statement of intent, matching
# every other failure branch in this file.) Verified by driving a real non-zero
# exit through scenario 1, not by reading.
CLI_STDERR="$FIXTURES/cli-stderr.txt"
: > "$CLI_STDERR"

report_cli_stderr() {
  if [ -s "$CLI_STDERR" ]; then
    printf -- '--- gaia stderr ---\n' >&2
    cat "$CLI_STDERR" >&2
    printf -- '--- end gaia stderr ---\n' >&2
  else
    printf -- '(gaia wrote nothing to stderr)\n' >&2
  fi
}

# The one failure branch every success-asserting invocation below uses, so the
# order above is stated once rather than repeated at eight call sites.
fail_with_stderr() {
  report_cli_stderr
  fail "$1"
  exit 1
}

# --- Scenario 1: region-only divergence -----------------------------------
# `current` differs from `baseline` only inside the region; `latest` differs
# from `baseline` only outside it. Masking the region should make the two
# sides read as no-adopter-drift: the adopter's own region edit never
# collides with the outside-region content GAIA changed.
printf 'outside-A\n%s\nregion-baseline-1\nregion-baseline-2\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s1-baseline.txt"
printf 'outside-A-changed\n%s\nregion-baseline-1\nregion-baseline-2\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s1-latest.txt"
printf 'outside-A\n%s\nregion-current-1\nregion-current-2\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s1-current.txt"

S1_JSON="$("$GAIA" update merge-region \
  --baseline "$FIXTURES/s1-baseline.txt" \
  --latest "$FIXTURES/s1-latest.txt" \
  --current "$FIXTURES/s1-current.txt" \
  --start-marker "$START_MARKER" --end-marker "$END_MARKER" \
  --json 2>"$CLI_STDERR")" \
  || fail_with_stderr "scenario 1: gaia update merge-region exited non-zero on staged tree"

printf '%s' "$S1_JSON" | node -e "
  const r = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
  if (r.verdict !== 'no-adopter-drift')
    throw new Error('expected verdict no-adopter-drift, got ' + r.verdict);
  if (r.markers.bailed !== false)
    throw new Error('expected markers.bailed=false, got ' + r.markers.bailed);
  for (const side of ['baseline', 'latest', 'current']) {
    if (r.markers[side].masked !== true)
      throw new Error('expected markers.' + side + '.masked=true, got ' + r.markers[side].masked);
  }
" || { fail "scenario 1 (region-only divergence) did not match the expected no-adopter-drift shape"; exit 1; }
log "scenario 1 (region-only divergence): OK"

# --- Scenario 2: divergence inside and outside the region -----------------
# All three sides differ from each other both inside and outside the region,
# so masking the region alone cannot resolve the outside-region divergence.
printf 'outside-A-baseline\n%s\nregion-baseline\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s2-baseline.txt"
printf 'outside-A-current\n%s\nregion-current\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s2-current.txt"
printf 'outside-A-latest\n%s\nregion-latest\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s2-latest.txt"

S2_JSON="$("$GAIA" update merge-region \
  --baseline "$FIXTURES/s2-baseline.txt" \
  --latest "$FIXTURES/s2-latest.txt" \
  --current "$FIXTURES/s2-current.txt" \
  --start-marker "$START_MARKER" --end-marker "$END_MARKER" \
  --json 2>"$CLI_STDERR")" \
  || fail_with_stderr "scenario 2: gaia update merge-region exited non-zero on staged tree"

printf '%s' "$S2_JSON" | node -e "
  const r = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
  if (r.verdict !== 'conflict')
    throw new Error('expected verdict conflict, got ' + r.verdict);
  const placeholder = '$PLACEHOLDER';
  for (const side of ['current', 'latest']) {
    const body = r.normalized[side];
    if (!body.includes(placeholder))
      throw new Error('expected normalized.' + side + ' to contain the placeholder line');
    for (const leaked of ['region-baseline', 'region-current', 'region-latest']) {
      if (body.includes(leaked))
        throw new Error('normalized.' + side + ' leaked region content: ' + leaked);
    }
  }
" || { fail "scenario 2 (inside and outside divergence) did not match the expected conflict shape"; exit 1; }
log "scenario 2 (divergence inside and outside): OK"

# --- Scenario 3: malformed markers (current side unbalanced) --------------
# `current` carries a start marker with no matching end marker. Any
# malformed side bails the WHOLE comparison: no side is masked, and every
# normalized.* field carries its own raw content unchanged.
printf 'outside-A\n%s\nregion-baseline\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s3-baseline.txt"
printf 'outside-A\n%s\nregion-baseline\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s3-latest.txt"
printf 'outside-A\n%s\nregion-current\noutside-B\n' \
  "$START_MARKER" > "$FIXTURES/s3-current.txt"

S3_JSON="$("$GAIA" update merge-region \
  --baseline "$FIXTURES/s3-baseline.txt" \
  --latest "$FIXTURES/s3-latest.txt" \
  --current "$FIXTURES/s3-current.txt" \
  --start-marker "$START_MARKER" --end-marker "$END_MARKER" \
  --json 2>"$CLI_STDERR")" \
  || fail_with_stderr "scenario 3: gaia update merge-region exited non-zero on staged tree"

# The fixture paths reach node through the ENVIRONMENT, never interpolated by
# the shell into the JS source. `$FIXTURES` derives from `mktemp -d`, so a
# single quote or a backslash in `TMPDIR` would otherwise land inside a JS
# string literal and break the eval with a syntax error that names nothing a
# maintainer can act on. The body is single-quoted for the same reason: with no
# shell expansion into it at all, the property holds by construction rather than
# by every future edit remembering it. Same shape as the sibling probe at
# `.gaia/scripts/tests/region-marker-conformance.bats`.
printf '%s' "$S3_JSON" \
  | GAIA_S3_BASELINE="$FIXTURES/s3-baseline.txt" \
    GAIA_S3_LATEST="$FIXTURES/s3-latest.txt" \
    GAIA_S3_CURRENT="$FIXTURES/s3-current.txt" \
    node -e '
  const fs = require("node:fs");
  const r = JSON.parse(fs.readFileSync(0, "utf8"));
  if (r.markers.bailed !== true)
    throw new Error("expected markers.bailed=true, got " + r.markers.bailed);
  if (r.markers.current.scan !== "malformed")
    throw new Error("expected markers.current.scan=malformed, got " + r.markers.current.scan);
  const raw = {
    baseline: fs.readFileSync(process.env.GAIA_S3_BASELINE, "utf8"),
    latest: fs.readFileSync(process.env.GAIA_S3_LATEST, "utf8"),
    current: fs.readFileSync(process.env.GAIA_S3_CURRENT, "utf8"),
  };
  for (const side of ["baseline", "latest", "current"]) {
    if (r.normalized[side] !== raw[side])
      throw new Error("normalized." + side + " is not byte-identical to its input file");
  }
' || { fail "scenario 3 (malformed markers) did not match the expected global-bail shape"; exit 1; }
log "scenario 3 (malformed markers, global bail): OK"

# --- Scenario 4: absent markers on baseline and current -------------------
# Baseline and current carry no marker pair at all; latest does. An absent
# side is compared unmasked while the other sides are still masked, and its
# `scan` reads 'absent', never 'malformed'.
printf 'no markers here at all\njust plain text\n' > "$FIXTURES/s4-baseline.txt"
printf 'no markers here at all\njust plain text\n' > "$FIXTURES/s4-current.txt"
printf 'outside-A\n%s\nregion-latest\n%s\noutside-B\n' \
  "$START_MARKER" "$END_MARKER" > "$FIXTURES/s4-latest.txt"

S4_JSON="$("$GAIA" update merge-region \
  --baseline "$FIXTURES/s4-baseline.txt" \
  --latest "$FIXTURES/s4-latest.txt" \
  --current "$FIXTURES/s4-current.txt" \
  --start-marker "$START_MARKER" --end-marker "$END_MARKER" \
  --json 2>"$CLI_STDERR")" \
  || fail_with_stderr "scenario 4: gaia update merge-region exited non-zero on staged tree"

printf '%s' "$S4_JSON" | node -e "
  const r = JSON.parse(require('node:fs').readFileSync(0, 'utf8'));
  if (r.markers.bailed !== false)
    throw new Error('expected markers.bailed=false, got ' + r.markers.bailed);
  if (r.markers.baseline.scan !== 'absent')
    throw new Error('expected markers.baseline.scan=absent, got ' + r.markers.baseline.scan);
  if (r.markers.current.scan !== 'absent')
    throw new Error('expected markers.current.scan=absent, got ' + r.markers.current.scan);
" || { fail "scenario 4 (absent markers) did not match the expected per-side shape"; exit 1; }
log "scenario 4 (absent markers, per-side normalization): OK"

# --- Scenario 5: idempotence -----------------------------------------------
# Invoking the same command twice on the same inputs produces byte-identical
# JSON output; `computeRegionMerge` is a pure function of its arguments.
S5_ARGS=(update merge-region \
  --baseline "$FIXTURES/s1-baseline.txt" \
  --latest "$FIXTURES/s1-latest.txt" \
  --current "$FIXTURES/s1-current.txt" \
  --start-marker "$START_MARKER" --end-marker "$END_MARKER" \
  --json)
S5_FIRST="$("$GAIA" "${S5_ARGS[@]}" 2>"$CLI_STDERR")" \
  || fail_with_stderr "scenario 5: first invocation exited non-zero"
S5_SECOND="$("$GAIA" "${S5_ARGS[@]}" 2>"$CLI_STDERR")" \
  || fail_with_stderr "scenario 5: second invocation exited non-zero"
[ "$S5_FIRST" = "$S5_SECOND" ] \
  || { fail "scenario 5 (idempotence): two invocations on the same inputs produced different output"; exit 1; }
log "scenario 5 (idempotence): OK"

# --- Scenario 6: post-update idempotence -----------------------------------
# `current` byte-identical to `latest` simulates the post-update working tree.
# A second `/update-gaia` run cannot reach the merge walk at all once
# `.gaia/VERSION` is bumped, so this is the only layer that can observe a
# re-invocation against the post-update state.
#
# Two independent properties, and the first is why this scenario is not a
# restatement of scenario 5. Scenario 5 establishes that the function is stable
# across two calls on the PRE-update inputs; repeating that on a different set
# of inputs adds no failure mode. What is only observable here is the VERDICT:
# once the working copy equals the release copy, the same three sides resolve to
# `already-latest` rather than to scenario 1's `no-adopter-drift`, which is the
# state every adopter's tree is left in and the one a re-run must recognize.
#
# Scenario 1's baseline and latest are READ here, deliberately: the contrast
# with scenario 1 is the point, same two sides, a different `current`, a
# different verdict. Reading them is also what scenarios 5 and 7 already do.
#
# What this scenario must not do is WRITE one. A `cp` over `s1-current.txt`
# is safe only for as long as nothing below that line reads it for its
# pre-update content, so any scenario later inserted above, or any reordering
# of this file, silently gets post-update content and passes for the wrong
# reason. The post-update state therefore lands in its own `s6-current.txt`
# and every `s1-*` file is left exactly as scenario 1 wrote it.
cp "$FIXTURES/s1-latest.txt" "$FIXTURES/s6-current.txt"

S6_ARGS=(update merge-region \
  --baseline "$FIXTURES/s1-baseline.txt" \
  --latest "$FIXTURES/s1-latest.txt" \
  --current "$FIXTURES/s6-current.txt" \
  --start-marker "$START_MARKER" --end-marker "$END_MARKER" \
  --json)
S6_FIRST="$("$GAIA" "${S6_ARGS[@]}" 2>"$CLI_STDERR")" \
  || fail_with_stderr "scenario 6: first post-update invocation exited non-zero"
S6_SECOND="$("$GAIA" "${S6_ARGS[@]}" 2>"$CLI_STDERR")" \
  || fail_with_stderr "scenario 6: second post-update invocation exited non-zero"

printf '%s' "$S6_FIRST" | node -e '
  const r = JSON.parse(require("node:fs").readFileSync(0, "utf8"));
  if (r.verdict !== "already-latest")
    throw new Error("expected verdict already-latest, got " + r.verdict);
' || { fail "scenario 6: the post-update state did not resolve to already-latest"; exit 1; }

[ "$S6_FIRST" = "$S6_SECOND" ] \
  || { fail "scenario 6 (post-update idempotence): re-invocation was not stable"; exit 1; }
log "scenario 6 (post-update verdict and idempotence): OK"

# --- Scenario 7: error path -------------------------------------------------
if "$GAIA" update merge-region \
    --baseline "$FIXTURES/s1-baseline.txt" \
    --latest "$FIXTURES/s1-latest.txt" \
    --current "$FIXTURES/does-not-exist.txt" \
    --start-marker "$START_MARKER" --end-marker "$END_MARKER" >/dev/null 2>&1; then
  fail "scenario 7: gaia update merge-region exited 0 on a missing --current file (expected non-zero)"
  exit 1
fi
log "scenario 7 (missing --current file exits non-zero): OK"

# --- Scenario 8: help path ---------------------------------------------------
HELP_OUT="$("$GAIA" update --help)" \
  || { fail "scenario 8: gaia update --help exited non-zero"; exit 1; }
printf '%s' "$HELP_OUT" | grep -q "merge-region" \
  || { fail "scenario 8: gaia update --help did not list merge-region"; exit 1; }
printf '%s' "$HELP_OUT" | grep -q "regen-regions" \
  || { fail "scenario 8: gaia update --help did not list regen-regions"; exit 1; }
log "scenario 8 (help lists merge-region and regen-regions): OK"

# --- Scenario 9: release-resolution grep ------------------------------------
# The skill invokes both new subcommands from the DOWNLOADED RELEASE COPY of
# the CLI, never the adopter's already-installed working-tree copy, so a run
# whose installed binary predates them can still reach them.
# This is the grep-assertable half of that rule: the skill carries the
# release-resolved form and carries no working-tree-resolved one.
#
# The two SC2016 disables below are per-line rather than file-wide on purpose.
# Each of these patterns carries a literal `$LATEST_DIR` that is matched as
# text and must not expand, which is exactly what SC2016 reports. Scoping the
# directive to the two lines that earn it keeps the rule live everywhere else,
# and the single-quoted `node -e` body in scenario 3 is why that matters: a
# later edit writing `'$FIXTURES/x'` inside it expecting shell expansion is an
# SC2016 hit worth seeing, and a file-wide disable would swallow it silently.
# shellcheck disable=SC2016
grep -q '"\$LATEST_DIR/\.gaia/cli/gaia" update merge-region' \
  "$PROJECT_ROOT/.claude/skills/update-gaia/SKILL.md" \
  || { fail "scenario 9: SKILL.md is missing the release-resolved merge-region invocation"; exit 1; }
# shellcheck disable=SC2016
grep -q '"\$LATEST_DIR/\.gaia/cli/gaia" update regen-regions' \
  "$PROJECT_ROOT/.claude/skills/update-gaia/SKILL.md" \
  || { fail "scenario 9: SKILL.md is missing the release-resolved regen-regions invocation"; exit 1; }
# Match the invocation whether or not a quote closes the binary path, then
# exclude the release-resolved lines by the root they name. Matching on the
# character before `.gaia` cannot do this job: a quoted working-tree invocation
# puts `"` where the space is expected and goes unseen, and an unquoted
# release-resolved one is preceded by `/`, so it reads as an offender.
if grep -nE '\.gaia/cli/gaia"? update (merge-region|regen-regions)' \
    "$PROJECT_ROOT/.claude/skills/update-gaia/SKILL.md" \
    | grep -qvF 'LATEST_DIR'; then
  fail "scenario 9: SKILL.md carries a working-tree-resolved invocation of merge-region or regen-regions"
  exit 1
fi
log "scenario 9 (release-resolution grep): OK"

pass "gaia update merge-region produced the expected region-aware verdicts, rejected a missing file, printed help, and the skill resolves it from the release copy"
