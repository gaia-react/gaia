#!/usr/bin/env bats
# Tests for .gaia/scripts/check-debt-issue-metadata.sh, the filing-time gate over
# a tech-debt issue's label set and dedup key.
#
# Most tests drive `--pre-file`, the blocking mode, which reads no network and
# needs no `gh`. The two advisory modes (`--issue`, `--sweep`) share all of their
# checking with `--pre-file` through `check_labels` / `check_body`, so the
# offline tests cover that logic once for all three.
#
# What the gh modes add on top is transport, and that is covered here through a
# `gh` stub placed on PATH rather than against the real tracker: a stub makes
# the whole surface hermetic and deterministic, including the arms a live
# tracker cannot be made to exhibit on demand (an empty backlog, a `gh` that
# fails), and a live backlog would also be data that changes under the test.
#
# The suite's job is to prove each guard can FAIL. A gate is only worth its
# context if the red case is demonstrated: the green case is already green
# before the gate exists, so a test that only asserts clean-stays-clean asserts
# nothing about the gate. Each check below therefore gets a fixture built to
# trip it, and the exit status plus the emitted finding code are both asserted,
# because a gate that fails for the wrong reason is a gate that will pass for
# the wrong reason later.
#
# Two of the fixtures are the live defects that motivated the gate, kept as
# named tests so the connection survives: an issue filed with no `audience:`
# label, and an issue filed with no dedup key at all.
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
<!-- gaia-debt-origin: branch=main mode=adhoc unit=unknown changed=unknown head=unknown session=unknown -->
`app/services/foo.ts:42`

## Failure mode

A null `userId` reaches this branch and throws.

## Suggested fix

Guard the branch.
EOF
}

# A body that additionally satisfies the `severity:investigate` research block:
# the marker line plus both of its labelled lines, each carrying text.
good_investigate_body() {
  good_body
  cat <<'EOF'

<!-- gaia-investigate: v1 -->
**Question:** does the fail-open branch ever run with a non-empty allowlist?
**Settled by:** a test that drives the branch with an allowlist of one entry.
EOF
}

# The label set a correct graded filing carries.
GOOD_LABELS='tech-debt,severity:important,audience:adopter,footprint:narrow,difficulty:easy'

# The label set an investigate filing carries. No difficulty grade: a filing
# that cannot grade the severity has not read the code closely enough to grade
# the fix either, so the two absences travel together.
INVESTIGATE_LABELS='tech-debt,severity:investigate,audience:adopter,footprint:narrow'

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
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:suggestion,audience:maintainer' --body-file "$BODY"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# audience: the namespace with no prior enforcement at all
# ---------------------------------------------------------------------------

@test "RED, live defect: a filing with no audience: label is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,difficulty:easy' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "audience-count"
}

@test "two audience: labels are rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,audience:maintainer" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "audience-count"
}

@test "a audience: value outside the permitted set is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,audience:internal' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "audience-value"
}

# ---------------------------------------------------------------------------
# severity and difficulty
# ---------------------------------------------------------------------------

@test "a filing with no severity: label is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,audience:adopter' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-count"
}

@test "two severity: labels are rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,severity:critical" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-count"
}

@test "a severity: value outside the permitted set is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:blocker,audience:adopter' --body-file "$BODY"
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
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,audience:adopter,difficulty:trivial' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "difficulty-value"
}

# ---------------------------------------------------------------------------
# severity:investigate and its research block
#
# `investigate` is the one severity value that costs something to pick. Every
# other grade is a judgment the filer already made; this one is the admission
# that they did not, so the gate demands the admission be specific. The failure
# this guards against is the one the dedup key's `class=` field already ran and
# lost: a free "I don't know" value absorbed 91.4% of that axis. A value that
# cannot be picked without writing down WHAT is unknown is not free.
#
# Both directions are checked. The block is required when the grade is present,
# and forbidden when it is not: a block left behind by a re-grade asserts an
# open question that has since been answered, which is worse than no block at
# all because a reader believes it.
# ---------------------------------------------------------------------------

@test "severity:investigate is inside the permitted set" {
  good_investigate_body >"$BODY"
  run bash "$CHECK" --pre-file --labels "$INVESTIGATE_LABELS" --body-file "$BODY"
  [ "$status" -eq 0 ]
  refute_code "severity-value"
}

@test "RED: an investigate filing with no research block is rejected" {
  run bash "$CHECK" --pre-file --labels "$INVESTIGATE_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "missing-investigate-block"
}

@test "RED: an investigate block with an empty Question line is rejected" {
  {
    good_body
    printf '\n<!-- gaia-investigate: v1 -->\n**Question:**\n**Settled by:** a test that drives the branch.\n'
  } >"$BODY"
  run bash "$CHECK" --pre-file --labels "$INVESTIGATE_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "investigate-question"
  # The block itself is present, so the presence check must NOT also fire:
  # two findings for one defect sends the filer to fix the wrong thing.
  refute_code "missing-investigate-block"
}

@test "RED: an investigate block with no Settled by line is rejected" {
  {
    good_body
    printf '\n<!-- gaia-investigate: v1 -->\n**Question:** does the branch ever run?\n'
  } >"$BODY"
  run bash "$CHECK" --pre-file --labels "$INVESTIGATE_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "investigate-settled-by"
}

@test "RED: a second investigate block is rejected" {
  {
    good_investigate_body
    printf '\n<!-- gaia-investigate: v1 -->\n**Question:** a second, contradicting question.\n**Settled by:** something else.\n'
  } >"$BODY"
  run bash "$CHECK" --pre-file --labels "$INVESTIGATE_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "duplicate-investigate-block"
}

@test "RED: a research block on a graded filing is rejected as stray" {
  good_investigate_body >"$BODY"
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "stray-investigate-block"
}

@test "a graded filing with no research block stays clean" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 0 ]
  refute_code "investigate"
}

@test "a CRLF investigate block is not reported as missing" {
  # Same contract as the CRLF dedup-key test below: a body last edited in the
  # web UI arrives with a trailing carriage return on every line, and the
  # end-anchored patterns would reject it without the shared normalization.
  good_investigate_body | sed 's/$/\r/' >"$BODY"
  run bash "$CHECK" --pre-file --labels "$INVESTIGATE_LABELS" --body-file "$BODY"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# footprint: validated when present, never demanded
# ---------------------------------------------------------------------------

@test "a filing with no footprint: label is clean, the human-filed case" {
  # Absence is deliberately not a finding. Nothing downstream depends on the
  # value: the drain re-derives spec-versus-implement from the cited code and
  # grades narrow-versus-wide itself, so demanding presence would demand a value
  # no decision reads, and would make every hand-filed issue a finding.
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,audience:adopter' --body-file "$BODY"
  [ "$status" -eq 0 ]
  refute_code "footprint"
}

@test "each permitted footprint: value is accepted" {
  local v
  for v in narrow wide spec; do
    run bash "$CHECK" --pre-file --labels "tech-debt,severity:important,audience:adopter,footprint:$v" --body-file "$BODY"
    [ "$status" -eq 0 ] || return 1
  done
}

@test "two footprint: labels are rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,footprint:spec" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "footprint-count"
}

@test "a footprint: value outside the permitted set is rejected" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,audience:adopter,footprint:agent' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "footprint-value"
}

@test "RED: an unfilled footprint placeholder is a finding, not a dropped flag" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,audience:adopter,footprint:' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "footprint-value"
  # The count check cannot catch this: `footprint:` is one label, so at-most-one
  # holds and only the value is wrong.
  refute_code "footprint-count"
}

# ---------------------------------------------------------------------------
# fold: validated when present, never demanded
# ---------------------------------------------------------------------------

@test "a filing with no fold: label is clean, the ordinary case" {
  # Absence is the norm rather than an omission: the label marks the minority of
  # findings whose repair rides another change's fixed cost, so demanding it
  # would make every ordinary filing a finding.
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS" --body-file "$BODY"
  [ "$status" -eq 0 ]
  refute_code "fold"
}

@test "fold:required is accepted" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,fold:required" --body-file "$BODY"
  [ "$status" -eq 0 ]
}

@test "two fold: labels are rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,fold:required,fold:required" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "fold-count"
}

@test "a fold: value outside the permitted set is rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,fold:optional" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "fold-value"
}

@test "RED: an unfilled fold placeholder is a finding, not a dropped flag" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,fold:" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "fold-value"
  # The count check cannot catch this: `fold:` is one label, so at-most-one
  # holds and only the value is wrong.
  refute_code "fold-count"
}

# --- the shapes an unquoted value expansion used to let through ------------
#
# Each of these greened the gate before the value loop read its input line-wise.
# They are grouped because they share one cause: a value reached the check as
# shell syntax rather than as data. The empty case is the one a caller actually
# hits, since the recipe substitutes placeholders into this argv.

@test "RED: an empty namespace value is a finding, not an absence" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:,audience:adopter' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-value"
  # The count check cannot catch this: `severity:` is one label, so the count
  # is correct and only the value is wrong.
  refute_code "severity-count"
}

@test "RED: an unfilled difficulty placeholder is a finding, not a dropped flag" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,audience:adopter,difficulty:' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "difficulty-value"
}

@test "RED: two values crammed into one label are rejected, not checked separately" {
  # Both halves are individually legal, so a word-splitting loop passed this.
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,audience:adopter maintainer' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "audience-value"
}

@test "RED: a glob in a label value is reported as one finding, not expanded" {
  run bash "$CHECK" --pre-file --labels 'tech-debt,severity:important,audience:*' --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "audience-value"
  # The bad case: the glob expanded against the working directory and the run
  # reported a finding per repository-root entry instead of one naming the label.
  grep -qF -- "CHANGELOG.md" <<<"$output" && return 1
  grep -qF -- "1 finding(s)" <<<"$output" || return 1
}

@test "a filing with no tech-debt label is rejected" {
  run bash "$CHECK" --pre-file --labels 'severity:important,audience:adopter' --body-file "$BODY"
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

@test "a drain label on a filing is rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,in-progress" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "drain-label-on-new-filing"
}

# The park labels are rejected on the same terms as the claim. Both spellings
# are checked, because the guard names each one literally: a third name added
# to the design but not to the regex fails open, and this is the only place
# that distinction is visible.
@test "either park label on a filing is rejected" {
  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,debt:spec-pending" --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "drain-label-on-new-filing"

  run bash "$CHECK" --pre-file --labels "$GOOD_LABELS,debt:spec-active" --body-file "$BODY"
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
  assert_code "audience-count"
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

@test "--sweep reports an empty backlog rather than reporting a clean check" {
  stub_gh '[]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 0 ]
  grep -qF -- "nothing was checked" <<<"$output" || return 1
}

@test "--sweep applies the shared label and body checks to a live-shaped corpus" {
  stub_gh '[
    {"number":300,
     "labels":[{"name":"tech-debt"},{"name":"severity:important"}],
     "body":"no key here"}
  ]'
  run bash "$CHECK" --sweep
  [ "$status" -eq 1 ]
  assert_code "audience-count"
  assert_code "missing-dedup-key"
}

@test "a CRLF body from the web UI is not reported as a malformed key" {
  # GitHub returns the line endings the client submitted, and a browser textarea
  # submits CRLF, so an issue last edited in the web UI carries a trailing \r.
  # The drain's own capture is unanchored and accepts it; this gate must too.
  stub_gh '[
    {"number":400,
     "labels":[{"name":"tech-debt"},{"name":"severity:important"},{"name":"audience:adopter"}],
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
  stub_gh '[]' '{
    "number":200,
    "labels":[{"name":"tech-debt"},{"name":"severity:important"}],
    "body":"no key here"
  }'
  run bash "$CHECK" --issue 200
  [ "$status" -eq 1 ]
  assert_code "audience-count"
  assert_code "missing-dedup-key"
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

# ---------------------------------------------------------------------------
# --investigate-cap: the bounded queue
#
# The cap is the forcing function. The research block above makes one
# investigate filing honest; the cap is what keeps the grade from becoming a
# graveyard, by rationing it. Over the cap a filing is refused with two exits,
# and both are the outcome the axis wants: drain one of the open ones, or grade
# this finding yourself because the "I do not know" budget is spent.
#
# It reports as an ordinary finding (exit 1) rather than a new exit code, so the
# script keeps its three-way contract: 0 clean, 1 fix something and retry, 2 the
# check did not run.
# ---------------------------------------------------------------------------

@test "--investigate-cap no-ops on a filing that is not investigate-graded, without reading the network" {
  # `stub_gh_failing` is the assertion: a mode that consulted gh here would
  # exit 2, so a clean exit proves the short-circuit happened before the read.
  stub_gh_failing
  run bash "$CHECK" --investigate-cap --labels "$GOOD_LABELS"
  [ "$status" -eq 0 ]
}

@test "--investigate-cap passes an investigate filing while the queue is under the cap" {
  stub_gh '[{"number":11,"title":"one"},{"number":12,"title":"two"}]'
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
  [ "$status" -eq 0 ]
}

@test "RED: --investigate-cap refuses the filing that would exceed the cap, and names the queue" {
  stub_gh '[{"number":11,"title":"one"},{"number":12,"title":"two"},{"number":13,"title":"three"}]'
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
  [ "$status" -eq 1 ]
  assert_code "investigate-cap-reached"
  # The open numbers are the whole point of the refusal: a filer told only
  # "full" has nothing to act on, and the two exits out of the refusal both
  # need the list.
  grep -qF -- "#11" <<<"$output" || return 1
  grep -qF -- "#13" <<<"$output" || return 1
}

@test "RED: --investigate-cap refuses a queue already over the cap" {
  stub_gh '[{"number":11,"title":"one"},{"number":12,"title":"two"},{"number":13,"title":"three"},{"number":14,"title":"four"}]'
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
  [ "$status" -eq 1 ]
  assert_code "investigate-cap-reached"
}

@test "--investigate-cap on a gh failure exits 2, never the findings status" {
  # The caller treats 2 as advisory and files anyway: refusing every filing
  # while GitHub is unreachable loses findings, and a bound that leaks by one
  # on a network blip is still a bound. Exit 2 is what makes that distinction
  # available to the caller at all.
  stub_gh_failing
  run bash "$CHECK" --investigate-cap --labels "$INVESTIGATE_LABELS"
  [ "$status" -eq 2 ]
}

@test "--investigate-cap with no --labels exits 2 rather than reading an empty label set as clean" {
  run bash "$CHECK" --investigate-cap
  [ "$status" -eq 2 ]
}

# --- the marker-stripped (adopter) shape of this script ---------------------
#
# The `audience:` namespace is maintainer-only: its rubric's tie-breaker ("a
# release-excluded path is audience:maintainer") is uncomputable on an adopter
# clone, so the declaration and the enforcement block both sit behind
# `# gaia:maintainer-only` markers and leave the bundle (gaia-react/gaia#1437).
#
# The hazard that wrap creates is a runtime one, not a syntax one. Under
# `set -euo pipefail` a strip that took the `AUDIENCE_VALUES` declaration but
# left its `check_ns_values` reader behind aborts on an unbound variable at the
# FIRST filing, taking the severity, difficulty, footprint, and fold checks down
# with it, and `bash -n` parses that file clean. So these tests strip through
# the real shipped stripper (`gaia-maintainer release scrub`, never a second
# parser written here) and then RUN the result.
#
# Only the stripped shape is tested here. The unstripped half needs nothing new:
# the `audience:` tests above already prove the axis stays mandatory, and
# the wrap changes nothing they read.
#
# Maintainer-only by construction: this suite is release-excluded, and so is
# the `gaia-maintainer` binary it drives. A clone without the binary skips
# rather than fails, so the absence never reads as a passing guard.
#
# require_stripper runs in each @test body rather than inside the helper, and
# that placement is the whole point: bats implements `skip` as `exit 0`, and
# the helper is called as `$(stripped_check)`, so a `skip` there would unwind
# only the substitution subshell. The test would carry on with an empty path
# and die at exit 127 on `bash ""`, which is the opposite of the skip the
# paragraph above promises.
require_stripper() {
  [ -x "$REPO_ROOT/.gaia/cli/gaia-maintainer" ] \
    || skip "maintainer CLI absent; nothing to strip through"
}

# sh_marker_delim <start|end>: echo that delimiter, quotes included, from the
# one marker-strip transform in `.gaia/release-scrub.yml` whose paths cover
# `**/*.sh`, which is the transform that governs the script under test.
sh_marker_delim() {
  awk -v want="$1" '
    /^  - type: / {in_block = ($0 == "  - type: marker-strip"); covers_sh = 0; next}
    !in_block {next}
    $0 == "      - \"**/*.sh\"" {covers_sh = 1; next}
    covers_sh && index($0, "    " want ": ") == 1 {
      sub(/^    [a-z]+: /, "", $0)
      print $0
      exit
    }
  ' "$REPO_ROOT/.gaia/release-scrub.yml"
}

# delim_missing <start|end>: name which delimiter key could not be read, and
# which of the two contracts moved. A literal format string, not the message in
# a variable, so shellcheck reads it as one.
delim_missing() {
  printf 'sh_marker_delim: no `%s:` under the `**/*.sh` marker-strip transform in .gaia/release-scrub.yml; that YAML shape moved, not the strip\n' "$1" >&2
}

# stripped_check: strip the script into a throwaway staging tree and echo the
# stripped path. Call `require_stripper` in the test body first.
stripped_check() {
  local cli="$REPO_ROOT/.gaia/cli/gaia-maintainer"

  local stage="$TMP/stage"
  mkdir -p "$stage/.gaia/scripts"
  cp "$CHECK" "$stage/.gaia/scripts/check-debt-issue-metadata.sh"

  # Only the `**/*.sh` marker-strip transform, so no sibling leak-check can
  # decide this test's outcome. Its delimiters are READ from the shipped config
  # rather than restated: the shipped parser is only half the contract, and a
  # second copy of the spellings would leave this suite stripping and passing
  # against a retired one while the real release strip took nothing out of this
  # script. Asserting the spellings are present somewhere in that file is not
  # enough, because a sibling transform there carries the same two spellings
  # and does not cover `**/*.sh`; the block has to be the one that governs
  # this file.
  local start end
  start="$(sh_marker_delim start)"
  end="$(sh_marker_delim end)"
  # Say which side of the contract moved. The bare `return 1` this replaces
  # surfaced in bats as the caller's `|| return 1` and nothing else, so a
  # shape-preserving edit to that transform (re-quoting the path entry, or
  # ordering `start:`/`end:` ahead of `paths:`) read as an unexplained failure
  # of the strip itself.
  [ -n "$start" ] || { delim_missing start; return 1; }
  [ -n "$end" ] || { delim_missing end; return 1; }

  cat >"$TMP/scrub.yml" <<YAML
transforms:
  - type: marker-strip
    paths:
      - "**/*.sh"
    start: $start
    end: $end
YAML

  "$cli" release scrub "$stage" --config "$TMP/scrub.yml" >/dev/null || return 1
  printf '%s\n' "$stage/.gaia/scripts/check-debt-issue-metadata.sh"
}

@test "the stripped script drops the audience requirement: a filing with no audience: label is clean" {
  require_stripper
  local stripped
  stripped="$(stripped_check)" || return 1

  grep -qF -- 'AUDIENCE_VALUES' "$stripped" && return 1

  run bash "$stripped" --pre-file \
    --labels 'tech-debt,severity:important,footprint:narrow,difficulty:easy' \
    --body-file "$BODY"
  [ "$status" -eq 0 ]
}

@test "the stripped script still RUNS every surviving check rather than aborting on an unbound variable" {
  # The finding CODES are the assertion, not the exit status. An unbound-
  # variable abort also exits non-zero, so a status-only test would green on
  # the exact defect this exists to catch. Each code below is emitted from a
  # line AFTER the stripped block, so seeing all four proves execution reached
  # the end of `check_labels`.
  require_stripper
  local stripped
  stripped="$(stripped_check)" || return 1

  run bash "$stripped" --pre-file \
    --labels 'tech-debt,severity:blocker,difficulty:trivial,footprint:agent,fold:maybe' \
    --body-file "$BODY"
  [ "$status" -eq 1 ]
  assert_code "severity-value"
  assert_code "difficulty-value"
  assert_code "footprint-value"
  assert_code "fold-value"
  refute_code "unbound variable"
}
