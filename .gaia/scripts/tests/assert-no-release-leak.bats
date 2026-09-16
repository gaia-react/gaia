#!/usr/bin/env bats

# Adversarial suite for .gaia/scripts/assert-no-release-leak.sh, the shipped-tree
# leak assertion release.yml runs against the very tree that becomes the tarball.
#
# The defect this guards (#2061) is that the assertion's predecessor derived its
# verdict from a command substitution whose producer failure was unobservable.
# An empty result was read as "nothing leaked", and empty is also what the
# pipeline produced when the `cd` did not land, `find` aborted part way through
# an unreadable directory, or `sed` died: the substitution's status was `grep`'s
# alone, and `|| true` swallowed even that. The failure direction was fail-open
# on the gate deciding whether a maintainer-only path ships to every adopter,
# and nothing in the repository went red when the scan did not happen.
#
# Three families, described rather than enumerated, so adding a member to one
# does not leave a roster here saying otherwise.
#
# The E family drives the ordinary contract: the clean pass, the refusal that
# names the leaked paths, the empty exclude list that is an answer rather than
# an absent one, and each way the question can be left unanswerable.
#
# The A family arms the repair. Each member stages the condition the predecessor
# read as clean, drives the script, and proves it refuses to answer. Each is
# paired with a positive control that drives the SAME fixture through the
# predecessor's own shape and shows it returning "clean", because a fixture that
# would pass either way proves nothing about which one is being tested.
#
# The C family binds the caller, so the repaired shape cannot return to
# release.yml silently.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]], POSIX [ ] and grep only, so a broken assertion still fails on
# macOS bash 3.2.
#
# Maintainer-only. `.gaia/scripts/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/assert-no-release-leak.sh"
  STAGING="$BATS_TEST_TMPDIR/staging"
  REGEX="$BATS_TEST_TMPDIR/exclude-regex.txt"
  mkdir -p "$STAGING"
}

teardown() {
  # A fixture that drops a directory to mode 000 would otherwise defeat bats'
  # own tmpdir cleanup.
  chmod -R u+rwX "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# Stage $1 (a staging-relative path) holding a one-line body.
stage() {
  local rel="$1"
  mkdir -p "$STAGING/$(dirname "$rel")"
  printf 'content\n' > "$STAGING/$rel"
}

# Write the compiled exclude patterns, one per line, in the anchored form
# `gaia-maintainer release exclude-regex` emits.
patterns() {
  printf '%s\n' "$@" > "$REGEX"
}

# E1. The ordinary case: a staged tree holding nothing the exclude list withholds
# scans clean.
@test "E1: a staged tree with no excluded path passes" {
  stage 'app/index.ts'
  stage 'README.md'
  patterns '^\.gaia/scripts/tests(/|$)'

  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 0 ]
}

# E2. The refusal, and the paths it names. The exit code alone is not the claim:
# a maintainer reads the annotation to learn which file leaked.
@test "E2: an excluded path in the staged tree refuses and names it" {
  stage 'app/index.ts'
  stage '.gaia/scripts/tests/secret.bats'
  patterns '^\.gaia/scripts/tests(/|$)'

  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 1 ]
  grep -qF -- '.gaia/scripts/tests/secret.bats' <<<"$output"
}

# E3. An empty compiled exclude list withholds nothing, so nothing can leak.
# This is the one empty input that is an answer rather than an absent one.
@test "E3: an empty exclude list passes rather than refusing" {
  stage 'app/index.ts'
  : > "$REGEX"

  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 0 ]
}

# E4. Usage errors are unanswerable, not clean.
@test "E4: a wrong argument count exits 2" {
  run bash "$SCRIPT" "$STAGING"
  [ "$status" -eq 2 ]
  grep -qF -- 'usage:' <<<"$output"
}

# E5. A staging directory that was never created cannot be scanned.
@test "E5: a missing staging directory exits 2" {
  patterns '^\.gaia/scripts/tests(/|$)'

  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/nope" "$REGEX"
  [ "$status" -eq 2 ]
  grep -qF -- 'missing or is not a directory' <<<"$output"
}

# E6. A missing pattern file is the exclude-regex compile having failed upstream;
# treating it as an empty list would pass every leak.
@test "E6: a missing exclude-regex file exits 2" {
  stage 'app/index.ts'

  run bash "$SCRIPT" "$STAGING" "$BATS_TEST_TMPDIR/nope.txt"
  [ "$status" -eq 2 ]
  grep -qF -- 'missing or unreadable' <<<"$output"
}

# A1. The partial-enumeration case, the shape the predecessor read as clean: a
# directory inside the staged tree that `find` cannot descend. The scan stops
# short, so the question is unanswered and the script says so.
@test "A1: a staged tree find cannot fully enumerate exits 2" {
  if [ "$(id -u)" -eq 0 ]; then
    skip 'root traverses a mode-000 directory, so the fixture cannot arm'
  fi
  stage 'app/index.ts'
  mkdir -p "$STAGING/.gaia/scripts/tests"
  printf 'leaked\n' > "$STAGING/.gaia/scripts/tests/secret.bats"
  chmod 000 "$STAGING/.gaia/scripts"
  patterns '^\.gaia/scripts/tests(/|$)'

  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 2 ]
  grep -qF -- 'UNPROVEN' <<<"$output"
}

# A1-control. The same fixture through the predecessor's own shape, proving A1
# arms the defect rather than some unrelated condition: the pre-fix pipeline
# returns an empty `leaked` and reads it as a clean tree, while a real leak sits
# inside the directory it could not enter.
@test "A1-control: the pre-fix shape reads that same tree as clean" {
  if [ "$(id -u)" -eq 0 ]; then
    skip 'root traverses a mode-000 directory, so the fixture cannot arm'
  fi
  stage 'app/index.ts'
  mkdir -p "$STAGING/.gaia/scripts/tests"
  printf 'leaked\n' > "$STAGING/.gaia/scripts/tests/secret.bats"
  chmod 000 "$STAGING/.gaia/scripts"
  patterns '^\.gaia/scripts/tests(/|$)'

  leaked="$( (cd "$STAGING" && find . -type f 2>/dev/null | sed 's|^\./||') \
    | grep -E -f "$REGEX" || true )"
  [ -z "$leaked" ]
}

# A2. The empty staged tree. A staging step that copied nothing satisfies any
# leak scan trivially, which is the same fail-open shape one layer up.
@test "A2: an empty staged tree exits 2 rather than passing" {
  patterns '^\.gaia/scripts/tests(/|$)'

  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 2 ]
  grep -qF -- 'holds no files' <<<"$output"
}

# A2-control. The same fixture through the predecessor's shape, which returns an
# empty `leaked` and lets the release proceed on a tree nothing was staged into.
@test "A2-control: the pre-fix shape reads an empty staged tree as clean" {
  patterns '^\.gaia/scripts/tests(/|$)'

  leaked="$( (cd "$STAGING" && find . -type f | sed 's|^\./||') \
    | grep -E -f "$REGEX" || true )"
  [ -z "$leaked" ]
}

# A3. A pattern file the ERE engine rejects. `grep` exits above 1, which the
# predecessor's `|| true` collapsed into the no-match arm and read as clean.
@test "A3: a pattern grep cannot compile exits 2" {
  stage 'app/index.ts'
  patterns '^\.gaia/scripts/tests[(/|$'

  run bash "$SCRIPT" "$STAGING" "$REGEX"
  [ "$status" -eq 2 ]
  grep -qF -- 'UNPROVEN' <<<"$output"
}

# A3-control. The same malformed pattern file through the predecessor's shape,
# which swallows grep's error status and reports a clean tree.
@test "A3-control: the pre-fix shape reads a grep failure as clean" {
  stage 'app/index.ts'
  patterns '^\.gaia/scripts/tests[(/|$'

  leaked="$( (cd "$STAGING" && find . -type f | sed 's|^\./||') \
    | grep -E -f "$REGEX" 2>/dev/null || true )"
  [ -z "$leaked" ]
}

# C1. The caller binding. release.yml must reach the shipped-tree leak assertion
# through this script, so the inline shape cannot return to the workflow without
# this test going red.
@test "C1: release.yml runs the leak assertion through this script" {
  grep -qF -- 'bash .gaia/scripts/assert-no-release-leak.sh' \
    "$REPO_ROOT/.github/workflows/release.yml"
}

# C2. The caller must also read the script's status rather than discarding it. A
# `|| true` anywhere on that invocation would restore the exact fail-open the
# script exists to close, one layer up.
@test "C2: release.yml does not discard the leak assertion's status" {
  run grep -n -- 'assert-no-release-leak.sh' "$REPO_ROOT/.github/workflows/release.yml"
  [ "$status" -eq 0 ]
  grep -qF -- '|| true' <<<"$output" && return 1
  true
}
