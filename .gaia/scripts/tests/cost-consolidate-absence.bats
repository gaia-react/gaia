#!/usr/bin/env bats
#
# UAT-007: cost-consolidate.sh is retired. This suite asserts the file is
# gone and that no tracked file still references it (a whole-tree git grep
# carrying named exclusions), plus SC5's archived-absent half: cost-backfill.sh
# still no-ops safely when neither archived/ tree exists.
#
# DP-001: `.gaia/manifest.json` is release-generated and FC-7 forbids editing
# it here, so it is excluded whatever it currently holds; `/gaia-release`
# decides its contents, not this suite. `.gaia/local` is gitignored (not
# tracked, so `git grep` would never surface it anyway). CHANGELOG.md is
# excluded because it may legitimately narrate the removal historically.
# wiki/log.md and wiki/hot.md are excluded on a different ground: each is
# wholly overwritten with free prose rather than edited, so a summary that
# quotes the retired symbol is that file's own wording and not a live
# reference this suite can say anything about. This file itself is excluded
# too: it is the absence assertion, so it names the retired symbol on purpose
# (once committed it is tracked, and `git grep` would otherwise match its own
# text). The routing-parity fixture
# (.gaia/tests/hooks/fixtures/audit-routing-before.tsv) is excluded on the same
# grounds: it is a generated enumeration of every tracked path, so it carries
# this test's own filename as a data row, never a call to the retired script.
#
# The grep names no positive root: its subject is the whole tracked tree minus
# those exclusions. Listing the roots instead is the obvious alternative, and it
# fails in one direction only, silently. A root nobody thought to list is not a
# gap the suite reports, it is a surface the suite cannot read, and the green it
# returns over that surface is indistinguishable from a real absence -- which is
# the failure this scan exists to make impossible, reproduced inside the scan
# itself. The header claim above ("no tracked file") is then what the pathspec
# establishes, up to the exclusions enumerated with it, rather than a wider
# claim a reader has to discount against an unstated set of unread roots.
#
# The honest limit, and why it fails safe. The assertion is over tree state, not
# over a diff, so the CI path filter deciding whether this suite runs controls
# WHEN a reintroduced reference is caught, never WHETHER. One landing on a
# surface that filter does not watch is caught by the next run the filter does
# arm, on a pull request that did not introduce it. Arming it punctually takes a
# catch-all entry in that filter, which would run every matrix leg its `code`
# output gates, this job's two pnpm installs among them, on very nearly every
# pull request; that filter's sibling output exists because the same cost was
# priced and declined on exactly those grounds. Late-and-certain is what is
# accepted instead, and a narrower pathspec here buys none of it back: it trades
# the surfaces it drops for never rather than for late.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
}

@test "UAT-007: cost-consolidate.sh no longer exists" {
  [ ! -f "$REPO_ROOT/.specify/extensions/gaia/lib/cost-consolidate.sh" ]
}

@test "UAT-007: git grep for cost-consolidate is empty across the whole tracked tree" {
  run git -C "$REPO_ROOT" grep -l cost-consolidate -- \
    ':!.gaia/local' ':!.gaia/manifest.json' ':!CHANGELOG.md' \
    ':!wiki/log.md' ':!wiki/hot.md' \
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
  before="$(snapshot_file "$ledger")"

  # Neither archived/ tree exists in this sandbox at all.
  [ ! -d "$SANDBOX/.gaia/local/specs/archived" ]
  [ ! -d "$SANDBOX/.gaia/local/plans/archived" ]

  run bash "$REPO_ROOT/.gaia/scripts/cost-backfill.sh" "$SANDBOX" --ledger "$ledger"
  [ "$status" -eq 0 ]

  # Still absent afterward: cost-backfill.sh never creates an archived/ tree.
  [ ! -d "$SANDBOX/.gaia/local/specs/archived" ]
  [ ! -d "$SANDBOX/.gaia/local/plans/archived" ]

  # The ledger is byte-identical: no row was appended.
  after="$(snapshot_file "$ledger")"
  assert_files_identical "$before" "$after"
}
