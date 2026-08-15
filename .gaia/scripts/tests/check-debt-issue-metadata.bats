#!/usr/bin/env bats
# Tests for .gaia/scripts/check-debt-issue-metadata.sh, the filing-time gate over
# a tech-debt issue's label set and dedup key.
#
# Every test here drives `--pre-file`, the blocking mode, which reads no network
# and needs no `gh`. The two advisory modes (`--issue`, `--sweep`) share all of
# their checking with `--pre-file` through `check_labels` / `check_body`, so
# covering the offline mode covers the logic; what the gh modes add on top is
# transport plus the corpus-calibrated anachronism check, which needs a live
# tracker to be worth asserting against and is verified by hand instead.
#
# The suite's job is to prove each guard can FAIL. A gate is only worth its
# context if the red case is demonstrated: the green case is already green
# before the gate exists, so a test that only asserts clean-stays-clean asserts
# nothing about the gate. Each check below therefore gets a fixture built to
# trip it, and the exit status plus the emitted finding code are both asserted,
# because a gate that fails for the wrong reason is a gate that will pass for
# the wrong reason later.
#
# Three of the fixtures are the live defects that motivated the gate, kept as
# named tests so the connection survives: an issue filed with no `surface:`
# label, an issue filed with no dedup key at all, and an issue filed carrying
# the one-time `debt:pre-provenance` rollout marker.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md. Note the
# `run` idiom throughout, which captures status instead of letting a non-zero
# exit abort the test body; `$status` is then compared with POSIX `[ ]`.

setup() {
  THIS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIR/../../.." && pwd)"
  CHECK="$REPO_ROOT/.gaia/scripts/check-debt-issue-metadata.sh"
  TMP="$(mktemp -d -t debt-issue-metadata-XXXXXX)"
  BODY="$TMP/body.md"
  good_body >"$BODY"
}

teardown() {
  [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# A body that satisfies every body-side check: one well-formed dedup key, a
# provenance line beside it, and the schema's prose parts.
good_body() {
  cat <<'EOF'
<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/services/foo.ts line=42 -->
<!-- gaia-debt-origin: branch=main mode=adhoc unit=unknown changed=unknown head=unknown -->
`app/services/foo.ts:42`

## Failure mode

A null `userId` reaches this branch and throws.

## Suggested fix

Guard the branch.

Handler: prompt
EOF
}

# The label set a correct graded filing carries.
GOOD_LABELS='tech-debt,severity:important,surface:adopter,difficulty:easy'

# assert_code <finding-code>: the run's output names this finding code.
assert_code() {
  grep -qF -- "$1" <<<"$output" || return 1
}

# refute_code <finding-code>: written as a positive match plus an explicit
# `return 1` rather than a `!`-negation, which `set -e` exempts.
refute_code() {
  grep -qF -- "$1" <<<"$output" && return 1
  return 0
}

# ---------------------------------------------------------------------------
# Green baseline
# ---------------------------------------------------------------------------

@test "a correct graded filing is clean" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 0 ]
  assert_code "clean"
}

@test "an ungraded filing is clean: the difficulty label is optional by design" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:suggestion,surface:maintainer' --body-file "$BODY"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# surface: the namespace with no prior enforcement at all
# ---------------------------------------------------------------------------

@test "RED, live defect: a filing with no surface: label is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,difficulty:easy' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "surface-count"
}

@test "two surface: labels are rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,surface:maintainer" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "surface-count"
}

@test "a surface: value outside the permitted set is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,surface:internal' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "surface-value"
}

# ---------------------------------------------------------------------------
# severity and difficulty
# ---------------------------------------------------------------------------

@test "a filing with no severity: label is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,surface:adopter' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-count"
}

@test "two severity: labels are rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,severity:critical" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-count"
}

@test "a severity: value outside the permitted set is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:blocker,surface:adopter' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-value"
}

@test "two difficulty: labels are rejected, while zero is not" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,difficulty:hard" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "difficulty-count"
}

@test "a difficulty: value outside the permitted set is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,surface:adopter,difficulty:trivial' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "difficulty-value"
}

@test "a filing with no tech-debt label is rejected" {
  run bash "$CHECK" --pre-file --labels 'severity:important,surface:adopter' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "missing-tech-debt"
}

# ---------------------------------------------------------------------------
# The dedup key
# ---------------------------------------------------------------------------

@test "RED, live defect: a body with no dedup key is rejected" {
  printf 'a body with prose and no key at all\n' >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "missing-dedup-key"
}

@test "a key with a non-integer line reads as malformed, not as absent" {
  printf '<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/foo.ts line=forty -->\n' >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "malformed-dedup-key"
  refute_code "missing-dedup-key"
}

@test "two dedup keys in one body are rejected" {
  {
    good_body
    printf '<!-- gaia-debt-key: v1 class=holistic/unclassified path=app/bar.ts line=7 -->\n'
  } >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "duplicate-dedup-key"
}

@test "a repository path containing spaces is a valid key path" {
  printf '<!-- gaia-debt-key: v1 class=holistic/unclassified path=wiki/concepts/PR Merge Workflow.md line=175 -->\n' >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 0 ]
}

@test "an absolute key path is rejected, and reported apart from the shape check" {
  printf '<!-- gaia-debt-key: v1 class=holistic/unclassified path=/Users/you/app/foo.ts line=42 -->\n' >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "dedup-key-path"
  refute_code "malformed-dedup-key"
}

@test "a prose mention of the key wrapper beside one real key stays clean" {
  # The shape a correction comment takes when it quotes the key format in
  # running text. The gate counts only whole-line keys, so the prose mention
  # is not a second key.
  {
    good_body
    printf 'Exactly one carries a dedup key, in bare form rather than the `<!-- gaia-debt-key: -->` wrapper.\n'
  } >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Labels that belong to another lifecycle stage
# ---------------------------------------------------------------------------

@test "RED, live defect: debt:pre-provenance on a filing is rejected unconditionally" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,debt:pre-provenance" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "pre-provenance-on-new-filing"
}

@test "a drain label on a filing is rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,debt:in-progress" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "drain-label-on-new-filing"
}

# ---------------------------------------------------------------------------
# Reporting and error handling
# ---------------------------------------------------------------------------

@test "every finding is reported, not just the first" {
  # Also the regression pin for the counter: `finding` increments a variable in
  # the caller's shell, so a check that loops in a subshell would report its
  # findings and lose the count, exiting 0 with findings on stdout.
  printf 'no key at all\n' >"$BODY"
  run bash "$CHECK" --pre-file --labels 'severity:important,severity:critical' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "missing-tech-debt"
  assert_code "severity-count"
  assert_code "surface-count"
  assert_code "missing-dedup-key"
  grep -qF -- "4 finding(s)" <<<"$output" || return 1
}

@test "a usage error exits 2, distinguishable from a finding" {
  run bash "$CHECK"
  [ "$status" -eq 2 ]
}

@test "an unknown argument exits 2" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY" --nonsense
  [ "$status" -eq 2 ]
}

@test "a missing body file exits 2 rather than reporting a clean filing" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$TMP/absent.md"
  [ "$status" -eq 2 ]
}

@test "--pre-file with no --labels exits 2 rather than passing an empty label set" {
  run bash "$CHECK" --pre-file --body-file "$BODY"
  [ "$status" -eq 2 ]
}
