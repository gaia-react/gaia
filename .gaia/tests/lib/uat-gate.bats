#!/usr/bin/env bats
#
# The owning-phase UAT gate (uat-gate.sh), the contract divergence check
# (uat-divergence-check.sh) and the working-document id scan
# (working-doc-id-scan.sh). Shell level only: the gate's Playwright step runs
# through --report with committed JSON reports recorded from a real Playwright
# run (fixtures/uat-gate/), so no Node and no browser is needed. Rendered specs
# come from the real renderer (uat-write.sh), never a hand-written marker.
#
# Assertion style follows .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT_REAL/.gaia/scripts/spec"
  GATE="$SCRIPTS/uat-gate.sh"
  DIVERGENCE="$SCRIPTS/uat-divergence-check.sh"
  SCAN="$SCRIPTS/working-doc-id-scan.sh"
  WRITER="$SCRIPTS/uat-write.sh"
  REPORTS="$BATS_TEST_DIRNAME/fixtures/uat-gate"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/plan"
  SPEC="$WORK/SPEC.md"
  ROUTING="$WORK/plan/README.md"
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  FILE_PHASE_TWO_RELATIVE='frontend/.playwright/e2e/checkout/guest-checkout-confirms-order.spec.ts'
  FILE_PHASE_THREE_RELATIVE='frontend/.playwright/e2e/orders/order-history-lists-orders.spec.ts'
  FILE_PHASE_TWO="$WORK/$FILE_PHASE_TWO_RELATIVE"
  FILE_PHASE_THREE="$WORK/$FILE_PHASE_THREE_RELATIVE"
}

# write_spec [<then-scalar>]: a SPEC with a non-UI UAT (phase 1) and two e2e
# UATs (phases 2 and 3), plus its routing table. The optional argument is the
# raw YAML scalar of the phase-2 then field.
write_spec() {
  cat >"$SPEC" <<SPEC_EOF
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: the pipeline is configured
    when: the script runs
    then: it exits zero
  - uat_id: UAT-002
    given: a visitor with items in the cart
    when: they check out as a guest
    then: ${1:-the confirmation page shows the order number}
  - uat_id: UAT-003
    given: a signed in member
    when: they open the order history
    then: every past order is listed newest first
---
SPEC_EOF
  cat >"$ROUTING" <<'ROUTING_EOF'
# Plan

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | non-ui | 1 | - | - |
| UAT-002 | e2e | 2 | checkout | guest-checkout-confirms-order.spec.ts |
| UAT-003 | e2e | 3 | orders | order-history-lists-orders.spec.ts |
<!-- gaia:uat-routing:end -->
ROUTING_EOF
}

render_specs() {
  (cd "$WORK" && bash "$WRITER" "$SPEC" --routing "$ROUTING" >/dev/null)
}

# green_body <file> [<body>]: keep the marker and contract header through the
# import line, then replace the red body with a passing-looking one.
green_body() {
  local file="$1" body="${2:-}" header="$BATS_TEST_TMPDIR/header"
  sed -n '1,/^import /p' "$file" >"$header"
  if [ -z "$body" ]; then
    body="test('the confirmation page shows the order number', async ({page}) => {
  await page.goto('/checkout');
  await expect(page.getByRole('heading')).toBeVisible();
});"
  fi
  {
    cat "$header"
    printf '\n%s\n' "$body"
  } >"$file"
  rm -f "$header"
}

prepare_green() {
  write_spec
  render_specs
  green_body "$FILE_PHASE_TWO"
}

# gate <argument>...: run the gate from the fixture root; stdout lands in
# $output, stderr in $STDERR_FILE.
gate() {
  run bash -c "cd '$WORK' && bash '$GATE' '$SPEC' --routing '$ROUTING' $* 2>'$STDERR_FILE'"
}

# assert_stderr_names <needle>...: every needle appears in the captured stderr.
assert_stderr_names() {
  local needle
  for needle in "$@"; do
    grep -qF -- "$needle" "$STDERR_FILE" || return 1
  done
}

# --- Gate: the report statuses ---

@test "the committed report fixtures are the full set the status cases drive" {
  local expected="expected-failure failed fixme no-tests passed passed-two-files skipped" found report
  found=$(cd "$REPORTS" && ls ./*.json | sed 's#^\./##; s#\.json$##' | LC_ALL=C sort | tr '\n' ' ')
  [ "${found% }" = "$expected" ]
  # Every report is real Playwright JSON: it carries the reporter's own keys.
  for report in "$REPORTS"/*.json; do
    jq -e 'has("suites") and has("config") and has("stats")' "$report" >/dev/null
  done
}

@test "gate passes a passed report (the twin of every refusal below)" {
  prepare_green
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ]
  [ ! -s "$STDERR_FILE" ]
}

@test "gate refuses an expected failure with the expected-failure reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/expected-failure.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" expected-failure
}

@test "gate refuses a skipped test with the skipped reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/skipped.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" skipped
}

@test "gate refuses a fixme test with the fixme reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/fixme.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" fixme
}

@test "gate refuses a failed test with the failed reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/failed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" failed
}

@test "gate refuses a report that holds no test for the file with the no-tests reason" {
  prepare_green
  gate --phase 2 --report "$REPORTS/no-tests.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" no-tests
}

@test "gate refuses a report that is not JSON, and a report that does not exist, as invalid input" {
  prepare_green
  printf 'not json\n' >"$BATS_TEST_TMPDIR/bad.json"
  gate --phase 2 --report "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 2 ]
  gate --phase 2 --report "$BATS_TEST_TMPDIR/absent.json"
  [ "$status" -eq 2 ]
}

# --- Gate: static violations ---

GREEN_TEST_LINES="  await page.goto('/checkout');
  await expect(page.getByRole('heading')).toBeVisible();"

# static_case <reason> <body>: a passed report cannot rescue this body.
static_case() {
  prepare_green
  green_body "$FILE_PHASE_TWO" "$2"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" "$1"
}

@test "gate refuses a leftover test.fail( with the annotation reason" {
  static_case annotation "test('t', async ({page}) => {
  test.fail();
$GREEN_TEST_LINES
});"
}

@test "gate refuses a conditional test.fail(condition) with the annotation reason" {
  static_case annotation "test('t', async ({page, browserName}) => {
  test.fail(browserName === 'webkit');
$GREEN_TEST_LINES
});"
}

@test "gate refuses test.only( with the annotation reason" {
  static_case annotation "test.only('t', async ({page}) => {
$GREEN_TEST_LINES
});"
}

@test "gate refuses test.skip( with the annotation reason" {
  static_case annotation "test('t', async ({page}) => {
  test.skip();
$GREEN_TEST_LINES
});"
}

@test "gate refuses test.fixme( with the annotation reason" {
  static_case annotation "test.fixme('t', async ({page}) => {
$GREEN_TEST_LINES
});"
}

@test "gate refuses test.describe.skip( with the annotation reason" {
  static_case annotation "test.describe.skip('group', () => {
  test('t', async ({page}) => {
$GREEN_TEST_LINES
  });
});"
}

@test "gate refuses test.describe.fixme( with the annotation reason" {
  static_case annotation "test.describe.fixme('group', () => {
  test('t', async ({page}) => {
$GREEN_TEST_LINES
  });
});"
}

@test "gate refuses a body of expect(true).toBe(true) with no page call with the floor reason" {
  static_case floor "test('t', async () => {
  expect(true).toBe(true);
});"
}

@test "gate refuses a page call whose only expect has a literal first argument with the floor reason" {
  static_case floor "test('t', async ({page}) => {
  await page.goto('/checkout');
  expect(true).toBe(true);
});"
}

@test "gate refuses string, number and null literal expects as the only assertions" {
  static_case floor "test('t', async ({page}) => {
  await page.goto('/checkout');
  expect('done, really').toBe('done, really');
  expect(1).toBe(1);
  expect(null).toBeNull();
});"
}

@test "gate refuses a non-literal expect with no page interaction with the floor reason" {
  static_case floor "test('t', async () => {
  expect(1 + 1).toBe(2);
});"
}

@test "gate accepts a literal expect beside a real non-literal one" {
  prepare_green
  green_body "$FILE_PHASE_TWO" "test('t', async ({page}) => {
  expect(true).toBe(true);
  await page.goto('/checkout');
  await expect(page).toHaveURL(/checkout/);
});"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ]
}

@test "gate refuses a missing spec file with the missing reason" {
  prepare_green
  rm -f "$FILE_PHASE_TWO"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" missing
}

@test "gate refuses a spec whose line 1 is not a contract marker with the missing reason" {
  prepare_green
  sed -i.bak '1s#.*#// not a marker#' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" missing
}

@test "gate refuses the freshly rendered red spec: it still carries test.fail( and a literal expect" {
  write_spec
  render_specs
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" annotation floor
}

# --- Gate: the other two checks ---

@test "gate refuses an altered contract comment with the divergence reason" {
  prepare_green
  sed -i.bak 's#^// Then: .*#// Then: the confirmation page shows nothing#' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_TWO_RELATIVE" divergence
}

@test "gate refuses a working-document id anywhere under the Playwright tree with the working-doc-id reason" {
  prepare_green
  printf '// see UAT-123 for context\n' >"$WORK/frontend/.playwright/helper.ts"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "frontend/.playwright/helper.ts" working-doc-id
}

# --- Gate: selection ---

@test "gate --phase checks only that phase's e2e rows: a broken later phase does not fail it" {
  prepare_green
  [ -f "$FILE_PHASE_THREE" ]
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 0 ]
  [ ! -s "$STDERR_FILE" ]
}

@test "gate --all checks every e2e row and fails on the broken later phase only" {
  prepare_green
  gate --all --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 1 ]
  assert_stderr_names "$FILE_PHASE_THREE_RELATIVE" annotation
  if grep -qF -- "$FILE_PHASE_TWO_RELATIVE" "$STDERR_FILE"; then
    return 1
  fi
}

@test "gate --all passes when every e2e row is green and reported passed" {
  prepare_green
  green_body "$FILE_PHASE_THREE" "test('every past order is listed newest first', async ({page}) => {
  await page.goto('/orders');
  await expect(page.getByRole('list')).toBeVisible();
});"
  gate --all --report "$REPORTS/passed-two-files.json"
  [ "$status" -eq 0 ]
}

@test "gate on a phase that owns no e2e rows prints no owned e2e specs and exits 0" {
  prepare_green
  gate --phase 1 --report "$REPORTS/failed.json"
  [ "$status" -eq 0 ]
  [ "$output" = "no owned e2e specs" ]
}

@test "gate refuses missing or conflicting selection arguments as invalid input" {
  prepare_green
  gate
  [ "$status" -eq 2 ]
  gate --phase 2 --all
  [ "$status" -eq 2 ]
  gate --phase two
  [ "$status" -eq 2 ]
}

@test "gate refuses an invalid routing table as invalid input" {
  prepare_green
  sed -i.bak '/UAT-003/d' "$ROUTING"
  rm -f "$ROUTING.bak"
  gate --phase 2 --report "$REPORTS/passed.json"
  [ "$status" -eq 2 ]
}

# --- Gate: environment ---

# stub_pnpm <body>: a pnpm on PATH that runs the given shell body.
stub_pnpm() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\n%s\n' "$1" >"$BATS_TEST_TMPDIR/bin/pnpm"
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
}

gate_with_stub() {
  run bash -c "cd '$WORK' && PATH='$BATS_TEST_TMPDIR/bin':\"\$PATH\" bash '$GATE' '$SPEC' --routing '$ROUTING' --phase 2 2>'$STDERR_FILE'"
}

@test "gate exits 4 naming the prerequisite when Playwright cannot start" {
  prepare_green
  stub_pnpm "echo \"browserType.launch: Executable doesn't exist\" >&2
exit 1"
  gate_with_stub
  [ "$status" -eq 4 ]
  assert_stderr_names Chromium
}

@test "gate exits 4 when the report carries top-level errors such as a held port" {
  prepare_green
  stub_pnpm "printf '{\"errors\":[{\"message\":\"http://localhost:3000 is already used\"}],\"suites\":[]}' >\"\$PLAYWRIGHT_JSON_OUTPUT_NAME\"
exit 1"
  gate_with_stub
  [ "$status" -eq 4 ]
  assert_stderr_names Prerequisites
}

@test "gate runs Playwright over only the owned file with the JSON reporter and reads its report" {
  prepare_green
  stub_pnpm "printf '%s\n' \"\$@\" >'$BATS_TEST_TMPDIR/pnpm-args'
cp '$REPORTS/passed.json' \"\$PLAYWRIGHT_JSON_OUTPUT_NAME\"
exit 0"
  gate_with_stub
  [ "$status" -eq 0 ]
  [ "$(tr '\n' ' ' <"$BATS_TEST_TMPDIR/pnpm-args")" = "-C frontend exec playwright test .playwright/e2e/checkout/guest-checkout-confirms-order.spec.ts --reporter=json " ]
}

@test "gate does not start Playwright when a static check already failed" {
  write_spec
  render_specs
  stub_pnpm "echo started >'$BATS_TEST_TMPDIR/pnpm-ran'"
  gate_with_stub
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/pnpm-ran" ]
}

# --- Divergence check ---

divergence() {
  run bash -c "cd '$WORK' && bash '$DIVERGENCE' '$SPEC' --routing '$ROUTING' $* 2>'$STDERR_FILE'"
}

@test "divergence passes freshly rendered specs" {
  write_spec
  render_specs
  divergence --all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "divergence names the file, the UAT and then when the Then line was altered" {
  write_spec
  render_specs
  sed -i.bak 's#^// Then: .*#// Then: something else entirely#' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_TWO_RELATIVE UAT-002 then" ]
}

@test "divergence ignores a body edit of selectors, labels and copy" {
  write_spec
  render_specs
  green_body "$FILE_PHASE_TWO" "test('a reworded title', async ({page}) => {
  await page.getByTestId('checkout-button').click();
  await expect(page.getByText('Thanks for your order')).toBeVisible();
});"
  divergence --all
  [ "$status" -eq 0 ]
}

@test "divergence still matches a contract line reformatted only in whitespace" {
  write_spec
  render_specs
  sed -i.bak 's#^// When: .*#// When:   they   check out as a   guest   #' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  divergence --all
  [ "$status" -eq 0 ]
}

@test "divergence fails on a missing When line, naming when" {
  write_spec
  render_specs
  sed -i.bak '/^\/\/ When: /d' "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_TWO_RELATIVE UAT-002 when" ]
}

@test "divergence fails on a missing spec file, naming file" {
  write_spec
  render_specs
  rm -f "$FILE_PHASE_THREE"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_THREE_RELATIVE UAT-003 file" ]
}

@test "divergence --phase selects only that phase's rows" {
  write_spec
  render_specs
  sed -i.bak 's#^// Given: .*#// Given: nobody#' "$FILE_PHASE_THREE"
  rm -f "$FILE_PHASE_THREE.bak"
  divergence --phase 2
  [ "$status" -eq 0 ]
  divergence --phase 3
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_THREE_RELATIVE UAT-003 given" ]
}

# quoted_then_case <yaml-then-scalar> <rendered-then> <word> <replacement>:
# render, expect a match, then change one inner word of the Then line and
# expect a mismatch.
quoted_then_case() {
  write_spec "$1"
  render_specs
  divergence --all
  [ "$status" -eq 0 ]
  grep -qxF -- "// Then: $2" "$FILE_PHASE_TWO"
  sed -i.bak "/^\/\/ Then: /s/$3/$4/" "$FILE_PHASE_TWO"
  rm -f "$FILE_PHASE_TWO.bak"
  divergence --all
  [ "$status" -eq 1 ]
  [ "$output" = "$FILE_PHASE_TWO_RELATIVE UAT-002 then" ]
}

@test "divergence reads back a freshly rendered then-clause wrapped in double quotes, and flags one changed word" {
  quoted_then_case "'\"Saved\" toast reads \"Done\"'" '"Saved" toast reads "Done"' Done Finished
}

@test "divergence reads back a freshly rendered then-clause wrapped in single quotes, and flags one changed word" {
  quoted_then_case "\"'Saved' toast reads 'Done'\"" "'Saved' toast reads 'Done'" Done Finished
}

@test "divergence refuses an invalid routing table as invalid input" {
  write_spec
  render_specs
  sed -i.bak '/UAT-003/d' "$ROUTING"
  rm -f "$ROUTING.bak"
  divergence --all
  [ "$status" -eq 2 ]
}

# --- Working-document id scan ---

SCAN_TREE="scan-tree"

scan_tree() {
  mkdir -p "$BATS_TEST_TMPDIR/$SCAN_TREE/e2e"
  cat >"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts" <<'TREE_EOF'
import {test} from '@playwright/test';
test('a clean title', async () => {});
TREE_EOF
}

scan() {
  run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$SCAN' '$SCAN_TREE' 2>'$STDERR_FILE'"
}

@test "scan exits zero on a clean tree" {
  scan_tree
  scan
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "scan names path:line for an id in a test title" {
  scan_tree
  printf "test('UAT-007 shows the total', async () => {});\n" >>"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts"
  scan
  [ "$status" -eq 1 ]
  [ "$output" = "$SCAN_TREE/e2e/clean.spec.ts:3: UAT-007" ]
}

@test "scan names path:line for an id in a line comment, case-insensitively" {
  scan_tree
  printf '// derived from spec-12\n// plan-3 owns this\n' >>"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts"
  scan
  [ "$status" -eq 1 ]
  [ "$(printf '%s\n' "$output" | sed -n '1p')" = "$SCAN_TREE/e2e/clean.spec.ts:3: spec-12" ]
  [ "$(printf '%s\n' "$output" | sed -n '2p')" = "$SCAN_TREE/e2e/clean.spec.ts:4: plan-3" ]
}

@test "scan names path:line for an id in a block comment" {
  scan_tree
  printf '/*\n * covers SPEC-110\n */\n' >>"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts"
  scan
  [ "$status" -eq 1 ]
  [ "$output" = "$SCAN_TREE/e2e/clean.spec.ts:4: SPEC-110" ]
}

@test "scan names the path for an id in a path segment" {
  scan_tree
  mkdir -p "$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/uat-004-checkout"
  printf 'export {};\n' >"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/uat-004-checkout/total.spec.ts"
  scan
  [ "$status" -eq 1 ]
  [ "$output" = "$SCAN_TREE/e2e/uat-004-checkout/total.spec.ts:0: uat-004" ]
}

@test "scan ignores a hit under output/" {
  scan_tree
  mkdir -p "$BATS_TEST_TMPDIR/$SCAN_TREE/output"
  printf 'UAT-001 artifact\n' >"$BATS_TEST_TMPDIR/$SCAN_TREE/output/trace.txt"
  scan
  [ "$status" -eq 0 ]
}

@test "scan treats an id-looking word without digits as clean" {
  scan_tree
  printf '// the spec- and uat- prefixes are fine without a number\n' >>"$BATS_TEST_TMPDIR/$SCAN_TREE/e2e/clean.spec.ts"
  scan
  [ "$status" -eq 0 ]
}

@test "scan refuses a missing directory as invalid input" {
  run bash -c "cd '$BATS_TEST_TMPDIR' && bash '$SCAN' no-such-directory 2>'$STDERR_FILE'"
  [ "$status" -eq 2 ]
}

@test "scan over this repository's own Playwright tree exits zero today" {
  run bash -c "cd '$REPO_ROOT_REAL' && bash '$SCAN'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
