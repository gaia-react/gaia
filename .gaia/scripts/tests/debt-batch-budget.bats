#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-batch-budget.sh, the /gaia-debt named-batch
# budget. The cost table is driven row by row, then each edge rule, the exact
# ranked subset offer, maximality of every offered subset, every refusal and
# unreadable-input arm, and the data-not-command-text property.
#
# The script is resolved from DEBT_BATCH_BUDGET_SCRIPT when set, so a mutated
# scratch copy can be run through the same assertions to prove they can fail.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/debt-batch-budget.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${DEBT_BATCH_BUDGET_SCRIPT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-batch-budget.sh}"
  BRANCH_LIBRARY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/branch-name-lib.sh"
  BACKLOG="$BATS_TEST_TMPDIR/backlog.json"
  export SCRIPT
}

# write_rows <file> <item>...: a backlog of one member per item, numbered 1..n
# in order, every one severity 1. An item is <difficulty>:<footprint>:<dir>,
# with "-" for null; each member's path is <dir>/file<number>.ts, so two items
# sharing a <dir> share a directory.
write_rows() {
  local file="$1" item difficulty footprint directory index=0 members=""
  shift
  for item in "$@"; do
    index=$((index + 1))
    IFS=: read -r difficulty footprint directory <<<"$item"
    members="$members$(jq -nc --argjson number "$index" --arg d "$difficulty" \
      --arg f "$footprint" --arg dir "$directory" \
      '{number: $number, sev: 1,
        difficulty: (if $d == "-" then null else $d end),
        footprint: (if $f == "-" then null else $f end),
        key: {class: "c", path: "\($dir)/file\($number).ts", line: 1},
        body: "no path cited here"}'),"
  done
  printf '[%s]' "${members%,}" >"$file"
}

# first_numbers <count>: sets NUMBERS to 1..count.
first_numbers() {
  local number=1
  NUMBERS=()
  while [ "$number" -le "$1" ]; do
    NUMBERS+=("$number")
    number=$((number + 1))
  done
}

score() {
  run --separate-stderr bash "$SCRIPT" --backlog "$BACKLOG" "$@"
}

# member_field <number> <field>: one field of one member of $output.
member_field() {
  printf '%s' "$output" | jq -r --argjson n "$1" ".members[] | select(.number == \$n) | .$2"
}

# subsets_compact: the subsets array of $output on one line.
subsets_compact() {
  printf '%s' "$output" | jq -c '.subsets'
}

# write_fixture_one: the four-member subset fixture, in backlog order.
write_fixture_one() {
  cat >"$BACKLOG" <<'EOF'
[
  {"number": 101, "sev": 3, "difficulty": "hard",   "footprint": "narrow", "key": {"class": "c", "path": "a/x.ts", "line": 1}},
  {"number": 102, "sev": 2, "difficulty": "medium", "footprint": "wide",   "key": {"class": "c", "path": "b/x.ts", "line": 1}},
  {"number": 103, "sev": 2, "difficulty": "easy",   "footprint": "wide",   "key": {"class": "c", "path": "b/y.ts", "line": 1}},
  {"number": 104, "sev": 1, "difficulty": "medium", "footprint": "narrow", "key": {"class": "c", "path": "c/x.ts", "line": 1}}
]
EOF
}

# expect_refusal <args...>: exit 2, empty stdout, a debt-batch-budget: line.
expect_refusal() {
  score "$@"
  [ "$status" -eq 2 ] || { echo "status $status for: $*" >&2; return 1; }
  [ -z "$output" ] || { echo "stdout not empty for: $*" >&2; return 1; }
  [[ "$stderr" == "debt-batch-budget: "* ]] || { echo "stderr was: $stderr" >&2; return 1; }
}

# ========== calibration ==========

@test "calibration: every cost-table row yields its exact total, verdict, and exit status" {
  local rows=(
    "8|fits|medium:narrow:d1 medium:narrow:d2 easy:narrow:d3"
    "14|over|medium:wide:d1 medium:wide:d2 easy:wide:d3"
    "8|fits|medium:wide:s medium:wide:s easy:wide:s"
    "9|fits|hard:narrow:d1 easy:narrow:d2"
    "10|fits|hard:narrow:d1 medium:narrow:d2"
    "14|over|hard:wide:d1 medium:wide:d2"
    "14|over|hard:narrow:d1 hard:narrow:d2"
    "12|fits|medium:narrow:d1 medium:narrow:d2 medium:narrow:d3 medium:narrow:d4"
    "14|over|medium:narrow:d1 medium:narrow:d2 medium:narrow:d3 medium:wide:d4"
    "10|fits|easy:narrow:d1 easy:narrow:d2 easy:narrow:d3 easy:narrow:d4 easy:narrow:d5"
    "12|fits|easy:wide:d1 easy:wide:d2 easy:wide:d3"
    "16|over|easy:wide:d1 easy:wide:d2 easy:wide:d3 easy:wide:d4"
    "13|over|hard:wide:d1 easy:wide:d2"
    "11|fits|hard:narrow:d1 easy:wide:d2"
    "3|fits|-:narrow:d1"
    "7|fits|medium:-:d1 easy:narrow:d2"
  )
  local row ran=0 expected_total expected_verdict items expected_status count
  for row in "${rows[@]}"; do
    IFS='|' read -r expected_total expected_verdict items <<<"$row"
    # shellcheck disable=SC2086 # the items are space-separated on purpose
    write_rows "$BACKLOG" $items
    count="$(printf '%s\n' $items | wc -l | tr -d ' ')"
    first_numbers "$count"
    score "${NUMBERS[@]}"
    expected_status=0
    [ "$expected_verdict" = "over" ] && expected_status=1
    [ "$status" -eq "$expected_status" ] || { echo "row [$row] status $status" >&2; return 1; }
    [ "$(printf '%s' "$output" | jq -r '.total')" = "$expected_total" ] || { echo "row [$row] total" >&2; return 1; }
    [ "$(printf '%s' "$output" | jq -r '.verdict')" = "$expected_verdict" ] || { echo "row [$row] verdict" >&2; return 1; }
    ran=$((ran + 1))
  done
  [ "${#rows[@]}" -eq 16 ]
  [ "$ran" -eq "${#rows[@]}" ]
}

# ========== edge rules ==========

@test "edge: a keyless wide member and a keyed wide member both pay, the body earns nothing" {
  cat >"$BACKLOG" <<'EOF'
[
  {"number": 1, "sev": 1, "difficulty": "medium", "footprint": "wide", "key": null, "body": "fix it in a/x.ts:3"},
  {"number": 2, "sev": 1, "difficulty": "medium", "footprint": "wide", "key": {"class": "c", "path": "a/x.ts", "line": 3}}
]
EOF
  score 1 2
  [ "$status" -eq 0 ]
  [ "$(member_field 1 directory)" = "null" ]
  [ "$(member_field 1 surcharge)" = "2" ]
  [ "$(member_field 1 waived)" = "false" ]
  [ "$(member_field 1 cost)" = "5" ]
  [ "$(member_field 2 directory)" = "a" ]
  [ "$(member_field 2 surcharge)" = "2" ]
  [ "$(member_field 2 waived)" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "10" ]
}

@test "edge: root-level paths never earn a waiver" {
  cat >"$BACKLOG" <<'EOF'
[
  {"number": 1, "sev": 1, "difficulty": "medium", "footprint": "wide", "key": {"class": "c", "path": "README.md", "line": 1}},
  {"number": 2, "sev": 1, "difficulty": "medium", "footprint": "wide", "key": {"class": "c", "path": "CHANGELOG.md", "line": 1}}
]
EOF
  score 1 2
  [ "$(member_field 1 directory)" = "." ]
  [ "$(member_field 2 directory)" = "." ]
  [ "$(member_field 1 waived)" = "false" ]
  [ "$(member_field 2 waived)" = "false" ]
  [ "$(member_field 1 surcharge)" = "2" ]
  [ "$(member_field 2 surcharge)" = "2" ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "10" ]
}

@test "edge: a wide member is waived by a narrow partner in the same directory" {
  cat >"$BACKLOG" <<'EOF'
[
  {"number": 1, "sev": 1, "difficulty": "medium", "footprint": "narrow", "key": {"class": "c", "path": "src/a/x.ts", "line": 1}},
  {"number": 2, "sev": 1, "difficulty": "medium", "footprint": "wide",   "key": {"class": "c", "path": "src/a/y.ts", "line": 1}}
]
EOF
  score 1 2
  [ "$status" -eq 0 ]
  [ "$(member_field 1 waived)" = "false" ]
  [ "$(member_field 1 surcharge)" = "0" ]
  [ "$(member_field 2 directory)" = "src/a" ]
  [ "$(member_field 2 waived)" = "true" ]
  [ "$(member_field 2 surcharge)" = "0" ]
  [ "$(member_field 2 cost)" = "3" ]
}

@test "edge: an unknown difficulty costs the medium base" {
  cat >"$BACKLOG" <<'EOF'
[{"number": 1, "sev": 1, "difficulty": "extreme", "footprint": "narrow", "key": null}]
EOF
  score 1
  [ "$status" -eq 0 ]
  [ "$(member_field 1 difficulty)" = "extreme" ]
  [ "$(member_field 1 base)" = "3" ]
  [ "$(member_field 1 cost)" = "3" ]
}

@test "edge: an unknown footprint pays the surcharge" {
  cat >"$BACKLOG" <<'EOF'
[{"number": 1, "sev": 1, "difficulty": "easy", "footprint": "huge", "key": null}]
EOF
  score 1
  [ "$status" -eq 0 ]
  [ "$(member_field 1 surcharge)" = "2" ]
  [ "$(member_field 1 waived)" = "false" ]
  [ "$(member_field 1 cost)" = "4" ]
}

@test "edge: a key object with an empty path has no directory" {
  cat >"$BACKLOG" <<'EOF'
[
  {"number": 1, "sev": 1, "difficulty": "easy", "footprint": "wide", "key": {"class": "c", "path": "", "line": 1}},
  {"number": 2, "sev": 1, "difficulty": "easy", "footprint": "wide", "key": {"class": "c", "path": "", "line": 1}}
]
EOF
  score 1 2
  [ "$(member_field 1 directory)" = "null" ]
  [ "$(member_field 2 directory)" = "null" ]
  [ "$(member_field 1 waived)" = "false" ]
  [ "$(member_field 1 surcharge)" = "2" ]
}

# ========== subset offer ==========

@test "subsets: the first fixture offers the exact ranked subsets" {
  write_fixture_one
  score 101 102 103 104
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "15" ]
  [ "$(subsets_compact)" = '[{"members":[101,102,103],"total":12,"recommended":true},{"members":[102,103,104],"total":8,"recommended":false},{"members":[101,104],"total":10,"recommended":false}]' ]
}

@test "subsets: argv order does not change the document" {
  write_fixture_one
  score 101 102 103 104
  local in_order="$output"
  score 104 101 103 102
  [ "$status" -eq 1 ]
  [ "$output" = "$in_order" ]
}

@test "subsets: equal-severity ties break on the lower backlog positions" {
  cat >"$BACKLOG" <<'EOF'
[
  {"number": 201, "sev": 2, "difficulty": "hard", "footprint": "narrow", "key": {"class": "c", "path": "a/x.ts", "line": 1}},
  {"number": 202, "sev": 2, "difficulty": "hard", "footprint": "narrow", "key": {"class": "c", "path": "b/x.ts", "line": 1}}
]
EOF
  score 201 202
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "14" ]
  [ "$(subsets_compact)" = '[{"members":[201],"total":7,"recommended":true},{"members":[202],"total":7,"recommended":false}]' ]
}

@test "subsets: among equal sizes the higher severity ranks first even at a later backlog position" {
  cat >"$BACKLOG" <<'EOF'
[
  {"number": 201, "sev": 1, "difficulty": "hard", "footprint": "narrow", "key": {"class": "c", "path": "a/x.ts", "line": 1}},
  {"number": 202, "sev": 3, "difficulty": "hard", "footprint": "narrow", "key": {"class": "c", "path": "b/x.ts", "line": 1}}
]
EOF
  score 201 202
  [ "$status" -eq 1 ]
  [ "$(subsets_compact)" = '[{"members":[202],"total":7,"recommended":true},{"members":[201],"total":7,"recommended":false}]' ]
}

@test "subsets: every offered subset fits and no named member can be added to it" {
  cat >"$BACKLOG" <<'EOF'
[
  {"number": 11, "sev": 3, "difficulty": "hard",   "footprint": "narrow", "key": {"class": "c", "path": "a/x.ts", "line": 1}},
  {"number": 12, "sev": 2, "difficulty": "medium", "footprint": "wide",   "key": {"class": "c", "path": "b/x.ts", "line": 1}},
  {"number": 13, "sev": 2, "difficulty": "easy",   "footprint": "wide",   "key": {"class": "c", "path": "b/y.ts", "line": 1}},
  {"number": 14, "sev": 1, "difficulty": "medium", "footprint": "narrow", "key": {"class": "c", "path": "c/x.ts", "line": 1}},
  {"number": 15, "sev": 1, "difficulty": "easy",   "footprint": "narrow", "key": {"class": "c", "path": "d/x.ts", "line": 1}},
  {"number": 16, "sev": 2, "difficulty": "hard",   "footprint": "wide",   "key": {"class": "c", "path": "e/x.ts", "line": 1}},
  {"number": 17, "sev": 1, "difficulty": "easy",   "footprint": "wide",   "key": {"class": "c", "path": "f/x.ts", "line": 1}}
]
EOF
  local named=() number
  while IFS= read -r number; do named+=("$number"); done < <(jq -r '.[].number' "$BACKLOG")
  [ "${#named[@]}" -eq 7 ]
  score "${named[@]}"
  [ "$status" -eq 1 ]
  local offered
  offered="$(printf '%s' "$output" | jq -c '.subsets[].members')"
  local subset_count=0 checks=0 expected_checks=0 members extra in_subset
  while IFS= read -r members; do
    [ -n "$members" ] || continue
    subset_count=$((subset_count + 1))
    local subset=()
    while IFS= read -r number; do subset+=("$number"); done < <(printf '%s' "$members" | jq -r '.[]')
    expected_checks=$((expected_checks + 1 + ${#named[@]} - ${#subset[@]}))
    score "${subset[@]}"
    [ "$status" -eq 0 ] || { echo "subset $members does not fit" >&2; return 1; }
    checks=$((checks + 1))
    for extra in "${named[@]}"; do
      in_subset=0
      for number in "${subset[@]}"; do [ "$number" = "$extra" ] && in_subset=1; done
      [ "$in_subset" -eq 0 ] || continue
      score "${subset[@]}" "$extra"
      [ "$status" -eq 1 ] || { echo "subset $members is not maximal: $extra fits" >&2; return 1; }
      checks=$((checks + 1))
    done
  done <<<"$offered"
  [ "$subset_count" -eq 3 ]
  [ "$checks" -eq "$expected_checks" ]
}

# ========== refusals ==========

@test "refusal: a non-numeric issue number" {
  write_fixture_one
  expect_refusal 12x
}

@test "refusal: a zero issue number" {
  write_fixture_one
  expect_refusal 0
}

@test "refusal: a duplicate issue number" {
  write_fixture_one
  expect_refusal 101 101
}

@test "refusal: no issue number" {
  write_fixture_one
  expect_refusal
}

@test "refusal: a named number absent from the backlog" {
  write_fixture_one
  expect_refusal 101 999
}

@test "refusal: a spec footprint" {
  cat >"$BACKLOG" <<'EOF'
[{"number": 1, "sev": 1, "difficulty": "easy", "footprint": "spec", "key": null}]
EOF
  expect_refusal 1
}

@test "refusal: a backlog that is a JSON object" {
  printf '{"number": 1, "sev": 1}' >"$BACKLOG"
  expect_refusal 1
}

@test "refusal: a named member without a numeric sev" {
  cat >"$BACKLOG" <<'EOF'
[{"number": 1, "difficulty": "easy", "footprint": "narrow", "key": null}]
EOF
  expect_refusal 1
}

@test "refusal: an unknown option" {
  write_fixture_one
  expect_refusal --bogus 101
}

@test "refusal: --backlog without a value" {
  run --separate-stderr bash "$SCRIPT" 101 --backlog
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-batch-budget: "* ]]
}

# ========== unreadable input ==========

@test "unreadable: empty stdin" {
  run --separate-stderr bash -c 'bash "$SCRIPT" 1 </dev/null'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-batch-budget: "* ]]
}

@test "unreadable: stdin that is not JSON" {
  run --separate-stderr bash -c 'printf "not json at all" | bash "$SCRIPT" 1'
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-batch-budget: "* ]]
}

@test "unreadable: a --backlog file that does not exist" {
  run --separate-stderr bash "$SCRIPT" --backlog "$BATS_TEST_TMPDIR/missing.json" 1
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-batch-budget: "* ]]
}

@test "unreadable: jq absent from PATH is exit 3 and the message names jq" {
  write_fixture_one
  local tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  ln -s "$(command -v bash)" "$tools/bash"
  ln -s "$(command -v cat)" "$tools/cat"
  run --separate-stderr env PATH="$tools" "$tools/bash" "$SCRIPT" --backlog "$BACKLOG" 101
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-batch-budget: "*jq* ]]
}

@test "stdin is read when --backlog is absent" {
  write_fixture_one
  run --separate-stderr bash -c 'bash "$SCRIPT" 101 102 <"$1"' _ "$BACKLOG"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "12" ]
}

# ========== data, not command text ==========

@test "a path carrying shell metacharacters is scored as data and never executed" {
  cd "$BATS_TEST_TMPDIR"
  local hostile='src/$(touch pwned)`touch pwned2`'
  jq -nc --arg dir "$hostile" '[
    {number: 1, sev: 1, difficulty: "easy", footprint: "wide", key: {class: "c", path: "\($dir)/x.ts", line: 1}},
    {number: 2, sev: 1, difficulty: "easy", footprint: "wide", key: {class: "c", path: "\($dir)/y.ts", line: 1}}
  ]' >"$BACKLOG"
  score 1 2
  [ "$status" -eq 0 ]
  [ "$(member_field 1 directory)" = "$hostile" ]
  [ "$(member_field 2 directory)" = "$hostile" ]
  [ "$(member_field 1 waived)" = "true" ]
  [ "$(member_field 2 waived)" = "true" ]
  [ -e "$BATS_TEST_TMPDIR/pwned" ] && return 1
  [ -e "$BATS_TEST_TMPDIR/pwned2" ] && return 1
  true
}

# ========== fits and single member ==========

@test "a fitting set exits 0 with the budget echoed and no subsets" {
  write_rows "$BACKLOG" easy:narrow:d1 easy:narrow:d2
  score 1 2
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.verdict')" = "fits" ]
  [ "$(printf '%s' "$output" | jq -r '.budget')" = "12" ]
  [ "$(subsets_compact)" = "[]" ]
}

@test "the largest single cost still fits on its own" {
  cat >"$BACKLOG" <<'EOF'
[{"number": 1, "sev": 3, "difficulty": "hard", "footprint": "wide", "key": null}]
EOF
  score 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "9" ]
  [ "$(printf '%s' "$output" | jq -r '.verdict')" = "fits" ]
}

# ========== worst case ==========

@test "worst case: the largest set the branch-name limit admits scores and offers three subsets" {
  local numbers=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21)
  [ "${#numbers[@]}" -eq 21 ]
  run bash "$BRANCH_LIBRARY" name debt "${numbers[@]}"
  [ "$status" -eq 0 ]
  local items=() index=0
  while [ "$index" -lt 21 ]; do
    index=$((index + 1))
    items+=("easy:narrow:d$index")
  done
  write_rows "$BACKLOG" "${items[@]}"
  score "${numbers[@]}"
  [ "$status" -eq 1 ]
  [ "$(printf '%s' "$output" | jq -r '.total')" = "42" ]
  [ "$(printf '%s' "$output" | jq -r '.subsets | length')" = "3" ]
  [ "$(printf '%s' "$output" | jq -c '[.subsets[].members | length]')" = "[6,6,6]" ]
  [ "$(subsets_compact | jq -c '.[0].members')" = "[1,2,3,4,5,6]" ]
}
