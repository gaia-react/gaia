#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-backlog.sh, the /gaia-debt exclusion and
# clustering pass. Each clustering rule is driven in both directions (the
# relation that joins and the near-miss that must not), every exclusion bucket
# is driven, and every refusal arm is checked for exit 2 with empty stdout and
# a single `debt-backlog:` stderr line.
#
# The script is resolved from DEBT_BACKLOG_SCRIPT when set, so a scratch copy
# with a rule removed can be run through the same assertions to prove they can
# fail.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/debt-backlog.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${DEBT_BACKLOG_SCRIPT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-backlog.sh}"
  BACKLOG="$BATS_TEST_TMPDIR/backlog.json"
  export SCRIPT
}

# issue <number> <class|-> <path|-> [label,label...] [footprint] [body]: one
# element in the ordering query's emitted shape. A "-" class or path writes a
# null key.
issue() {
  jq -nc --argjson number "$1" --arg class "$2" --arg path "$3" \
    --arg labels "${4:-}" --arg footprint "${5:-code}" --arg body "${6:-no path here}" \
    '{number: $number,
      labels: ($labels | if . == "" then [] else split(",") end),
      key: (if $path == "-" then null else {class: $class, path: $path, line: 1} end),
      body: $body, footprint: $footprint}'
}

# write_backlog <issue-json>...: the ordered array at $BACKLOG.
write_backlog() {
  local joined="" element
  for element in "$@"; do joined="$joined$element,"; done
  printf '[%s]' "${joined%,}" >"$BACKLOG"
}

# backlog: runs the script with the backlog on stdin.
backlog() {
  run --separate-stderr bash "$SCRIPT" <"$BACKLOG"
}

# field <jq-expression>: one value out of $output.
field() {
  printf '%s' "$output" | jq -c "$1"
}

# ========== clustering ==========

@test "two keyed issues on one path form a path cluster in backlog order" {
  write_backlog "$(issue 5 c/a .claude/hooks/x.sh)" "$(issue 9 c/b .claude/hooks/x.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[{"members":[5,9],"paths":[".claude/hooks/x.sh"],"signal":"path"}]' ]
}

@test "same seeded class and same directory across files is a class-dir cluster" {
  write_backlog "$(issue 1 c/a .claude/hooks/a.sh)" "$(issue 2 c/a .claude/hooks/b.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[{"members":[1,2],"paths":[".claude/hooks/a.sh",".claude/hooks/b.sh"],"signal":"class-dir"}]' ]
}

@test "the sentinel class never satisfies the class rule" {
  write_backlog "$(issue 1 holistic/unclassified .claude/hooks/a.sh)" \
    "$(issue 2 holistic/unclassified .claude/hooks/b.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[]' ]
  [ "$(field '.candidates')" = '[1,2]' ]
}

@test "a shared directory alone does not cluster" {
  write_backlog "$(issue 1 c/a .claude/hooks/a.sh)" "$(issue 2 c/b .claude/hooks/b.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[]' ]
}

@test "the same class in different directories does not cluster" {
  write_backlog "$(issue 1 c/a .claude/hooks/a.sh)" "$(issue 2 c/a .claude/rules/b.md)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[]' ]
}

@test "root-level files of one class share the dot directory" {
  write_backlog "$(issue 1 c/a a.sh)" "$(issue 2 c/a b.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters | length')" = '1' ]
}

@test "a keyless issue citing the path in its body joins the keyed issue" {
  write_backlog "$(issue 1 c/a .claude/hooks/a.sh)" \
    "$(issue 2 - - '' code 'see `.claude/hooks/a.sh:12` for the bug')"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[{"members":[1,2],"paths":[".claude/hooks/a.sh"],"signal":"path"}]' ]
}

@test "a keyless issue with no parseable path stands alone" {
  write_backlog "$(issue 1 c/a .claude/hooks/a.sh)" \
    "$(issue 2 - - '' code 'nothing path-like, only word:12 and plain text')"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[]' ]
  [ "$(field '.candidates')" = '[1,2]' ]
}

@test "a body path followed by a non-digit terminator parses" {
  write_backlog "$(issue 1 c/a src/a.ts)" "$(issue 2 - - '' code 'at src/a.ts:12, then more')"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters[0].members')" = '[1,2]' ]
}

@test "a body line number is read whole, so the path is still the file" {
  write_backlog "$(issue 1 c/a src/a.sh)" "$(issue 2 - - '' code 'bug at src/a.sh:123')"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters[0].members')" = '[1,2]' ]
}

@test "the first path-like token in a body wins" {
  write_backlog "$(issue 1 c/a src/first.sh)" "$(issue 2 c/b src/second.sh)" \
    "$(issue 3 - - '' code 'port:80 then src/first.sh:4 and src/second.sh:9')"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[{"members":[1,3],"paths":["src/first.sh"],"signal":"path"}]' ]
}

@test "transitive links join one mixed cluster" {
  write_backlog "$(issue 1 c/a .claude/hooks/a.sh)" "$(issue 2 c/b .claude/hooks/a.sh)" \
    "$(issue 3 c/b .claude/hooks/c.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.clusters')" = '[{"members":[1,2,3],"paths":[".claude/hooks/a.sh",".claude/hooks/c.sh"],"signal":"mixed"}]' ]
}

@test "clusters are ordered by their first member and candidates keep input order" {
  write_backlog "$(issue 7 c/a z/one.sh)" "$(issue 3 c/b y/two.sh)" \
    "$(issue 8 c/c y/two.sh)" "$(issue 4 c/d z/one.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.candidates')" = '[7,3,8,4]' ]
  [ "$(field '[.clusters[].members]')" = '[[7,4],[3,8]]' ]
}

# ========== exclusions ==========

@test "an in-progress issue is excluded and never clusters" {
  write_backlog "$(issue 1 c/a src/a.sh in-progress)" "$(issue 2 c/b src/a.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.excluded.in_progress')" = '[1]' ]
  [ "$(field '.candidates')" = '[2]' ]
  [ "$(field '.clusters')" = '[]' ]
}

@test "each spec park label lands in spec_parked" {
  write_backlog "$(issue 1 c/a src/a.sh debt:spec-pending)" "$(issue 2 c/b src/b.sh debt:spec-active)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.excluded.spec_parked')" = '[1,2]' ]
  [ "$(field '.candidates')" = '[]' ]
}

@test "a severity:investigate issue lands in investigate" {
  write_backlog "$(issue 1 c/a src/a.sh severity:investigate)" "$(issue 2 c/b src/a.sh)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.excluded.investigate')" = '[1]' ]
  [ "$(field '.candidates')" = '[2]' ]
  [ "$(field '.clusters')" = '[]' ]
}

@test "an issue with two exclusion labels appears once, in the first bucket" {
  write_backlog "$(issue 1 c/a src/a.sh severity:investigate,debt:spec-pending,in-progress)" \
    "$(issue 2 c/b src/b.sh severity:investigate,debt:spec-active)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.excluded')" = '{"in_progress":[1],"spec_parked":[2],"investigate":[]}' ]
}

# ========== spec_class and empty input ==========

@test "spec_class lists candidates with a spec footprint and still clusters them" {
  write_backlog "$(issue 1 c/a src/a.sh '' spec)" "$(issue 2 c/b src/a.sh '' code)" \
    "$(issue 3 c/c src/c.sh in-progress spec)"
  backlog
  [ "$status" -eq 0 ]
  [ "$(field '.spec_class')" = '[1]' ]
  [ "$(field '.clusters[0].members')" = '[1,2]' ]
}

@test "an empty backlog reports every list empty" {
  printf '[]' >"$BACKLOG"
  backlog
  [ "$status" -eq 0 ]
  [ "$output" = '{"candidates":[],"excluded":{"in_progress":[],"spec_parked":[],"investigate":[]},"clusters":[],"spec_class":[]}' ]
}

@test "the --backlog seam reads the array from a file" {
  write_backlog "$(issue 1 c/a src/a.sh)" "$(issue 2 c/b src/a.sh)"
  run --separate-stderr bash "$SCRIPT" --backlog "$BACKLOG" </dev/null
  [ "$status" -eq 0 ]
  [ "$(field '.clusters[0].members')" = '[1,2]' ]
}

# ========== refusals ==========

# refused: asserts exit 2, empty stdout, exactly one debt-backlog: line.
refused() {
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" = '1' ]
  case "$stderr" in debt-backlog:*) ;; *) return 1 ;; esac
}

@test "input that is not JSON is refused" {
  printf 'not json' >"$BACKLOG"
  backlog
  refused
}

@test "empty input is refused" {
  : >"$BACKLOG"
  backlog
  refused
}

@test "a JSON object rather than an array is refused" {
  printf '{"number":1}' >"$BACKLOG"
  backlog
  refused
}

@test "an unknown flag is refused" {
  printf '[]' >"$BACKLOG"
  run --separate-stderr bash "$SCRIPT" --bogus <"$BACKLOG"
  refused
}

@test "--backlog without a value is refused" {
  run --separate-stderr bash "$SCRIPT" --backlog </dev/null
  refused
}

@test "--backlog naming a missing file is refused" {
  run --separate-stderr bash "$SCRIPT" --backlog "$BATS_TEST_TMPDIR/absent.json" </dev/null
  refused
}

@test "jq absent from PATH is refused" {
  printf '[]' >"$BACKLOG"
  mkdir -p "$BATS_TEST_TMPDIR/empty-path"
  run --separate-stderr env PATH="$BATS_TEST_TMPDIR/empty-path" "$BASH" "$SCRIPT" <"$BACKLOG"
  refused
}

# ========== guards can fail ==========

@test "a copy without the sentinel-class check fails the sentinel refusal" {
  local scratch="$BATS_TEST_TMPDIR/debt-backlog-mutant.sh"
  grep -q 'holistic/unclassified' "$SCRIPT" || return 1
  sed 's#holistic/unclassified#never/matches/anything#' "$SCRIPT" >"$scratch"
  cmp -s "$SCRIPT" "$scratch" && return 1
  write_backlog "$(issue 1 holistic/unclassified .claude/hooks/a.sh)" \
    "$(issue 2 holistic/unclassified .claude/hooks/b.sh)"
  run --separate-stderr bash "$scratch" <"$BACKLOG"
  [ "$status" -eq 0 ]
  [ "$(field '.clusters | length')" = '1' ]
}
