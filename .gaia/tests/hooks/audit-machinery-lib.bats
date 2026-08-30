#!/usr/bin/env bats
# Tests for .claude/hooks/lib/audit-machinery.sh, the one machinery-path
# matcher for the Code Audit Team.
#
# The boundary under test is the one the lib's own header states: a `.bats`
# suite is never machinery, even when it sits under a `/**` directory-prefix
# entry, while its sibling `.sh` files under that same prefix still are. The
# stakes are asymmetric in one direction only. A machinery path enters EVERY
# member's digest (audit-digest.sh) and makes the CI base resolver emit
# `main_ref` (.github/audit/resolve-audit-base.sh), so classifying a suite as
# machinery invalidates every standing clearance marker and re-reviews the
# whole PR diff for a test-only edit (#1357). Coverage of the suites themselves
# is unaffected: the roster's own `.bats` globs dispatch a real member to them.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"
  MACHINERY_LIB="$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh"
  [ -f "$MACHINERY_LIB" ] || skip "audit-machinery.sh not present"
  # shellcheck source=/dev/null
  . "$MACHINERY_LIB"

  # A real pair under the `.github/audit/**` prefix entry: the suite and the
  # gate script it guards. Both are tracked, so the pair proves the exclusion
  # is keyed on the extension rather than on the directory.
  SUITE_PATH=".github/audit/tests/pr-merge-audit-check.bats"
  SIBLING_PATH=".github/audit/resolve-audit-base.sh"
}

@test "a bats suite under a machinery /** prefix is not machinery, its sibling .sh still is" {
  run audit_path_is_machinery "$SUITE_PATH"
  [ "$status" -ne 0 ]

  run audit_path_is_machinery "$SIBLING_PATH"
  [ "$status" -eq 0 ]
}

# audit_machinery_flags is the batch classifier the digest walk uses, and its
# contract is byte-identical membership with audit_path_is_machinery. A carve-
# out applied to only one of the two would leave the digest walk rotating every
# member's key while the single-path matcher says it should not.

@test "audit_machinery_flags agrees with audit_path_is_machinery across the bats boundary" {
  out="$(printf '%s\n%s\n' "$SUITE_PATH" "$SIBLING_PATH" | audit_machinery_flags)"

  grep -qxF -- "$(printf '%s\t0' "$SUITE_PATH")" <<<"$out" || return 1
  grep -qxF -- "$(printf '%s\t1' "$SIBLING_PATH")" <<<"$out" || return 1
}

# The trigger the carve-out exists for: a PR whose delta is suites only. The CI
# base resolver calls audit_delta_has_machinery and widens every member's review
# to the full PR diff on a hit, so a miss here is what keeps a test-only edit
# reviewed as a delta.

@test "a delta of bats suites alone reports no machinery hit" {
  run audit_delta_has_machinery <<'EOF'
.github/audit/tests/pr-merge-audit-check.bats
.github/audit/tests/resolve-audit-base.bats
EOF
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# Population sweep over the real tree. The pair above pins the one prefix that
# sweeps suites today; this catches a future `/**` entry that starts sweeping
# them somewhere else, which no fixture-based test would see.

@test "no tracked .bats file in the repo classifies as machinery" {
  hits=""
  swept=0
  while IFS= read -r -d '' tracked; do
    [ -n "$tracked" ] || continue
    swept=$((swept + 1))
    if audit_path_is_machinery "$tracked"; then
      hits="${hits}${tracked}
"
    fi
  done < <(git -C "$REPO_ROOT" ls-files -z '*.bats')

  # A sweep that classified nothing greens on an empty $hits while asserting
  # nothing, which retires the only guard against a future `/**` entry reaching
  # suites. Assert the population is non-empty before reading the verdict.
  [ "$swept" -gt 0 ]
  [ -z "$hits" ]
}
