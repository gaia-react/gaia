#!/usr/bin/env bats
#
# Regression guard for the frontmatter YAML parse-error check in lint.sh
# (issue #682). Before that check existed, lint.sh only confirmed that
# each required frontmatter key was present on its own line (a grep, not
# a parse); a SPEC frontmatter that is syntactically invalid YAML still
# lints clean under that check alone. Each hazard fixture below keeps
# every required key present on its own line -- the exact blind spot the
# pre-existing key-presence checks never caught -- and relies solely on
# the new parser-backed check to fail lint. Release-excluded (this dir
# does not ship).
#
# Assertion style note (`.claude/rules/bats-assertions.md`): assertions
# use POSIX `[ ]` or an explicit `return 1`, never a bare mid-test `[[ ]]`,
# so a broken assertion fails correctly even under macOS's bash 3.2.

setup() {
  LINT=".specify/extensions/gaia/lib/lint.sh"
}

required_keys="spec_id type status immutable wiki_promote_default chain_trigger intent success_criteria uats scope_boundaries clarifications research_summary created updated"

# Fails (returns 1) unless every required top-level frontmatter key is
# present on its own line in $1 -- i.e. unless the fixture would have
# passed the pre-existing grep-only key-presence checks.
assert_all_required_keys_present() {
  for k in $required_keys; do
    grep -qE "^${k}:" "$1" || return 1
  done
}

# Skip a parse-fail test when no YAML parser is available. lint.sh's parse
# check is best-effort: with neither python3+pyyaml nor yq present it skips
# the check silently, so the hazard fixtures below lint clean and would fail
# these tests spuriously. Detection mirrors lint.sh (python3+pyyaml, then yq).
#
# On CI the parser is a precondition rather than a maybe: audit-ci-tests.yml
# installs python3-yaml in the same job that runs this suite. So the CI branch
# FAILS instead of skipping. A skip reports `ok ... # skip` and greens the job,
# which would retire every parse-fail test below in silence. The test directly
# after this one proves that branch fires. Matches the same-named gate in
# .gaia/scripts/tests/retrigger-reachability.bats, which has no yq fallback.
require_yaml_parser() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  if command -v yq >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::no YAML parser (python3+pyyaml or yq) on a CI runner; the parse-fail tests here would skip to green. Check the apt install in .github/workflows/audit-ci-tests.yml." >&2
    return 1
  fi
  skip "no YAML parser available (python3+pyyaml or yq); lint.sh skips the parse check"
}

# The gate above is the single point where every parse-fail test below can be
# turned off at once, and nothing else in this file would notice if it started
# skipping on CI. This is what makes that weakening red. Not itself gated.
@test "the parser gate fails on a CI runner and still skips off CI" {
  local shim="$BATS_TMPDIR/lint-yaml-no-parser" rc
  mkdir -p "$shim"
  # python3 present, but its `import yaml` fails: the shape a runner takes when
  # python3-yaml is dropped from the apt line, not one where python3 is missing
  # outright. The shebang is absolute so the stripped PATH below cannot affect it.
  printf '#!/bin/sh\nexit 1\n' > "$shim/python3"
  chmod +x "$shim/python3"

  # The shim ALONE is a sufficient PATH, and here it is also load-bearing: the
  # gate runs no command other than `command -v python3`, that python3, and
  # `command -v yq`, so a PATH holding only the shim is what puts the yq fallback
  # out of reach on a host that has yq installed. Calling the gate in a subshell
  # keeps its `skip` arm from marking this test skipped -- bats' `skip` exits 0,
  # so the subshell's status is the discriminator: non-zero is the CI failure,
  # 0 is the off-CI skip.
  rc=0
  ( PATH="$shim" GITHUB_ACTIONS=true; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || {
    echo "the gate skipped on a CI runner with no YAML parser; the parse-fail tests would report green" >&2
    return 1
  }

  rc=0
  ( PATH="$shim"; unset GITHUB_ACTIONS; require_yaml_parser ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || {
    echo "the gate failed off CI, where a missing parser must still skip" >&2
    return 1
  }
}

@test "valid GAIA frontmatter lints clean, no yaml_parse_error" {
  spec="$BATS_TMPDIR/lint-yaml-valid.spec.md"
  cat > "$spec" <<'SPEC'
---
spec_id: SPEC-001
type: feature
status: in-progress
immutable: true
wiki_promote_default: yes
chain_trigger: gaia-plan
intent: |
  Plain paragraph describing the feature.
success_criteria:
  - Outcome one.
uats:
  - uat_id: UAT-001
    given: Some precondition.
    when: Some action.
    then: Some outcome.
scope_boundaries:
  always:
    - Always do X.
  ask_first:
    - Ask before Y.
  never:
    - Never do Z.
clarifications:
  answered:
    - q: A question?
      a: An answer.
  pending: []
research_summary: |
  Some research findings.
created: 2026-01-01
updated: 2026-01-01
---

# Title

## One-line summary

Summary.
SPEC

  assert_all_required_keys_present "$spec" || return 1

  run bash "$LINT" "$spec"
  [ "$status" -eq 0 ] || return 1
  grep -qF '"ok":true' <<<"$output" || return 1
  grep -qF 'yaml_parse_error' <<<"$output" && return 1
  return 0
}

@test "backtick-leading plain scalar fails yaml_parse_error even though all required keys are present" {
  require_yaml_parser
  spec="$BATS_TMPDIR/lint-yaml-backtick.spec.md"
  cat > "$spec" <<'SPEC'
---
spec_id: SPEC-001
type: feature
status: in-progress
immutable: true
wiki_promote_default: yes
chain_trigger: `gaia-plan`
intent: |
  Plain paragraph describing the feature.
success_criteria:
  - Outcome one.
uats:
  - uat_id: UAT-001
    given: Some precondition.
    when: Some action.
    then: Some outcome.
scope_boundaries:
  always:
    - Always do X.
  ask_first:
    - Ask before Y.
  never:
    - Never do Z.
clarifications:
  answered:
    - q: A question?
      a: An answer.
  pending: []
research_summary: |
  Some research findings.
created: 2026-01-01
updated: 2026-01-01
---

# Title

## One-line summary

Summary.
SPEC

  assert_all_required_keys_present "$spec" || return 1

  run bash "$LINT" "$spec"
  [ "$status" -eq 1 ] || return 1
  grep -qF 'yaml_parse_error' <<<"$output" || return 1
}

@test "colon-space inside a plain scalar fails yaml_parse_error even though all required keys are present" {
  require_yaml_parser
  spec="$BATS_TMPDIR/lint-yaml-colonspace.spec.md"
  cat > "$spec" <<'SPEC'
---
spec_id: SPEC-001
type: feature
status: in-progress
immutable: true
wiki_promote_default: yes
chain_trigger: gaia-plan: extra
intent: |
  Plain paragraph describing the feature.
success_criteria:
  - Outcome one.
uats:
  - uat_id: UAT-001
    given: Some precondition.
    when: Some action.
    then: Some outcome.
scope_boundaries:
  always:
    - Always do X.
  ask_first:
    - Ask before Y.
  never:
    - Never do Z.
clarifications:
  answered:
    - q: A question?
      a: An answer.
  pending: []
research_summary: |
  Some research findings.
created: 2026-01-01
updated: 2026-01-01
---

# Title

## One-line summary

Summary.
SPEC

  assert_all_required_keys_present "$spec" || return 1

  run bash "$LINT" "$spec"
  [ "$status" -eq 1 ] || return 1
  grep -qF 'yaml_parse_error' <<<"$output" || return 1
}

@test "space-hash inside a plain scalar fails yaml_parse_error even though all required keys are present" {
  require_yaml_parser
  spec="$BATS_TMPDIR/lint-yaml-hash.spec.md"
  cat > "$spec" <<'SPEC'
---
spec_id: SPEC-001
type: feature
status: in-progress
immutable: true
wiki_promote_default: yes
chain_trigger: gaia-plan
intent: |
  Plain paragraph describing the feature.
success_criteria:
  - Outcome one.
uats:
  - uat_id: UAT-001
    given: Some precondition.
    when: Some action.
    then: the result is 42 #percent complete
      and remains stable afterward.
scope_boundaries:
  always:
    - Always do X.
  ask_first:
    - Ask before Y.
  never:
    - Never do Z.
clarifications:
  answered:
    - q: A question?
      a: An answer.
  pending: []
research_summary: |
  Some research findings.
created: 2026-01-01
updated: 2026-01-01
---

# Title

## One-line summary

Summary.
SPEC

  assert_all_required_keys_present "$spec" || return 1

  run bash "$LINT" "$spec"
  [ "$status" -eq 1 ] || return 1
  grep -qF 'yaml_parse_error' <<<"$output" || return 1
}
