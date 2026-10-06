#!/usr/bin/env bats
#
# .gaia/scripts/spec/uat-write.sh behavior: routed rendering, the contract
# marker and body hash, the preserve/rewrite/delete/conflict decision table,
# the render ledger, quoting, the working-document id refusal and routing
# validation. Shell level only: no Node, no browser.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/uat-write.sh"
  LIB="$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK/plan"
  SPEC="$WORK/SPEC.md"
  ROUTING="$WORK/plan/README.md"
  LEDGER="$WORK/plan/uat-render.json"
  E2E="$WORK/frontend/.playwright/e2e"
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  # shellcheck source=.gaia/scripts/spec/uat-lib.sh
  source "$LIB"
}

# write_routing <row>...: the routing table with the given body rows.
write_routing() {
  {
    printf '# Plan\n\n<!-- gaia:uat-routing:start -->\n'
    printf '| uat_id | surface | phase | feature_folder | file_name |\n|---|---|---|---|---|\n'
    printf '%s\n' "$@"
    printf '<!-- gaia:uat-routing:end -->\n'
  } >"$ROUTING"
}

# render [<extra-arg>...]: run the renderer from the fixture root; stdout lands
# in $output, stderr in $STDERR_FILE.
render() {
  local extra=''
  local argument
  for argument in "$@"; do
    extra="$extra '$argument'"
  done
  run bash -c "cd '$WORK' && bash '$SCRIPT' '$SPEC' --routing '$ROUTING'$extra 2>'$STDERR_FILE'"
}

detail_field() {
  jq -r --arg path "$1" --arg field "$2" '.details[] | select(.path == $path) | .[$field] // ""' <<<"$output"
}

contract_line() {
  awk -v prefix="// $2: " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' "$1"
}

assert_nothing_written() {
  [ ! -e "$E2E" ] || return 1
  [ ! -e "$LEDGER" ]
}

write_two_uat_spec() {
  cat >"$SPEC" <<EOF
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they check out as a guest
    then: the confirmation page shows the order number
  - uat_id: UAT-002
    given: a signed in member
    when: they open the order history
    then: ${1:-every past order is listed newest first}
---
EOF
  write_routing \
    '| UAT-001 | e2e | 1 | checkout | guest-checkout-confirms-order.spec.ts |' \
    '| UAT-002 | e2e | 2 | orders | order-history-lists-orders.spec.ts |'
}

FILE_A_RELATIVE='frontend/.playwright/e2e/checkout/guest-checkout-confirms-order.spec.ts'
FILE_B_RELATIVE='frontend/.playwright/e2e/orders/order-history-lists-orders.spec.ts'

edit_body() {
  sed -i.bak 's/expect(false, outcome.text).toBe(true);/expect(false, `edited: ${outcome.text}`).toBe(true);/' "$1"
  rm -f "$1.bak"
  grep -qF -- 'edited: ' "$1"
}

@test "only the e2e-routed UAT renders, at its routed path, with marker, hash, contract and an expected failure" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they check out as a guest
    then: the confirmation page shows the order number
  - uat_id: UAT-002
    given: a product card story
    when: the card renders
    then: the price is visible
  - uat_id: UAT-003
    given: a ledger row
    when: the reconcile script runs
    then: the row is stamped merged
---
EOF
  write_routing \
    '| UAT-001 | e2e | 2 | checkout | guest-checkout-confirms-order.spec.ts |' \
    '| UAT-002 | story | 3 | - | - |' \
    '| UAT-003 | non-ui | 1 | - | - |'

  render
  [ "$status" -eq 0 ]
  expected_files="$E2E/checkout/guest-checkout-confirms-order.spec.ts"
  actual_files=$(find "$E2E" -type f | LC_ALL=C sort)
  [ "$actual_files" = "$expected_files" ] || return 1

  file="$expected_files"
  head -n 1 "$file" | grep -qE '^// gaia-uat-contract sha256:[0-9a-f]{64}$' || return 1
  [ "$(uat_lib_embedded_hash "$file")" = "$(uat_lib_body_hash "$file")" ] || return 1
  [ "$(contract_line "$file" Given)" = "a visitor with items in the cart" ] || return 1
  [ "$(contract_line "$file" When)" = "they check out as a guest" ] || return 1
  [ "$(contract_line "$file" Then)" = "the confirmation page shows the order number" ] || return 1
  grep -qF -- 'test.fail(' "$file" || return 1
  grep -qxF -- "  text: 'the confirmation page shows the order number'," "$file" || return 1
  grep -qxF -- '  expect(false, outcome.text).toBe(true);' "$file" || return 1
  grep -qiE '(SPEC|UAT|PLAN)-[0-9]+' <<<"$file" && return 1
  grep -qiE '(SPEC|UAT|PLAN)-[0-9]+' "$file" && return 1
  [ "$(detail_field "$FILE_A_RELATIVE" action)" = "written" ]
}

@test "a routing table with no e2e rows writes nothing under the e2e directory and reports zero counts" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a product card story
    when: the card renders
    then: the price is visible
  - uat_id: UAT-002
    given: a ledger row
    when: the reconcile script runs
    then: the row is stamped merged
---
EOF
  write_routing '| UAT-001 | story | 1 | - | - |' '| UAT-002 | non-ui | 1 | - | - |'

  render
  [ "$status" -eq 0 ]
  if [ -e "$E2E" ]; then
    [ -z "$(find "$E2E" -mindepth 1)" ] || return 1
  fi
  grep -qF -- '"summary":{"written":0,"rewritten":0,"unchanged":0,"preserved":0,"deleted":0,"conflict":0}' <<<"$output"
}

@test "an edited spec of an unchanged UAT is preserved and an unedited spec of a changed UAT is rewritten, with the cache gone" {
  write_two_uat_spec
  render
  [ "$status" -eq 0 ]
  file_a="$WORK/$FILE_A_RELATIVE"
  file_b="$WORK/$FILE_B_RELATIVE"
  edit_body "$file_a"
  cp "$file_a" "$BATS_TEST_TMPDIR/a.saved"
  write_two_uat_spec 'every past order is listed with its status'
  mkdir -p "$WORK/.gaia/local/cache/uat-write"
  rm -rf "$WORK/.gaia/local/cache"

  render
  [ "$status" -eq 0 ]
  cmp -s "$file_a" "$BATS_TEST_TMPDIR/a.saved" || return 1
  [ "$(uat_lib_embedded_hash "$file_a")" != "$(uat_lib_body_hash "$file_a")" ] || return 1
  [ "$(contract_line "$file_b" Then)" = "every past order is listed with its status" ] || return 1
  [ "$(uat_lib_embedded_hash "$file_b")" = "$(uat_lib_body_hash "$file_b")" ] || return 1
  [ "$(detail_field "$FILE_A_RELATIVE" action)" = "preserved" ] || return 1
  [ "$(detail_field "$FILE_B_RELATIVE" action)" = "rewritten" ] || return 1
  [ ! -e "$WORK/.gaia/local/cache" ]
}

@test "an edited spec whose UAT changed is a conflict left byte-identical, other actions still apply, and --overwrite replaces it" {
  write_two_uat_spec
  render
  [ "$status" -eq 0 ]
  file_a="$WORK/$FILE_A_RELATIVE"
  file_b="$WORK/$FILE_B_RELATIVE"
  edit_body "$file_b"
  cp "$file_b" "$BATS_TEST_TMPDIR/b.saved"
  write_two_uat_spec 'every past order is listed with its status'
  sed -i.bak 's/then: the confirmation page shows the order number/then: the confirmation page shows the order total/' "$SPEC"
  grep -qF -- 'shows the order total' "$SPEC" || return 1

  render
  [ "$status" -eq 3 ]
  cmp -s "$file_b" "$BATS_TEST_TMPDIR/b.saved" || return 1
  [ "$(detail_field "$FILE_B_RELATIVE" action)" = "conflict" ] || return 1
  [ "$(detail_field "$FILE_B_RELATIVE" reason)" = "changed-and-edited" ] || return 1
  [ "$(detail_field "$FILE_A_RELATIVE" action)" = "rewritten" ] || return 1
  [ "$(contract_line "$file_a" Then)" = "the confirmation page shows the order total" ] || return 1

  render --overwrite "$FILE_B_RELATIVE"
  [ "$status" -eq 0 ]
  [ "$(detail_field "$FILE_B_RELATIVE" action)" = "rewritten" ] || return 1
  [ "$(contract_line "$file_b" Then)" = "every past order is listed with its status" ] || return 1
  [ "$(uat_lib_embedded_hash "$file_b")" = "$(uat_lib_body_hash "$file_b")" ]
}

@test "a hand-written neighbour is untouched, an unedited removed UAT's spec is deleted, an edited re-routed one is a conflict" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they remove an item
    then: the cart total drops
  - uat_id: UAT-002
    given: a visitor with items in the cart
    when: they apply a coupon
    then: the discount line appears
---
EOF
  write_routing \
    '| UAT-001 | e2e | 1 | cart | cart-total-drops.spec.ts |' \
    '| UAT-002 | e2e | 1 | cart | coupon-discount-appears.spec.ts |'
  render
  [ "$status" -eq 0 ]
  hand_written="$E2E/cart/cart-hand-written.spec.ts"
  printf "import {test} from '@playwright/test';\n\ntest('hand written', () => {});\n" >"$hand_written"
  cp "$hand_written" "$BATS_TEST_TMPDIR/hand.saved"
  removed="$E2E/cart/cart-total-drops.spec.ts"
  rerouted="$E2E/cart/coupon-discount-appears.spec.ts"
  edit_body "$rerouted"
  cp "$rerouted" "$BATS_TEST_TMPDIR/rerouted.saved"

  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-002
    given: a visitor with items in the cart
    when: they apply a coupon
    then: the discount line appears
---
EOF
  write_routing '| UAT-002 | story | 1 | - | - |'

  render
  [ "$status" -eq 3 ]
  cmp -s "$hand_written" "$BATS_TEST_TMPDIR/hand.saved" || return 1
  [ -z "$(detail_field 'frontend/.playwright/e2e/cart/cart-hand-written.spec.ts' action)" ] || return 1
  [ ! -e "$removed" ] || return 1
  [ "$(detail_field 'frontend/.playwright/e2e/cart/cart-total-drops.spec.ts' action)" = "deleted" ] || return 1
  cmp -s "$rerouted" "$BATS_TEST_TMPDIR/rerouted.saved" || return 1
  [ "$(detail_field 'frontend/.playwright/e2e/cart/coupon-discount-appears.spec.ts' action)" = "conflict" ] || return 1
  [ "$(detail_field 'frontend/.playwright/e2e/cart/coupon-discount-appears.spec.ts' reason)" = "removed-or-rerouted-and-edited" ] || return 1

  ledger_paths=$(jq -r '.rendered[].path' "$LEDGER")
  [ "$ledger_paths" = "frontend/.playwright/e2e/cart/coupon-discount-appears.spec.ts" ]
}

@test "a marker-less file at a routed path is a conflict and stays byte-identical" {
  write_two_uat_spec
  mkdir -p "$E2E/checkout"
  printf "import {test} from '@playwright/test';\n\ntest('mine', () => {});\n" >"$WORK/$FILE_A_RELATIVE"
  cp "$WORK/$FILE_A_RELATIVE" "$BATS_TEST_TMPDIR/unmarked.saved"

  render
  [ "$status" -eq 3 ]
  cmp -s "$WORK/$FILE_A_RELATIVE" "$BATS_TEST_TMPDIR/unmarked.saved" || return 1
  [ "$(detail_field "$FILE_A_RELATIVE" action)" = "conflict" ] || return 1
  [ "$(detail_field "$FILE_A_RELATIVE" reason)" = "unmarked-file-at-target" ] || return 1
  [ "$(detail_field "$FILE_B_RELATIVE" action)" = "written" ]
}

@test "apostrophes, ampersands, backslashes and double quotes reach the contract lines verbatim and the JS literal escaped" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor's "cart" & a C:\carts folder
    when: they press "Save" & the user's C:\tmp path loads
    then: the user's "Saved" note & the C:\tmp\x path appear
  - uat_id: UAT-002
    given: a visitor's "cart" & a C:\carts folder
    when: they press "Save" & the user's C:\tmp path loads
    then: it's "a" "b" C:\x & a `tick`
---
EOF
  write_routing \
    '| UAT-001 | e2e | 1 | quoting | raw-literal.spec.ts |' \
    '| UAT-002 | e2e | 1 | quoting | quoted-literal.spec.ts |'

  render
  [ "$status" -eq 0 ]
  raw_file="$E2E/quoting/raw-literal.spec.ts"
  quoted_file="$E2E/quoting/quoted-literal.spec.ts"
  expected_given=$(printf '%s' "a visitor's \"cart\" & a C:\\carts folder" | uat_lib_canonical_text)
  expected_when=$(printf '%s' "they press \"Save\" & the user's C:\\tmp path loads" | uat_lib_canonical_text)
  expected_then=$(printf '%s' "the user's \"Saved\" note & the C:\\tmp\\x path appear" | uat_lib_canonical_text)
  [ "$(contract_line "$raw_file" Given)" = "$expected_given" ] || return 1
  [ "$(contract_line "$raw_file" When)" = "$expected_when" ] || return 1
  [ "$(contract_line "$raw_file" Then)" = "$expected_then" ] || return 1

  # A backslash with no backtick or template opener renders as String.raw, verbatim.
  grep -qxF -- "  text: String.raw\`$expected_then\`," "$raw_file" || return 1

  # A backtick rules String.raw out: a quoted literal with \\ and \' escapes.
  literal_line=$(grep -E '^  text: ' "$quoted_file")
  [ "$literal_line" = "  text: 'it\\'s \"a\" \"b\" C:\\\\x & a \`tick\`'," ] || return 1
  inner=${literal_line#  text: \'}
  inner=${inner%\',}
  stripped=$(printf '%s' "$inner" | sed -e 's/\\\\//g' -e "s/\\\\'//g")
  grep -qF -- "'" <<<"$stripped" && return 1

  for file in "$raw_file" "$quoted_file"; do
    grep -qE 'UAT_|CONTRACT_MARKER|\$\{UAT' "$file" && return 1
    [ "$(grep -c -F -- '&' "$file")" -ge 4 ] || return 1
  done
  true
}

@test "plain, double-quoted and single-quoted YAML forms of one value canonicalize to the same text" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor's "cart" & C:\x
    when: plain
    then: the same
  - uat_id: UAT-002
    given: "a visitor's \"cart\" & C:\\x"
    when: double
    then: the same
  - uat_id: UAT-003
    given: 'a visitor''s "cart" & C:\x'
    when: single
    then: the same
---
EOF
  write_routing \
    '| UAT-001 | e2e | 1 | quoting | plain-form.spec.ts |' \
    '| UAT-002 | e2e | 1 | quoting | double-form.spec.ts |' \
    '| UAT-003 | e2e | 1 | quoting | single-form.spec.ts |'

  givens=$(uat_lib_parse_spec "$SPEC" | cut -f2 | LC_ALL=C sort -u)
  [ "$givens" = "a visitor's \"cart\" & C:\\x" ] || return 1

  render
  [ "$status" -eq 0 ]
  for form in plain double single; do
    [ "$(contract_line "$E2E/quoting/$form-form.spec.ts" Given)" = "a visitor's \"cart\" & C:\\x" ] || return 1
  done
  true
}

@test "an e2e-routed UAT carrying a working-document id is refused and nothing is written; routed non-ui it renders" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they check out as a guest
    then: the confirmation page shows the order number
  - uat_id: UAT-002
    given: a reopened requirement
    when: the follow-up lands
    then: the behavior from SPEC-12 holds
---
EOF
  write_routing \
    '| UAT-001 | e2e | 1 | checkout | guest-checkout-confirms-order.spec.ts |' \
    '| UAT-002 | e2e | 1 | followup | follow-up-holds.spec.ts |'

  render
  [ "$status" -eq 2 ]
  grep -qF -- 'UAT-002 then carries a working-document id' "$STDERR_FILE" || return 1
  assert_nothing_written || return 1

  write_routing \
    '| UAT-001 | e2e | 1 | checkout | guest-checkout-confirms-order.spec.ts |' \
    '| UAT-002 | non-ui | 1 | - | - |'
  render
  [ "$status" -eq 0 ]
  [ -f "$WORK/$FILE_A_RELATIVE" ]
}

write_routing_fixture_spec() {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they check out as a guest
    then: the confirmation page shows the order number
  - uat_id: UAT-002
    given: a signed in member
    when: they open the order history
    then: every past order is listed newest first
---
EOF
}

# assert_routing_refused <expected-stderr-substring> <row>...
assert_routing_refused() {
  local expected="$1"
  shift
  write_routing_fixture_spec
  write_routing "$@"
  render
  [ "$status" -eq 2 ] || return 1
  grep -qF -- "$expected" "$STDERR_FILE" || return 1
  assert_nothing_written
}

VALID_ROW_ONE='| UAT-001 | e2e | 1 | checkout | guest-checkout-confirms-order.spec.ts |'
VALID_ROW_TWO='| UAT-002 | non-ui | 2 | - | - |'

@test "routing validation: a valid table renders (the twin that keeps the refusals honest)" {
  write_routing_fixture_spec
  write_routing "$VALID_ROW_ONE" "$VALID_ROW_TWO"
  render
  [ "$status" -eq 0 ]
  [ -f "$WORK/$FILE_A_RELATIVE" ]
}

@test "routing validation: missing markers are refused" {
  write_routing_fixture_spec
  printf '| uat_id | surface | phase | feature_folder | file_name |\n|---|---|---|---|---|\n%s\n%s\n' "$VALID_ROW_ONE" "$VALID_ROW_TWO" >"$ROUTING"
  render
  [ "$status" -eq 2 ]
  grep -qF -- 'markers are missing or unbalanced' "$STDERR_FILE" || return 1
  assert_nothing_written
}

@test "routing validation: an unbalanced start marker is refused" {
  write_routing_fixture_spec
  write_routing "$VALID_ROW_ONE" "$VALID_ROW_TWO"
  printf '<!-- gaia:uat-routing:start -->\n' >>"$ROUTING"
  render
  [ "$status" -eq 2 ]
  grep -qF -- 'markers are missing or unbalanced' "$STDERR_FILE" || return 1
  assert_nothing_written
}

@test "routing validation: a SPEC UAT with no row is refused" {
  assert_routing_refused 'UAT-002 has no routing row' "$VALID_ROW_ONE"
}

@test "routing validation: a row for an id the SPEC lacks is refused" {
  assert_routing_refused 'UAT-009 is routed but absent from the SPEC' "$VALID_ROW_ONE" "$VALID_ROW_TWO" '| UAT-009 | non-ui | 1 | - | - |'
}

@test "routing validation: a duplicated id is refused" {
  assert_routing_refused 'UAT-002 has more than one row' "$VALID_ROW_ONE" "$VALID_ROW_TWO" '| UAT-002 | story | 1 | - | - |'
}

@test "routing validation: an invalid surface is refused" {
  assert_routing_refused "UAT-002 has surface 'browser'" "$VALID_ROW_ONE" '| UAT-002 | browser | 2 | - | - |'
}

@test "routing validation: a non-integer phase is refused" {
  assert_routing_refused "UAT-002 has phase 'two'" "$VALID_ROW_ONE" '| UAT-002 | non-ui | two | - | - |'
}

@test "routing validation: an e2e row without a folder and file is refused" {
  assert_routing_refused "UAT-002 is e2e with feature_folder '-'" "$VALID_ROW_ONE" '| UAT-002 | e2e | 2 | - | - |'
}

@test "routing validation: an e2e file name without the .spec.ts suffix is refused" {
  assert_routing_refused "expected a kebab-case name ending .spec.ts" "$VALID_ROW_ONE" '| UAT-002 | e2e | 2 | orders | order-history.ts |'
}

@test "routing validation: a working-document id in an e2e file name is refused" {
  assert_routing_refused "carries a working-document id" "$VALID_ROW_ONE" '| UAT-002 | e2e | 2 | orders | uat-002-order-history.spec.ts |'
}

@test "routing validation: two e2e rows on one path are refused" {
  assert_routing_refused "a path another e2e row already claims" "$VALID_ROW_ONE" '| UAT-002 | e2e | 2 | checkout | guest-checkout-confirms-order.spec.ts |'
}

@test "re-running on unchanged inputs reports every file unchanged and leaves a clean tree" {
  write_two_uat_spec
  render
  [ "$status" -eq 0 ]
  git -C "$WORK" init -q
  git -C "$WORK" add -A
  git -C "$WORK" -c user.name=fixture -c user.email=fixture@example.com commit -q -m fixture

  render
  [ "$status" -eq 0 ]
  [ "$(detail_field "$FILE_A_RELATIVE" action)" = "unchanged" ] || return 1
  [ "$(detail_field "$FILE_B_RELATIVE" action)" = "unchanged" ] || return 1
  [ "$(jq -r '.details | length' <<<"$output")" -eq 2 ] || return 1
  [ -z "$(git -C "$WORK" status --porcelain)" ]
}

@test "a then-clause wrapped in double quotes is a fixed point: rendered, read back and re-rendered unchanged" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a saved draft
    when: the save completes
    then: '"Saved" toast reads "Done"'
---
EOF
  write_routing '| UAT-001 | e2e | 1 | drafts | saved-toast-reads-done.spec.ts |'
  file="$E2E/drafts/saved-toast-reads-done.spec.ts"

  render
  [ "$status" -eq 0 ]
  [ "$(contract_line "$file" Then)" = '"Saved" toast reads "Done"' ] || return 1
  [ "$(uat_lib_contract "$file" | cut -f3)" = '"Saved" toast reads "Done"' ] || return 1
  render
  [ "$status" -eq 0 ]
  [ "$(detail_field 'frontend/.playwright/e2e/drafts/saved-toast-reads-done.spec.ts' action)" = "unchanged" ] || return 1

  # The reason readers use the whitespace pass only: a second full
  # canonicalization strips the clause's own outer quotes.
  recanonicalized=$(printf '%s' '"Saved" toast reads "Done"' | uat_lib_canonical_text)
  [ "$recanonicalized" = 'Saved" toast reads "Done' ] || return 1
  [ "$recanonicalized" != '"Saved" toast reads "Done"' ]
}

@test "a then-clause wrapped in single quotes is a fixed point too" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a saved draft
    when: the save completes
    then: "'Saved' toast reads 'Done'"
---
EOF
  write_routing '| UAT-001 | e2e | 1 | drafts | saved-toast-reads-done.spec.ts |'
  file="$E2E/drafts/saved-toast-reads-done.spec.ts"

  render
  [ "$status" -eq 0 ]
  [ "$(contract_line "$file" Then)" = "'Saved' toast reads 'Done'" ] || return 1
  [ "$(uat_lib_contract "$file" | cut -f3)" = "'Saved' toast reads 'Done'" ] || return 1
  render
  [ "$status" -eq 0 ]
  [ "$(detail_field 'frontend/.playwright/e2e/drafts/saved-toast-reads-done.spec.ts' action)" = "unchanged" ]
}

@test "no run writes a cache under .gaia/local/cache" {
  write_two_uat_spec
  render
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/.gaia/local/cache/uat-write" ] || return 1
  [ ! -e "$WORK/.gaia/local" ]
}

@test "the render ledger beside the routing file lists every e2e path" {
  write_two_uat_spec
  render
  [ "$status" -eq 0 ]
  expected_paths=$(printf '%s\n%s\n' "$FILE_A_RELATIVE" "$FILE_B_RELATIVE" | LC_ALL=C sort)
  [ "$(jq -r '.rendered[].path' "$LEDGER")" = "$expected_paths" ] || return 1
  [ "$(jq -r '.rendered[] | select(.path == "'"$FILE_A_RELATIVE"'") | .uat_id' "$LEDGER")" = "UAT-001" ]
}

@test "canonical text folds continuation lines and normalizes whitespace; the whitespace pass is the identity on canonical text" {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor	with   a tab
      and a folded continuation
    when: they act
    then: the result shows
---
EOF
  [ "$(uat_lib_parse_spec "$SPEC" | cut -f2)" = "a visitor with a tab and a folded continuation" ] || return 1
  canonical='"Saved" toast reads "Done"'
  [ "$(printf '%s' "$canonical" | uat_lib_whitespace_text)" = "$canonical" ]
}
