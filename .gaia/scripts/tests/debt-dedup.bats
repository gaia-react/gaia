#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-dedup.sh, the tech-debt dedup check. Covers the
# three match tiers and the near misses each one must refuse (a longer line
# number, a resolved closed issue, a keyed issue's prose), then the usage and
# unreadable-input exits, because a caller files a new issue on exit 0 and must
# never reach that on a failure.
#
# Every test passes both input seams, so the suite never reaches `gh`. Set
# DEBT_DEDUP_SCRIPT to run the same assertions against a scratch copy.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/debt-dedup.bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="${DEBT_DEDUP_SCRIPT:-$REPO_ROOT/.gaia/scripts/debt-dedup.sh}"
  OPEN_FILE="$BATS_TEST_TMPDIR/open.json"
  CLOSED_FILE="$BATS_TEST_TMPDIR/closed.json"
  printf '[]' >"$OPEN_FILE"
  printf '[]' >"$CLOSED_FILE"
}

# key_body <class> <path> <line>: a body carrying one key comment after prose.
key_body() {
  printf 'Finding text.\n<!-- gaia-debt-key: v1 class=%s path=%s line=%s -->' "$1" "$2" "$3"
}

# open_issue <number> <body>...: write the open list, one issue per pair.
open_issues() {
  local entries="[]" issue_number issue_body
  while [ "$#" -ge 2 ]; do
    issue_number="$1"
    issue_body="$2"
    shift 2
    entries="$(jq -c --argjson n "$issue_number" --arg b "$issue_body" '. + [{number: $n, body: $b}]' <<<"$entries")"
  done
  printf '%s' "$entries" >"$OPEN_FILE"
}

# closed_issue <number> <body> <reason> <labels-csv>: write a one-issue closed list.
closed_issue() {
  jq -n -c --argjson n "$1" --arg b "$2" --arg r "$3" --arg l "$4" \
    '[{number: $n, body: $b, stateReason: $r, labels: ($l | split(",") | map(select(. != "")) | map({name: .}))}]' \
    >"$CLOSED_FILE"
}

dedup() {
  run --separate-stderr bash "$SCRIPT" --open-json "$OPEN_FILE" --closed-json "$CLOSED_FILE" "$@"
}

# ========== open keyed matches ==========

@test "open keyed issue with the same path and line matches, with its verbatim inner key" {
  open_issues 41 "$(key_body config-drift src/foo.ts 7)"
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 1 ]
  [ "$(jq -r '.match' <<<"$output")" = "true" ]
  [ "$(jq -r '.number' <<<"$output")" = "41" ]
  [ "$(jq -r '.state' <<<"$output")" = "OPEN" ]
  [ "$(jq -r '.declined' <<<"$output")" = "false" ]
  [ "$(jq -r '.source' <<<"$output")" = "key" ]
  [ "$(jq -r '.inner_key' <<<"$output")" = "v1 class=config-drift path=src/foo.ts line=7" ]
}

@test "stdout is exactly one line on a match" {
  open_issues 41 "$(key_body c src/foo.ts 7)"
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "no issue at all: exit 0 with match false" {
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 0 ]
  [ "$output" = '{"match":false}' ]
}

@test "near miss: a stored line 42 does not match line 4, and the reverse" {
  open_issues 41 "$(key_body c src/foo.ts 42)"
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 0 ]
  [ "$output" = '{"match":false}' ]
  open_issues 41 "$(key_body c src/foo.ts 4)"
  dedup --path src/foo.ts --line 42
  [ "$status" -eq 0 ]
  [ "$output" = '{"match":false}' ]
}

@test "near miss: a different path with the same line does not match" {
  open_issues 41 "$(key_body c src/other.ts 7)"
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 0 ]
}

@test "the class is ignored: a reclassified finding is the same finding" {
  open_issues 41 "$(key_body old-class src/foo.ts 7)"
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 1 ]
  [ "$(jq -r '.number' <<<"$output")" = "41" ]
}

@test "a path containing a space matches verbatim" {
  open_issues 41 "$(key_body c 'wiki/concepts/PR Merge Workflow.md' 12)"
  dedup --path 'wiki/concepts/PR Merge Workflow.md' --line 12
  [ "$status" -eq 1 ]
  [ "$(jq -r '.inner_key' <<<"$output")" = "v1 class=c path=wiki/concepts/PR Merge Workflow.md line=12" ]
}

@test "regex metacharacters in the path match only literally" {
  open_issues 41 "$(key_body c 'aXb+c/(x).sh' 3)"
  dedup --path 'a.b+c/(x).sh' --line 3
  [ "$status" -eq 0 ]
  open_issues 41 "$(key_body c 'a.b+c/(x).sh' 3)"
  dedup --path 'a.b+c/(x).sh' --line 3
  [ "$status" -eq 1 ]
}

@test "a leading-zero line argument is the same integer" {
  open_issues 41 "$(key_body c src/foo.ts 7)"
  dedup --path src/foo.ts --line 007
  [ "$status" -eq 1 ]
}

# ========== closed matches ==========

@test "a closed issue carrying wontfix is a declined match" {
  closed_issue 30 "$(key_body c src/foo.ts 7)" COMPLETED wontfix
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 1 ]
  [ "$(jq -r '.state' <<<"$output")" = "CLOSED" ]
  [ "$(jq -r '.declined' <<<"$output")" = "true" ]
  [ "$(jq -r '.source' <<<"$output")" = "key" ]
}

@test "a closed issue closed as not planned is a declined match without the label" {
  closed_issue 30 "$(key_body c src/foo.ts 7)" NOT_PLANNED ""
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 1 ]
  [ "$(jq -r '.declined' <<<"$output")" = "true" ]
}

@test "refusal: a closed issue resolved as completed is not a match" {
  closed_issue 30 "$(key_body c src/foo.ts 7)" COMPLETED "tech-debt"
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 0 ]
  [ "$output" = '{"match":false}' ]
}

@test "precedence: an open match beats a declined match on the same identity" {
  open_issues 50 "$(key_body c src/foo.ts 7)"
  closed_issue 30 "$(key_body c src/foo.ts 7)" NOT_PLANNED ""
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 1 ]
  [ "$(jq -r '.number' <<<"$output")" = "50" ]
  [ "$(jq -r '.state' <<<"$output")" = "OPEN" ]
}

@test "precedence: two open matches report the lower number" {
  open_issues 60 "$(key_body c src/foo.ts 7)" 55 "$(key_body d src/foo.ts 7)"
  dedup --path src/foo.ts --line 7
  [ "$status" -eq 1 ]
  [ "$(jq -r '.number' <<<"$output")" = "55" ]
}

# ========== keyless open matches ==========

@test "a keyless open body citing path:line matches as keyless with a null inner key" {
  open_issues 70 'The helper in `src/foo.ts:4` is dead.'
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 1 ]
  [ "$(jq -r '.source' <<<"$output")" = "keyless" ]
  [ "$(jq -r '.inner_key' <<<"$output")" = "null" ]
  [ "$(jq -r '.state' <<<"$output")" = "OPEN" ]
}

@test "refusal: the keyless scan does not let line 4 match a cited line 42" {
  open_issues 70 'The helper in `src/foo.ts:42` is dead.'
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 0 ]
}

@test "a keyless citation at the very end of the body matches" {
  open_issues 70 'See src/foo.ts:4'
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 1 ]
}

@test "a keyless body whose first citation is longer still matches a later exact one" {
  open_issues 70 'src/foo.ts:42 and also src/foo.ts:4.'
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 1 ]
}

@test "the keyless scan is literal: metacharacters in the path do not widen it" {
  open_issues 70 'See aXb+c/(x).sh:3 here.'
  dedup --path 'a.b+c/(x).sh' --line 3
  [ "$status" -eq 0 ]
}

@test "the keyless scan does not apply to closed issues" {
  closed_issue 30 'See `src/foo.ts:4`.' NOT_PLANNED wontfix
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 0 ]
}

@test "the keyless scan does not apply to an open issue that has a parseable key" {
  open_issues 70 "$(printf 'Mentions src/foo.ts:4 in prose.\n<!-- gaia-debt-key: v1 class=c path=src/other.ts line=9 -->')"
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 0 ]
}

@test "a keyed match outranks a keyless match even when the keyless number is lower" {
  open_issues 10 'See src/foo.ts:4.' 90 "$(key_body c src/foo.ts 4)"
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 1 ]
  [ "$(jq -r '.number' <<<"$output")" = "90" ]
  [ "$(jq -r '.source' <<<"$output")" = "key" ]
}

# ========== key parsing ==========

@test "two keys on one line: the first key's own path and line are the identity" {
  local fixture="$REPO_ROOT/.gaia/tests/fixtures/dedup-key-corpus/two-keys-one-line-issues.json"
  jq -c '[.[] | {number, body}]' "$fixture" >"$OPEN_FILE"
  [ "$(jq 'length' "$OPEN_FILE")" -ge 1 ]
  dedup --path 'wiki/concepts/PR Merge Workflow.md' --line 7
  [ "$status" -eq 1 ]
  [ "$(jq -r '.inner_key' <<<"$output")" = "v1 class=a path=wiki/concepts/PR Merge Workflow.md line=7" ]
  dedup --path 'wiki/concepts/Task Orchestration.md' --line 9
  [ "$status" -eq 0 ]
}

@test "a multiline decoy key is not spliced across lines" {
  local decoy
  decoy="$(printf '<!-- gaia-debt-key: v1 class=decoy path=src/a.ts line=\nprose\n<!-- gaia-debt-key: v1 class=real path=src/real.ts line=42 -->')"
  open_issues 80 "$decoy"
  dedup --path src/real.ts --line 42
  [ "$status" -eq 1 ]
  [ "$(jq -r '.inner_key' <<<"$output")" = "v1 class=real path=src/real.ts line=42" ]
  dedup --path src/a.ts --line 0
  [ "$status" -eq 0 ]
}

# ========== conformance with the ordering query ==========

# capture_of <file>: the key capture regex text inside the file's capture("...") call.
capture_of() {
  grep -o 'capture("<!-- gaia-debt-key[^"]*")' "$1" | head -n 1
}

@test "the key capture is byte-identical to the one in the debt playbook ordering query" {
  local playbook="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  local from_script from_playbook
  from_script="$(capture_of "$SCRIPT")"
  from_playbook="$(capture_of "$playbook")"
  [ -n "$from_script" ]
  [ -n "$from_playbook" ]
  [ "$from_script" = "$from_playbook" ]
}

@test "red twin: a scratch copy with a widened path class fails the conformance check" {
  local scratch="$BATS_TEST_TMPDIR/debt-dedup-widened.sh"
  sed 's/path=(?<path>\[^>\\n\]+)/path=(?<path>[^ ]+)/' "$SCRIPT" >"$scratch"
  cmp -s "$SCRIPT" "$scratch" && return 1
  local playbook="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  [ "$(capture_of "$scratch")" != "$(capture_of "$playbook")" ]
}

# ========== usage ==========

# usage_refusal <args>...: exit 2, empty stdout, exactly one debt-dedup: line.
usage_refusal() {
  dedup "$@"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^debt-dedup: ')" -eq 1 ]
}

@test "usage: no --path" {
  usage_refusal --line 4
}

@test "usage: empty --path" {
  usage_refusal --path "" --line 4
}

@test "usage: a non-integer --line" {
  usage_refusal --path src/foo.ts --line 4a
}

@test "usage: --line missing" {
  usage_refusal --path src/foo.ts
}

@test "usage: unknown flag" {
  usage_refusal --path src/foo.ts --line 4 --bogus
}

# ========== unreadable input ==========

# input_refusal <args>...: exit 3, empty stdout, exactly one debt-dedup: line.
input_refusal() {
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | grep -c '^debt-dedup: ')" -eq 1 ]
}

@test "unreadable: an open list that is not JSON" {
  printf 'not json' >"$OPEN_FILE"
  dedup --path src/foo.ts --line 4
  input_refusal
}

@test "unreadable: a closed list that is not an array" {
  printf '{"a":1}' >"$CLOSED_FILE"
  dedup --path src/foo.ts --line 4
  input_refusal
}

@test "unreadable: a missing seam file" {
  rm -f "$OPEN_FILE"
  dedup --path src/foo.ts --line 4
  input_refusal
}

@test "unreadable: jq absent from PATH" {
  local stub_directory="$BATS_TEST_TMPDIR/no-jq"
  mkdir -p "$stub_directory"
  run --separate-stderr env PATH="$stub_directory" "$BASH" "$SCRIPT" \
    --open-json "$OPEN_FILE" --closed-json "$CLOSED_FILE" --path src/foo.ts --line 4
  input_refusal
}

@test "unreadable: an open result that fills its limit is saturated" {
  local limit
  limit="$(grep -E '^open_limit=' "$SCRIPT" | head -n 1 | cut -d= -f2)"
  [ -n "$limit" ]
  jq -n -c --argjson n "$limit" '[range(0; $n) | {number: (. + 1), body: "x"}]' >"$OPEN_FILE"
  dedup --path src/foo.ts --line 4
  input_refusal
}

@test "unreadable: a closed result that fills its limit is saturated" {
  local limit
  limit="$(grep -E '^closed_limit=' "$SCRIPT" | head -n 1 | cut -d= -f2)"
  [ -n "$limit" ]
  jq -n -c --argjson n "$limit" '[range(0; $n) | {number: (. + 1), body: "x", labels: [], stateReason: "COMPLETED"}]' >"$CLOSED_FILE"
  dedup --path src/foo.ts --line 4
  input_refusal
}

@test "a result one short of its limit is read normally" {
  local limit
  limit="$(grep -E '^open_limit=' "$SCRIPT" | head -n 1 | cut -d= -f2)"
  jq -n -c --argjson n "$((limit - 1))" '[range(0; $n) | {number: (. + 1), body: "x"}]' >"$OPEN_FILE"
  dedup --path src/foo.ts --line 4
  [ "$status" -eq 0 ]
}
