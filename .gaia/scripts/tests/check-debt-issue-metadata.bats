#!/usr/bin/env bats
# Tests for .gaia/scripts/check-debt-issue-metadata.sh, the filing-time gate over
# a tech-debt issue's label set and dedup key.
#
# Most tests drive `--pre-file`, the blocking mode, which reads no network and
# needs no `gh`. The two advisory modes (`--issue`, `--sweep`) share all of their
# checking with `--pre-file` through `check_labels` / `check_body`, so the
# offline tests cover that logic once for all three.
#
# What the gh modes add on top is transport plus the corpus-calibrated
# anachronism check, and that check is the script's only logic no `--pre-file`
# test reaches. It is covered here through a `gh` stub placed on PATH rather
# than against the real tracker: a stub makes the whole surface hermetic and
# deterministic, including the arms a live tracker cannot be made to exhibit on
# demand (an empty backlog, a corpus with no provenance at all, a `gh` that
# fails). Asserting the anachronism boundary against a live backlog would also
# be asserting against data that changes under the test.
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

@test "two difficulty: labels are rejected" {
  # The zero case is the separate ungraded-filing test above; this one asserts
  # only the two-label half, which is what its name now says.
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,difficulty:hard" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "difficulty-count"
}

@test "a difficulty: value outside the permitted set is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,surface:adopter,difficulty:trivial' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "difficulty-value"
}

# --- the shapes an unquoted value expansion used to let through ------------
#
# Each of these greened the gate before the value loop read its input line-wise.
# They are grouped because they share one cause: a value reached the check as
# shell syntax rather than as data. The empty case is the one a caller actually
# hits, since the recipe substitutes placeholders into this argv.

@test "RED: an empty namespace value is a finding, not an absence" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:,surface:adopter' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-value"
  # The count check cannot catch this: `severity:` is one label, so the count
  # is correct and only the value is wrong.
  refute_code "severity-count"
}

@test "RED: an unfilled difficulty placeholder is a finding, not a dropped flag" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,surface:adopter,difficulty:' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "difficulty-value"
}

@test "RED: two values crammed into one label are rejected, not checked separately" {
  # Both halves are individually legal, so a word-splitting loop passed this.
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,surface:adopter maintainer' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "surface-value"
}

@test "RED: a glob in a label value is reported as one finding, not expanded" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,surface:*' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "surface-value"
  # The bad case: the glob expanded against the working directory and the run
  # reported a finding per repository-root entry instead of one naming the label.
  grep -qF -- "CHANGELOG.md" <<<"$output" && return 1
  grep -qF -- "1 finding(s)" <<<"$output" || return 1
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

@test "RED: a malformed key line is reported even when a valid key stands beside it" {
  # The ladder this replaced stopped at the first arm that held, so a valid key
  # made every later check unreachable. The stray line is not inert: the
  # debt-count refresher collects covered paths with a looser scan than this
  # gate's shape test, so the bogus path would enter that set.
  {
    good_body
    printf '<!-- gaia-debt-key: v1 class=x path=app/bogus.ts line=nope -->\n'
  } >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "malformed-dedup-key"
}

@test "a body carrying only a prose mention of the key has no key, rather than a malformed one" {
  printf 'This issue predates the `<!-- gaia-debt-key: -->` wrapper entirely.\n' >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "missing-dedup-key"
  refute_code "malformed-dedup-key"
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

# ---------------------------------------------------------------------------
# The two advisory gh modes, driven through a stub
#
# `stub_gh <corpus-json> [view-json]` puts a `gh` on PATH ahead of any real one
# and makes it answer `issue list` with <corpus-json> and `issue view` with
# [view-json]. `stub_gh_failing` makes every call exit non-zero, which is how
# the environment-error arm is reached without breaking anyone's auth.
# ---------------------------------------------------------------------------

stub_gh() {
  mkdir -p "$TMP/bin"
  printf '%s\n' "$1" >"$TMP/corpus.json"
  printf '%s\n' "${2:-[]}" >"$TMP/view.json"
  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
# $1 is `issue`, $2 is the subcommand.
case "$2" in
  list) cat "$STUB_DIR/corpus.json" ;;
  view) cat "$STUB_DIR/view.json" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
  export STUB_DIR="$TMP"
  export PATH="$TMP/bin:$PATH"
}

stub_gh_failing() {
  mkdir -p "$TMP/bin"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bin/gh"
  chmod +x "$TMP/bin/gh"
  export PATH="$TMP/bin:$PATH"
}

# One issue carrying provenance, filed early; one carrying the rollout marker,
# filed later. The second is the anachronism.
CORPUS_ANACHRONISM='[
  {"number":100,"createdAt":"2026-08-01T00:00:00Z",
   "labels":[{"name":"tech-debt"},{"name":"severity:important"},{"name":"surface:adopter"}],
   "body":"<!-- gaia-debt-key: v1 class=c path=app/a.ts line=1 -->\n<!-- gaia-debt-origin: branch=main -->"},
  {"number":200,"createdAt":"2026-08-09T00:00:00Z",
   "labels":[{"name":"tech-debt"},{"name":"severity:important"},{"name":"surface:adopter"},{"name":"debt:pre-provenance"}],
   "body":"<!-- gaia-debt-key: v1 class=c path=app/b.ts line=2 -->"}
]'

@test "RED: --sweep flags the rollout marker on an issue filed after provenance began" {
  stub_gh "$CORPUS_ANACHRONISM"
  run bash "$CHECK" --sweep
  [ "$status" -eq 1 ]
  assert_code "pre-provenance-anachronism"
  grep -qF -- "#200" <<<"$output" || return 1
  # The earlier issue legitimately predates nothing and must not be flagged.
  grep -qF -- "#100" <<<"$output" && return 1
  true
}

@test "--sweep leaves the rollout marker alone on an issue filed before provenance began" {
  # Same corpus with the dates swapped: the marked issue is now the older one,
  # which is exactly the cohort the marker exists to name.
  stub_gh '[
    {"number":100,"createdAt":"2026-08-09T00:00:00Z",
     "labels":[{"name":"tech-debt"},{"name":"severity:important"},{"name":"surface:adopter"}],
     "body":"<!-- gaia-debt-key: v1 class=c path=app/a.ts line=1 -->\n<!-- gaia-debt-origin: branch=main -->"},
    {"number":200,"createdAt":"2026-08-01T00:00:00Z",
     "labels":[{"name":"tech-debt"},{"name":"severity:important"},{"name":"surface:adopter"},{"name":"debt:pre-provenance"}],
     "body":"<!-- gaia-debt-key: v1 class=c path=app/b.ts line=2 -->"}
  ]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 0 ]
}

@test "--sweep disables the anachronism check when no issue carries provenance" {
  # No boundary exists, so nothing can be on the wrong side of it. The marker
  # must not be flagged on a repo that has not started writing provenance.
  stub_gh '[
    {"number":200,"createdAt":"2026-08-09T00:00:00Z",
     "labels":[{"name":"tech-debt"},{"name":"severity:important"},{"name":"surface:adopter"},{"name":"debt:pre-provenance"}],
     "body":"<!-- gaia-debt-key: v1 class=c path=app/b.ts line=2 -->"}
  ]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 0 ]
}

@test "--sweep reports an empty backlog rather than reporting a clean check" {
  stub_gh '[]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 0 ]
  grep -qF -- "nothing was checked" <<<"$output" || return 1
}

@test "--sweep applies the shared label and body checks to a live-shaped corpus" {
  stub_gh '[
    {"number":300,"createdAt":"2026-08-09T00:00:00Z",
     "labels":[{"name":"tech-debt"},{"name":"severity:important"}],
     "body":"no key here"}
  ]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 1 ]
  assert_code "surface-count"
  assert_code "missing-dedup-key"
}

@test "a CRLF body from the web UI is not reported as a malformed key" {
  # GitHub returns the line endings the client submitted, and a browser textarea
  # submits CRLF, so an issue last edited in the web UI carries a trailing \r.
  # The drain's own capture is unanchored and accepts it; this gate must too.
  stub_gh '[
    {"number":400,"createdAt":"2026-08-09T00:00:00Z",
     "labels":[{"name":"tech-debt"},{"name":"severity:important"},{"name":"surface:adopter"}],
     "body":"<!-- gaia-debt-key: v1 class=c path=app/a.ts line=1 -->\r\nsome prose\r\n"}
  ]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 0 ]
}

@test "a gh failure exits 2, not the findings status" {
  stub_gh_failing
  run bash "$CHECK" --sweep
  [ "$status" -eq 2 ]
}

@test "--issue reports on a single issue through the same shared checks" {
  stub_gh "$CORPUS_ANACHRONISM" '{
    "number":200,"createdAt":"2026-08-09T00:00:00Z",
    "labels":[{"name":"tech-debt"},{"name":"severity:important"},{"name":"debt:pre-provenance"}],
    "body":"<!-- gaia-debt-key: v1 class=c path=app/b.ts line=2 -->"
  }'
  run bash "$CHECK" --issue 200
  [ "$status" -eq 1 ]
  assert_code "surface-count"
  assert_code "pre-provenance-anachronism"
}

@test "a key line ending in a literal r is malformed, on every platform" {
  # The inverse of the CRLF fixture, and the reason the tolerance is a `tr`
  # rather than a `\r?` in the pattern. That escape is BSD-only: it matches a
  # carriage return on macOS and a literal `r` on Linux, so a pattern carrying
  # it accepts this line on exactly one of the two platforms. Pinning both
  # directions is what makes the platform-independence checkable rather than
  # asserted, since either fixture alone passes under the broken spelling on the
  # platform that happens to agree with it.
  printf '<!-- gaia-debt-key: v1 class=c path=app/a.ts line=1 -->r\n' >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "malformed-dedup-key"
}
