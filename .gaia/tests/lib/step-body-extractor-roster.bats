#!/usr/bin/env bats
# Tests for .gaia/scripts/check-step-body-extractor-roster.sh: the check that
# turns the `extract_step_body` family over code-review-audit.yml from a grep
# recipe re-run by hand into a declared roster.
#
# What has to be true for the check to be worth its name, and why each is a test
# rather than a sentence in the header.
#
# 1. It fires on an unregistered candidate. That is the whole point: a new copy
#    of the extractor joining the tree with nobody noticing is the failure the
#    hand-run recipe produced three times, so a green run on a tree carrying one
#    would reproduce the defect inside the fix.
#
# 2. It fires on a stale entry, both tables. A roster naming a file that no
#    longer extracts anything decays into the hardcoded list it replaced, and a
#    check that only looks one way cannot tell a retired member from a live one.
#
# 3. It does NOT fire on a near miss. Each of the two literals is load-bearing
#    alone: a suite that names the workflow in prose without extracting a step,
#    and one that extracts steps out of some other file, are both non-candidates.
#    Without these, the honest way to green the check is to widen it until it
#    matches everything, and nobody would learn that from the passing tests.
#
# 4. Every non-member carries a reason. The table's value is that a reader can
#    see the judgment was made; an entry with an empty reason is an omission
#    wearing a member's clothes.
#
# The fixture repos stand in for the real tree, so the mutation tests can prove
# the red without editing tracked source. There is deliberately no "the real
# tree is clean" test: the check is a member of
# .gaia/tests/whole-tree-invariants.sh, which runs it against the real tree in
# CI, so asserting it a second time here would only duplicate that run.
#
# This suite writes its fixtures from the check's own GAIA_SBX_* variables
# rather than retyping the two criterion literals. That keeps it out of the
# candidate set it is testing -- no self-reference to resolve -- and it means a
# test cannot green against a literal the check no longer uses.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  CHECK="$REPO_ROOT/.gaia/scripts/check-step-body-extractor-roster.sh"
  # shellcheck source=/dev/null
  . "$CHECK"
  TMP=""
}

teardown() {
  [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf "$TMP"
  return 0
}

# extractor_file <path>: a stub carrying BOTH criterion literals, so the
# enumeration counts it exactly as a real extractor copy.
extractor_file() {
  mkdir -p "$TMP/$( dirname "$1" )"
  {
    printf '#!/usr/bin/env bats\n'
    printf '# reads %s\n' "$GAIA_SBX_WORKFLOW"
    printf 'awk %s/^%s/ { exit }%s "$WORKFLOW"\n' "'" "$GAIA_SBX_STEP_HEADER" "'"
  } > "$TMP/$1"
}

# fixture_repo: a temp git repo holding one stub at every registered path, so
# the baseline agrees with the tables and each test mutates one thing.
fixture_repo() {
  TMP="$(mktemp -d -t step-body-extractor-roster-XXXXXX)"
  git -C "$TMP" init -q --initial-branch=main
  local path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    extractor_file "$path"
  done < <( _gaia_sbx_registered )
  git -C "$TMP" add -A
}

@test "a tree whose candidates match both tables exactly passes" {
  fixture_repo
  run gaia_check_step_body_extractor_roster "$TMP"
  [ "$status" -eq 0 ]
  grep -qF -- 'step-body extractor roster over' <<<"$output"
}

@test "an unregistered extractor copy fails the check and is named" {
  fixture_repo
  extractor_file '.github/audit/tests/newly-copied-extractor.bats'
  git -C "$TMP" add -A
  run gaia_check_step_body_extractor_roster "$TMP"
  [ "$status" -eq 1 ]
  grep -qF -- 'unregistered step-extractor candidates' <<<"$output"
  grep -qF -- '.github/audit/tests/newly-copied-extractor.bats' <<<"$output"
}

@test "a member that stops extracting fails the check as a stale entry" {
  fixture_repo
  local retired
  retired="$( printf '%s\n' "$GAIA_SBX_MEMBERS" | head -1 )"
  git -C "$TMP" rm -q -f -- "$retired"
  run gaia_check_step_body_extractor_roster "$TMP"
  [ "$status" -eq 1 ]
  grep -qF -- 'stale roster entries' <<<"$output"
  grep -qF -- "$retired" <<<"$output"
}

@test "a non-member that stops extracting fails the check as a stale entry too" {
  fixture_repo
  local retired
  retired="$( printf '%s\n' "$GAIA_SBX_NOT_MEMBERS" | head -1 | sed 's/|.*//' )"
  git -C "$TMP" rm -q -f -- "$retired"
  run gaia_check_step_body_extractor_roster "$TMP"
  [ "$status" -eq 1 ]
  grep -qF -- 'stale roster entries' <<<"$output"
  grep -qF -- "$retired" <<<"$output"
}

@test "naming the workflow without extracting a step is not a candidate" {
  fixture_repo
  mkdir -p "$TMP/.github/audit/tests"
  printf '#!/usr/bin/env bats\n# prose about %s and nothing else\n' \
    "$GAIA_SBX_WORKFLOW" > "$TMP/.github/audit/tests/mentions-only.bats"
  git -C "$TMP" add -A
  run gaia_check_step_body_extractor_roster "$TMP"
  [ "$status" -eq 0 ]
  grep -qF -- 'mentions-only.bats' <<<"$output" && return 1
  true
}

@test "extracting steps out of a different workflow is not a candidate" {
  fixture_repo
  mkdir -p "$TMP/.github/audit/tests"
  printf '#!/usr/bin/env bats\nawk %s/^%s/ { exit }%s some-other-workflow.yml\n' \
    "'" "$GAIA_SBX_STEP_HEADER" "'" > "$TMP/.github/audit/tests/other-workflow.bats"
  git -C "$TMP" add -A
  run gaia_check_step_body_extractor_roster "$TMP"
  [ "$status" -eq 0 ]
  grep -qF -- 'other-workflow.bats' <<<"$output" && return 1
  true
}

@test "every declared non-member carries a reason" {
  local line path reason
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line%%|*}"
    reason="${line#*|}"
    [ -n "$path" ] || return 1
    [ "$reason" != "$line" ] || {
      printf 'non-member entry has no |reason: %s\n' "$line" >&2
      return 1
    }
    [ -n "$reason" ] || {
      printf 'non-member entry has an empty reason: %s\n' "$path" >&2
      return 1
    }
  done <<EOF
$GAIA_SBX_NOT_MEMBERS
EOF
  true
}
