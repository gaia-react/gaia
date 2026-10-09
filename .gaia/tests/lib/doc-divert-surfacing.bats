#!/usr/bin/env bats
# Doc pins for how a diverted security finding is surfaced and how a transient
# filing is retried. The unit's report carries a count and record paths and no
# finding detail; the main thread's runbook tells the human the count before
# it posts the status and then merges without stopping; the unit re-files each
# retry file every round.
#
# Prose-to-prose only: whether the filing script behaves as the sentences say
# is file-tech-debt.bats's subject. Every presence check has a red twin: a
# scratch copy with the sentence removed must fail the same predicate.
#
# GAIA_AUDIT_LOOP_UNIT_AGENT, GAIA_AUDIT_LOOP_PAGE (the runbook) and
# GAIA_AUDIT_LOOP_ROUNDS (the round procedure) override the paths so a scratch copy can be driven through the same cases.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded, so the UAT ids below are traceability, not shipped prose.

# The pinned sentences carry backticks as literal Markdown.
# shellcheck disable=SC2016

# bats file_tags=whole-tree

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AGENT="${GAIA_AUDIT_LOOP_UNIT_AGENT:-$ROOT/.claude/agents/audit-loop-unit.md}"
  PAGE="${GAIA_AUDIT_LOOP_PAGE:-$ROOT/wiki/concepts/PR Merge Workflow.md}"
  ROUNDS="${GAIA_AUDIT_LOOP_ROUNDS:-$ROOT/wiki/concepts/Audit Round Procedure.md}"
}

# scratch_without <file> <literal>: a copy of <file> with every line carrying
# the literal removed; prints its path.
scratch_without() {
  local scratch_copy_path="$BATS_TEST_TMPDIR/without.md"
  grep -vF -- "$2" "$1" >"$scratch_copy_path"
  printf '%s\n' "$scratch_copy_path"
}

# assert_pinned <file> <literal>: present in the real file, absent from the
# scratch copy that drops it (the red twin).
assert_pinned() {
  grep -qF -- "$2" "$1" || { echo "missing in $1: $2" >&2; return 1; }
  local copy
  copy="$(scratch_without "$1" "$2")"
  grep -qF -- "$2" "$copy" && { echo "red twin did not fail: $2" >&2; return 1; }
  true
}

@test "UAT-038: the unit's report carries diverted_count and diverted_records and no finding detail" {
  assert_pinned "$AGENT" '`diverted_count` (integer), `diverted_records` (array of record paths)'
  assert_pinned "$AGENT" 'The report carries no diverted finding detail (diverts render as a count and record paths only): never a diverted finding'"'"'s key, class, path, title or reason.'
  assert_pinned "$AGENT" 'A diverted finding appears nowhere outside the filing script'"'"'s local record'
}

@test "UAT-038: the runbook surfaces a non-zero diverted count to the human before the status posts, then merges without stopping" {
  assert_pinned "$PAGE" 'surface that count and the `diverted_records` paths to the human before the status is posted, then post and merge without stopping.'
  assert_pinned "$PAGE" 'and nothing about it goes into a PR body, comment or status.'
}

@test "UAT-038: the surfacing sentence sits under Posting the status last" {
  local posting
  posting="$(awk '/^#### Posting the status last$/ {inside_posting=1; next} /^#{3,4} / {inside_posting=0} inside_posting' "$PAGE")"
  [ -n "$posting" ]
  grep -qF -- 'surface that count and the `diverted_records` paths to the human before the status is posted' <<<"$posting"
}

@test "UAT-005: the unit re-files every retry file each round and records filing_pending" {
  assert_pinned "$AGENT" '- Retry pass: run the same command with `--finding <f>` and `--disposition file` once for every file in `<run>/filing-retry/` that an earlier `transient` outcome left, into the same outcome file. Run it every round, whatever the round'"'"'s own filings did.'
  assert_pinned "$AGENT" 'and the files left in `<run>/filing-retry/` into `filing_pending`'
}

@test "UAT-005: the round procedure states a transient filing never blocks the merge and is retried every later round" {
  assert_pinned "$ROUNDS" 'and the `transient` one is retried every later round.'
}
