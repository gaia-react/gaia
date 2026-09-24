#!/usr/bin/env bats
#
# UAT-007: cost-consolidate.sh is retired. This suite asserts the file is
# gone and that no tracked file still references it (a whole-tree git grep
# carrying named exclusions).
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
# The dedup-key corpus (.gaia/tests/fixtures/dedup-key-corpus/) is excluded on
# those same grounds: it is a verbatim capture of every residual key recorded in
# this repository's merged pull-request bodies and its tech-debt issues in every
# state, so a key whose path field happens to cite this suite's own file is a
# captured data row and not a reference to the retired script. Nothing under
# that directory executes.
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
}

@test "UAT-007: cost-consolidate.sh no longer exists" {
  [ ! -f "$REPO_ROOT/.specify/extensions/gaia/lib/cost-consolidate.sh" ]
}

@test "UAT-007: git grep for cost-consolidate is empty across the whole tracked tree" {
  # gaia-lint-ignore lint-git-path-quoting: the assertion below is emptiness of
  # $output, and quoting cannot turn a non-empty result empty or an empty one
  # non-empty -- the same reasoning the guard header applies to a `git status
  # --porcelain` emptiness test; bats `run` cannot carry NUL through $output
  # either
  run git -C "$REPO_ROOT" grep -l cost-consolidate -- \
    ':!.gaia/local' ':!.gaia/manifest.json' ':!CHANGELOG.md' \
    ':!wiki/log.md' ':!wiki/hot.md' \
    ':!.gaia/scripts/tests/cost-consolidate-absence.bats' \
    ':!.gaia/tests/hooks/fixtures/audit-routing-before.tsv' \
    ':!.gaia/tests/fixtures/dedup-key-corpus'
  # git grep exits 1 (not 0) when it finds no match; the assertion that
  # matters is emptiness of $output, not the exit code.
  [ -z "$output" ]
}
