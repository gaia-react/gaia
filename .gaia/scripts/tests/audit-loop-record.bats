#!/usr/bin/env bats
# Guards .gaia/scripts/audit-loop-record.sh, the one writer of the PR body's
# `## Audit rounds` section.
#
# A refusal must be reachable: each malformed-marker body below is driven to
# exit 1 with no output file created.
#
# `gh` is a stub on PATH serving fixture JSON and logging its argv, so the
# "body never on a command line" claim runs against the real script. Assertion
# style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-loop-record.sh"
  START='<!-- gaia:audit-rounds:start -->'
  END='<!-- gaia:audit-rounds:end -->'
  T="$BATS_TEST_TMPDIR"
  command -v jq >/dev/null 2>&1 || skip "jq missing"
}

# values <total> <members-json> <grants>: write $T/values.json.
values() {
  printf '{"total":%s,"members":%s,"grants":%s}\n' "$1" "$2" "$3" > "$T/values.json"
}

# section_for <body-file>: the lines from the start marker through the end
# marker, for the strict parser.
section_lines() {
  awk -v s="$START" -v e="$END" '
    $0 == s { on = 1 }
    on { print }
    $0 == e { exit }
  ' "$1"
}

# parse_section <body-file>: strict parse of the section. Prints
# `<total> <grants> <member>=<n>...`; returns 1 on any deviation from the shape.
parse_section() {
  local sec count line total grants members names sorted
  sec="$(section_lines "$1")"
  count="$(printf '%s\n' "$sec" | wc -l | tr -d ' ')"
  [ "$count" -eq 5 ] || return 1
  [ "$(printf '%s\n' "$sec" | sed -n 1p)" = "$START" ] || return 1
  [ "$(printf '%s\n' "$sec" | sed -n 2p)" = '## Audit rounds' ] || return 1
  [ -z "$(printf '%s\n' "$sec" | sed -n 3p)" ] || return 1
  [ "$(printf '%s\n' "$sec" | sed -n 5p)" = "$END" ] || return 1
  line="$(printf '%s\n' "$sec" | sed -n 4p)"
  printf '%s\n' "$line" | grep -Eq '^Total rounds: [0-9]+; per member: (none|code-audit-[a-z0-9-]+ [0-9]+(, code-audit-[a-z0-9-]+ [0-9]+)*); human grants: [0-9]+\.$' || return 1
  total="$(printf '%s\n' "$line" | sed -E 's/^Total rounds: ([0-9]+);.*/\1/')"
  grants="$(printf '%s\n' "$line" | sed -E 's/.*human grants: ([0-9]+)\.$/\1/')"
  members="$(printf '%s\n' "$line" | sed -E 's/^.*per member: (.*); human grants: .*$/\1/')"
  if [ "$members" = none ]; then
    printf '%s %s\n' "$total" "$grants"
    return 0
  fi
  names="$(printf '%s\n' "$members" | tr ',' '\n' | sed -E 's/^ *//; s/ [0-9]+$//')"
  sorted="$(printf '%s\n' "$names" | LC_ALL=C sort)"
  [ "$names" = "$sorted" ] || return 1
  printf '%s %s %s\n' "$total" "$grants" "$(printf '%s\n' "$members" | sed -E 's/, /;/g; s/ /=/g')"
}

# byte_offset <file> <literal>: byte offset of the first occurrence.
byte_offset() {
  grep -b -o -F -m1 -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# outside_equal <original> <result>: every byte before the start marker and
# every byte after the end marker's text is identical.
outside_equal() {
  local o_s r_s o_e r_e
  o_s="$(byte_offset "$1" "$START")"
  r_s="$(byte_offset "$2" "$START")"
  [ "$o_s" = "$r_s" ] || return 1
  head -c "$o_s" "$1" > "$T/o.pre"
  head -c "$r_s" "$2" > "$T/r.pre"
  cmp -s "$T/o.pre" "$T/r.pre" || return 1
  o_e="$(byte_offset "$1" "$END")"
  r_e="$(byte_offset "$2" "$END")"
  tail -c "+$(( o_e + ${#END} + 1 ))" "$1" > "$T/o.post"
  tail -c "+$(( r_e + ${#END} + 1 ))" "$2" > "$T/r.post"
  cmp -s "$T/o.post" "$T/r.post"
}

rec_offline() {
  run bash "$SCRIPT" --pr 12 --values-json "$T/values.json" --body-in "$1" --body-out "$2"
}

# ---------------------------------------------------------------------------
# Offline splice
# ---------------------------------------------------------------------------

@test "offline: a body with no section gets one appended after a blank line" {
  values 3 '{"code-audit-frontend":3}' 0
  printf 'Summary line\n\nMore text\n' > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  grep -qxF "$START" "$T/out.md"
  head -c "$(wc -c < "$T/in.md")" "$T/out.md" | cmp -s - "$T/in.md"
  [ "$(sed -n 4p "$T/out.md")" = "" ]
  [ "$(sed -n 5p "$T/out.md")" = "$START" ]
  parse_section "$T/out.md" > "$T/parsed"
  [ "$(cat "$T/parsed")" = "3 0 code-audit-frontend=3" ]
}

@test "offline: an empty body gets the section alone" {
  values 1 '{"code-audit-frontend":1}' 0
  : > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$T/out.md")" = "$START" ]
  parse_section "$T/out.md" >/dev/null
}

@test "offline: an unterminated last line still gets one blank line before the section" {
  values 1 '{"code-audit-frontend":1}' 0
  printf 'no trailing newline' > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$T/out.md")" = 'no trailing newline' ]
  [ "$(sed -n 2p "$T/out.md")" = '' ]
  [ "$(sed -n 3p "$T/out.md")" = "$START" ]
}

@test "offline: an existing section is replaced in place, outside bytes identical" {
  values 4 '{"code-audit-frontend":4,"code-audit-maintainer-shell":2}' 1
  printf 'before line\r\nsecond before\n\n%s\n## Audit rounds\n\nTotal rounds: 9; per member: x; human grants: 9.\n%s\n\nafter line\r\nlast after\n' \
    "$START" "$END" > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  outside_equal "$T/in.md" "$T/out.md"
  parse_section "$T/out.md" > "$T/parsed"
  [ "$(cat "$T/parsed")" = "4 1 code-audit-frontend=4;code-audit-maintainer-shell=2" ]
  [ "$(grep -cF "$START" "$T/out.md")" -eq 1 ]
}

@test "offline: a section that was the last line without a newline is replaced" {
  values 2 '{"code-audit-frontend":2}' 0
  printf 'text\n%s\nold\n%s' "$START" "$END" > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$T/out.md")" = text ]
  parse_section "$T/out.md" >/dev/null
}

@test "offline: running twice is idempotent" {
  values 3 '{"code-audit-frontend":3}' 0
  printf 'Body\n' > "$T/in.md"
  rec_offline "$T/in.md" "$T/once.md"
  [ "$status" -eq 0 ]
  rec_offline "$T/once.md" "$T/twice.md"
  [ "$status" -eq 0 ]
  cmp -s "$T/once.md" "$T/twice.md"
}

@test "offline: a hand-edited higher count or garbage text is replaced by the computed one" {
  values 2 '{"code-audit-frontend":2}' 0
  printf 'x\n%s\nTotal rounds: 99; per member: code-audit-frontend 99; human grants: 99.\nrubbish <script>\n%s\ny\n' \
    "$START" "$END" > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  parse_section "$T/out.md" > "$T/parsed"
  [ "$(cat "$T/parsed")" = "2 0 code-audit-frontend=2" ]
  grep -q 'rubbish' "$T/out.md" && return 1
  grep -q '99' "$T/out.md" && return 1
  true
}

@test "offline: members are written sorted whatever the input order" {
  values 3 '{"code-audit-z":1,"code-audit-a":2,"code-audit-m-n":3}' 0
  : > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  parse_section "$T/out.md" > "$T/parsed"
  [ "$(cat "$T/parsed")" = "3 0 code-audit-a=2;code-audit-m-n=3;code-audit-z=1" ]
}

@test "offline: no members prints none and still parses" {
  values 0 '{}' 0
  : > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  parse_section "$T/out.md" > "$T/parsed"
  [ "$(cat "$T/parsed")" = "0 0" ]
}

@test "offline: values can be read from stdin" {
  printf 'Body\n' > "$T/in.md"
  run bash -c 'printf "{\"total\":1,\"members\":{\"code-audit-frontend\":1},\"grants\":0}" | bash "$0" --pr 12 --values-json - --body-in "$1" --body-out "$2"' \
    "$SCRIPT" "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  parse_section "$T/out.md" >/dev/null
}

# ---------------------------------------------------------------------------
# Refusals: exit 1 and the output file is never created
# ---------------------------------------------------------------------------

assert_refused() {
  # $1 body printf format, rest printf args
  local fmt="$1"
  shift
  values 1 '{"code-audit-frontend":1}' 0
  # shellcheck disable=SC2059  # the caller supplies the format on purpose
  printf "$fmt" "$@" > "$T/in.md"
  rm -f "$T/out.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 1 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ ! -e "$T/out.md" ] || return 1
  [ -n "$output" ]
}

@test "refuses: two start markers" {
  assert_refused '%s\nold\n%s\n%s\n' "$START" "$END" "$START"
}

@test "refuses: two end markers" {
  assert_refused '%s\nold\n%s\n%s\n' "$START" "$END" "$END"
}

@test "refuses: two balanced sections, so only the duplicate check can stop it" {
  assert_refused '%s\nold\n%s\nmid\n%s\nold2\n%s\n' "$START" "$END" "$START" "$END"
}

@test "refuses: a start marker with no end" {
  assert_refused 'text\n%s\nmore\n' "$START"
}

@test "refuses: an end marker with no start" {
  assert_refused 'text\n%s\nmore\n' "$END"
}

@test "refuses: the end marker before the start" {
  assert_refused '%s\nmid\n%s\n' "$END" "$START"
}

@test "refuses: a marker inside a backtick fence" {
  assert_refused 'intro\n```\n%s\nold\n%s\n```\n' "$START" "$END"
}

@test "refuses: a marker inside a tilde fence" {
  assert_refused 'intro\n~~~\n%s\nold\n%s\n~~~\n' "$START" "$END"
}

@test "refuses: a marker inside an unterminated fence" {
  assert_refused 'intro\n```md\n%s\nold\n%s\n' "$START" "$END"
}

@test "refuses: one marker fenced even when the other is not" {
  assert_refused '%s\nold\n```\n%s\n```\n' "$START" "$END"
}

@test "refuses: a marker that shares its line with other text" {
  assert_refused 'see %s\nold\n%s\n' "$START" "$END"
}

@test "a fence that has closed before the markers does not refuse" {
  values 1 '{"code-audit-frontend":1}' 0
  printf 'text\n```\ncode\n```\n%s\nold\n%s\n' "$START" "$END" > "$T/in.md"
  rec_offline "$T/in.md" "$T/out.md"
  [ "$status" -eq 0 ]
  outside_equal "$T/in.md" "$T/out.md"
}

# ---------------------------------------------------------------------------
# Input validation: exit 2
# ---------------------------------------------------------------------------

assert_usage() {
  # $1 values JSON text, rest of the args appended to the call
  local json="$1"
  shift
  printf '%s\n' "$json" > "$T/values.json"
  : > "$T/in.md"
  rm -f "$T/out.md"
  run bash "$SCRIPT" --pr 12 --values-json "$T/values.json" --body-in "$T/in.md" --body-out "$T/out.md" "$@"
  [ "$status" -eq 2 ] || { printf 'status %s: %s\n' "$status" "$output" >&2; return 1; }
  [ ! -e "$T/out.md" ]
}

@test "invalid: a negative total" {
  assert_usage '{"total":-1,"members":{"code-audit-frontend":1},"grants":0}'
}

@test "invalid: a non-integer grant" {
  assert_usage '{"total":1,"members":{"code-audit-frontend":1},"grants":1.5}'
}

@test "invalid: a string where an integer belongs" {
  assert_usage '{"total":"3","members":{"code-audit-frontend":1},"grants":0}'
}

@test "invalid: a member name that is a command" {
  assert_usage '{"total":1,"members":{"rm -rf":1},"grants":0}'
}

@test "invalid: a member name carrying an embedded newline" {
  assert_usage '{"total":1,"members":{"code-audit-a\nrm":1},"grants":0}'
}

@test "invalid: a negative member count" {
  assert_usage '{"total":1,"members":{"code-audit-frontend":-2},"grants":0}'
}

@test "invalid: a missing key and an extra key" {
  assert_usage '{"total":1,"members":{"code-audit-frontend":1}}'
  assert_usage '{"total":1,"members":{},"grants":0,"extra":1}'
}

@test "invalid: not JSON at all" {
  assert_usage 'not json'
}

@test "invalid: --pr 12a" {
  values 1 '{"code-audit-frontend":1}' 0
  : > "$T/in.md"
  run bash "$SCRIPT" --pr 12a --values-json "$T/values.json" --body-in "$T/in.md" --body-out "$T/out.md"
  [ "$status" -eq 2 ]
  [ ! -e "$T/out.md" ]
}

@test "invalid: --repo a/b;c" {
  values 1 '{"code-audit-frontend":1}' 0
  : > "$T/in.md"
  run bash "$SCRIPT" --pr 12 --repo 'a/b;c' --values-json "$T/values.json" --body-in "$T/in.md" --body-out "$T/out.md"
  [ "$status" -eq 2 ]
  [ ! -e "$T/out.md" ]
}

@test "invalid: flag combinations that name no single source of values" {
  values 1 '{"code-audit-frontend":1}' 0
  : > "$T/in.md"
  run bash "$SCRIPT" --pr 12 --body-in "$T/in.md" --body-out "$T/out.md"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --pr 12 --values-json "$T/values.json" --body-in "$T/in.md"
  [ "$status" -eq 2 ]
}

@test "invalid: the removed CI-computed flags are unknown arguments" {
  values 1 '{"code-audit-frontend":1}' 0
  : > "$T/in.md"
  run bash "$SCRIPT" --pr 12 --from-ci --body-in "$T/in.md" --body-out "$T/out.md"
  [ "$status" -eq 2 ]
  grep -qF "unknown argument: --from-ci" <<<"$output"
  run bash "$SCRIPT" --pr 12 --values-json "$T/values.json" --current-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --body-in "$T/in.md" --body-out "$T/out.md"
  [ "$status" -eq 2 ]
  grep -qF "unknown argument: --current-sha" <<<"$output"
  run bash "$SCRIPT" --pr 12 --values-json "$T/values.json" --current-audited true --body-in "$T/in.md" --body-out "$T/out.md"
  [ "$status" -eq 2 ]
  [ ! -e "$T/out.md" ]
}

# ---------------------------------------------------------------------------
# gh stub: fixture JSON in, argv out
# ---------------------------------------------------------------------------

make_stub() {
  STUB="$T/stub"
  mkdir -p "$STUB/bin"
  : > "$STUB/argv.log"
  cat > "$STUB/bin/gh" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_DIR/argv.log"
[ -z "${STUB_FAIL:-}" ] || exit 1
case "$1 $2" in
  "pr view")
    cat "$STUB_DIR/body.txt"; printf '\n'
    ;;
  "pr edit")
    prev=""
    for a in "$@"; do
      [ "$prev" = "--body-file" ] && cp "$a" "$STUB_DIR/edited.md"
      prev="$a"
    done
    ;;
  *) exit 1 ;;
esac
STUBEOF
  chmod +x "$STUB/bin/gh"
  export STUB_DIR="$STUB"
  PATH="$STUB/bin:$PATH"
}

# ---------------------------------------------------------------------------
# Body travels by file, never by argv
# ---------------------------------------------------------------------------

@test "gh mode: the body goes through --body-file and its text never reaches an argv" {
  make_stub
  printf 'ZZBODYTOKENZZ line one\n\n%s\nold\n%s\ntail ZZTAILTOKENZZ\n' "$START" "$END" > "$STUB/body.txt"
  values 2 '{"code-audit-frontend":2}' 0
  run bash "$SCRIPT" --pr 12 --repo o/r --values-json "$T/values.json"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -q -- '--body-file' "$STUB/argv.log"
  grep -q -- 'pr edit 12 --repo o/r' "$STUB/argv.log"
  grep -q 'ZZBODYTOKENZZ' "$STUB/argv.log" && return 1
  grep -q 'ZZTAILTOKENZZ' "$STUB/argv.log" && return 1
  grep -q 'Audit rounds' "$STUB/argv.log" && return 1
  grep -q 'ZZBODYTOKENZZ' "$STUB/edited.md"
  grep -q 'ZZTAILTOKENZZ' "$STUB/edited.md"
  parse_section "$STUB/edited.md" > "$T/parsed"
  [ "$(cat "$T/parsed")" = "2 0 code-audit-frontend=2" ]
}

@test "gh mode: the body read back from gh is not given a stray trailing newline" {
  make_stub
  printf 'exact body' > "$STUB/body.txt"
  values 1 '{"code-audit-frontend":1}' 0
  run bash "$SCRIPT" --pr 12 --values-json "$T/values.json"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$STUB/edited.md")" = 'exact body' ]
  [ "$(sed -n 2p "$STUB/edited.md")" = '' ]
  [ "$(sed -n 3p "$STUB/edited.md")" = "$START" ]
}

@test "gh mode: a malformed body edits nothing" {
  make_stub
  printf '%s\nonly a start\n' "$START" > "$STUB/body.txt"
  values 1 '{"code-audit-frontend":1}' 0
  run bash "$SCRIPT" --pr 12 --values-json "$T/values.json"
  [ "$status" -eq 1 ]
  grep -q 'pr edit' "$STUB/argv.log" && return 1
  [ ! -e "$STUB/edited.md" ]
}

@test "gh mode: a failing pr edit exits 1" {
  make_stub
  printf 'body\n' > "$STUB/body.txt"
  values 1 '{"code-audit-frontend":1}' 0
  run env STUB_FAIL=1 bash "$SCRIPT" --pr 12 --values-json "$T/values.json"
  [ "$status" -eq 1 ]
}
