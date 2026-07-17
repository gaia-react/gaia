#!/usr/bin/env bats
#
# UAT-007: cost-consolidate.sh is retired. This suite asserts the file is
# gone and that no tracked file still references it (a scoped, allowlisted
# git grep), plus SC5's archived-absent half: cost-backfill.sh still no-ops
# safely when neither archived/ tree exists.
#
# DP-001: `.gaia/manifest.json` legitimately still lists cost-consolidate.sh
# until `/gaia-release` regenerates it (release-generated, FC-7 forbids
# editing it here), so it is excluded from the grep by design, not an
# oversight. `.gaia/local` is gitignored (not tracked, so `git grep` would
# never surface it anyway) and CHANGELOG.md/wiki/log.md are excluded because
# they may legitimately narrate the removal historically. This file itself is
# excluded too: it is the absence assertion, so it names the retired symbol on
# purpose (once committed it is tracked, and `git grep` would otherwise match
# its own text). The routing-parity fixture
# (.gaia/tests/hooks/fixtures/audit-routing-before.tsv) is excluded on the same
# grounds: it is a generated enumeration of every tracked path, so it carries
# this test's own filename as a data row, never a call to the retired script.
#
# Parallel-authoring note: two live call sites (spec-archive-merged.sh via
# spec-close.md, and plan-archive.sh) are removed by sibling tasks in the same
# phase as this one. The grep test below is the phase-integration gate: it is
# expected to be non-empty until every sibling task's edits land alongside
# this one, at which point it goes empty.
#
# Assertion style note: bare `[[ ... ]]` is avoided for any non-terminal
# assertion per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
}

@test "UAT-007: cost-consolidate.sh no longer exists" {
  [ ! -f "$REPO_ROOT/.specify/extensions/gaia/lib/cost-consolidate.sh" ]
}

@test "UAT-007: scoped git grep for cost-consolidate is empty across .specify .gaia .claude wiki" {
  run git -C "$REPO_ROOT" grep -l cost-consolidate -- \
    .specify .gaia .claude wiki \
    ':!.gaia/local' ':!.gaia/manifest.json' ':!CHANGELOG.md' ':!wiki/log.md' \
    ':!.gaia/scripts/tests/cost-consolidate-absence.bats' \
    ':!.gaia/tests/hooks/fixtures/audit-routing-before.tsv'
  # git grep exits 1 (not 0) when it finds no match; the assertion that
  # matters is emptiness of $output, not the exit code.
  [ -z "$output" ]
}

@test "SC5: cost-backfill.sh no-ops when both archived/ dirs are absent (no rows, no dirs created)" {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR}/sandbox.XXXXXX")"
  mkdir -p "$SANDBOX/.gaia/local/telemetry"
  ledger="$SANDBOX/.gaia/local/telemetry/cost.jsonl"
  printf '%s\n' '{"schema_version":1,"kind":"execute","spec_id":"SPEC-PRE","session_id":"pre","buckets":{"fresh_input":1,"cache_write":0,"cache_read":0,"output":0},"total":1}' > "$ledger"
  before="$(cat "$ledger")"

  # Neither archived/ tree exists in this sandbox at all.
  [ ! -d "$SANDBOX/.gaia/local/specs/archived" ]
  [ ! -d "$SANDBOX/.gaia/local/plans/archived" ]

  run bash "$REPO_ROOT/.gaia/scripts/cost-backfill.sh" "$SANDBOX" --ledger "$ledger"
  [ "$status" -eq 0 ]

  # Still absent afterward: cost-backfill.sh never creates an archived/ tree.
  [ ! -d "$SANDBOX/.gaia/local/specs/archived" ]
  [ ! -d "$SANDBOX/.gaia/local/plans/archived" ]

  # The ledger is byte-identical: no row was appended.
  after="$(cat "$ledger")"
  [ "$before" = "$after" ]
}
