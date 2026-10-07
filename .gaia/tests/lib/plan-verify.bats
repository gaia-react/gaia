#!/usr/bin/env bats
#
# .gaia/scripts/spec/plan-verify.sh behavior: existence checks, the routing
# table, the story play-function criterion line, the orchestrator step
# sentinels (match rule, order rule, per-arm requirements), failure
# aggregation and the misrouting warning. Shell level only.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  mkdir -p "$PLAN"
  S_RENDER='<!-- gaia:orchestrator-step uat-render -->'
  S_GATE='<!-- gaia:orchestrator-step uat-gate -->'
  S_PRE='<!-- gaia:orchestrator-step uat-pre-audit -->'
  S_WIKI='<!-- gaia:orchestrator-step wiki-promotion -->'
  S_CLOSE='<!-- gaia:orchestrator-step post-merge-close -->'
}

# write_spec [<story then-clause>]: three UATs, one per surface.
write_spec() {
  cat >"$SPEC" <<EOF2
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they check out as a guest
    then: the confirmation page shows the order number
  - uat_id: UAT-002
    given: the save button is shown
    when: the user presses save
    then: ${1:-the toast reads Saved}
  - uat_id: UAT-003
    given: a corrupted cache file
    when: the rebuild script runs
    then: the script exits zero
---
EOF2
}

write_routing() {
  cat >"$PLAN/README.md" <<EOF2
# Plan

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | e2e | 2 | checkout | guest-checkout-confirms-order.spec.ts |
| UAT-002 | story | 3 | - | - |
| UAT-003 | non-ui | 1 | - | - |
<!-- gaia:uat-routing:end -->
EOF2
}

# write_orchestrator <sentinel>...: ORCHESTRATOR.md with these lines in this order.
write_orchestrator() {
  {
    printf '# Orchestrator\n\n'
    printf '%s\n\nprose between steps\n\n' "$@"
  } >"$PLAN/ORCHESTRATOR.md"
}

write_task() {
  printf '# Task\n\n%s\n' "$1" >"$PLAN/task-one.md"
}

# spec_fixture: a passing spec-derived plan folder.
spec_fixture() {
  write_spec
  write_routing
  write_orchestrator "$S_RENDER" "$S_GATE" "$S_PRE" "$S_WIKI" "$S_CLOSE"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  write_task '- Story play-function criterion (UAT-002): the toast reads Saved'
}

# spec_less_fixture: a passing spec-less plan folder.
spec_less_fixture() {
  printf '# Plan\n' >"$PLAN/README.md"
  write_orchestrator "$S_WIKI" "$S_CLOSE"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  write_task '- nothing'
}

verify_spec() {
  run bash "$SCRIPT" "$PLAN" --spec "$SPEC"
}

verify_spec_less() {
  run bash "$SCRIPT" "$PLAN"
}

@test "a complete spec-derived plan passes" {
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ]
}

@test "a complete spec-less plan passes" {
  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ]
}

@test "usage errors exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/no-such-folder"
  [ "$status" -eq 2 ]
  spec_less_fixture
  run bash "$SCRIPT" "$PLAN" --spec "$BATS_TEST_TMPDIR/no-such-spec.md"
  [ "$status" -eq 2 ]
}

@test "a story UAT with no criterion line fails naming its id" {
  spec_fixture
  write_task '- nothing relevant'
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'UAT-002'
}

@test "the criterion line with the then-clause verbatim passes" {
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ]
}

@test "a criterion line for the right id with a different then-clause fails" {
  spec_fixture
  write_task '- Story play-function criterion (UAT-002): the toast reads Failed'
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'UAT-002'
}

@test "a criterion line for a different id does not satisfy the story UAT" {
  spec_fixture
  write_task '- Story play-function criterion (UAT-003): the toast reads Saved'
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'UAT-002'
}

@test "whitespace-only differences in the criterion line pass" {
  spec_fixture
  write_task "-   Story play-function criterion (UAT-002):	the   toast  reads   Saved   "
  verify_spec
  [ "$status" -eq 0 ]
}

@test "a then-clause that begins and ends with a double quote passes verbatim and is not quote-stripped" {
  spec_fixture
  write_spec "'\"Saved\" toast reads \"Done\"'"
  write_task '- Story play-function criterion (UAT-002): "Saved" toast reads "Done"'
  verify_spec
  [ "$status" -eq 0 ]
  write_task '- Story play-function criterion (UAT-002): Saved" toast reads "Done'
  verify_spec
  [ "$status" -eq 1 ]
}

@test "the criterion line may live in any task doc" {
  spec_fixture
  write_task '- nothing relevant'
  printf '%s\n' '- Story play-function criterion (UAT-002): the toast reads Saved' >"$PLAN/task-two.md"
  verify_spec
  [ "$status" -eq 0 ]
}

@test "an invalid routing table fails and carries the library problem line" {
  spec_fixture
  sed -i.bak '/| UAT-003 |/d' "$PLAN/README.md"
  rm -f "$PLAN/README.md.bak"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'UAT-003 has no routing row'
}

@test "each spec-derived sentinel is required and a missing one is named alone" {
  local literal
  for literal in "$S_RENDER" "$S_GATE" "$S_PRE" "$S_WIKI" "$S_CLOSE"; do
    spec_fixture
    grep -vxF -- "$literal" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    verify_spec
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -qF -- "$literal" || return 1
    [ "$(echo "$output" | grep -c 'sentinel')" -eq 1 ] || return 1
  done
}

@test "a spec-less plan does not require the UAT sentinels but requires the other two" {
  local literal
  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ]
  for literal in "$S_WIKI" "$S_CLOSE"; do
    spec_less_fixture
    grep -vxF -- "$literal" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    verify_spec_less
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -qF -- "$literal" || return 1
  done
}

@test "indented sentinels and a trailing tab still match" {
  spec_fixture
  {
    printf '      %s\n\n' "$S_RENDER" "$S_GATE" "$S_PRE" "$S_WIKI"
    printf '%s\t\n' "$S_CLOSE"
  } >"$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 0 ]
}

@test "a sentinel line carrying trailing prose does not match" {
  spec_fixture
  write_orchestrator "$S_RENDER" "$S_GATE" "$S_PRE" "$S_WIKI" "$S_CLOSE see below"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF -- "$S_CLOSE"
}

@test "the render sentinel below the gate sentinel is out of order and named" {
  spec_fixture
  write_orchestrator "$S_GATE" "$S_RENDER" "$S_PRE" "$S_WIKI" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_RENDER"
}

@test "a spec-less plan with the close sentinel above the promotion sentinel fails" {
  spec_less_fixture
  write_orchestrator "$S_CLOSE" "$S_WIKI"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'out of order'
}

@test "a missing KICKOFF.md fails naming it" {
  spec_less_fixture
  rm "$PLAN/KICKOFF.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'KICKOFF.md'
}

@test "a plan with no task doc fails naming the task files" {
  spec_less_fixture
  rm "$PLAN/task-one.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'task-*.md'
}

@test "every failure is reported in one run" {
  spec_less_fixture
  rm "$PLAN/KICKOFF.md" "$PLAN/task-one.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'KICKOFF.md'
  echo "$output" | grep -qF 'task-*.md'
}

@test "a story row whose then-clause mentions navigation warns without changing the exit code" {
  spec_fixture
  write_spec 'the page navigates to /checkout'
  write_task '- Story play-function criterion (UAT-002): the page navigates to /checkout'
  verify_spec
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^WARN: UAT-002'
}

@test "a story row without route words prints no warning" {
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'WARN:' && return 1
  true
}
