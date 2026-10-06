#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-parse-args.sh, the /gaia-debt argument parser.
# It guards the grammar table (every recognized form maps to one stdout line),
# the refusal table (every unrecognized form exits 2 naming the first offending
# token, so a typo can never fall through to a drain), that input is never
# evaluated, and the misuse exit. Each table asserts it ran every row, because a
# loop that iterates nothing passes.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/debt-parse-args.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${DEBT_PARSE_ARGS_SCRIPT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-parse-args.sh}"
  LONG_NUMBER="1234567890123456789012345"
  USAGE_LINE="accepted form: /gaia-debt [<issue-number> ...] [[use] worktree|branch] (numbers may carry a leading # and be separated by spaces or commas)"
}

# parse <interpreter> <stdin text>: run the parser with the text on stdin.
parse() {
  local interpreter="$1"
  run --separate-stderr "$interpreter" "$SCRIPT" <<<"$2"
}

# recognized_rows: one "stdin|stdout" row per line. A literal newline inside a
# stdin value is written as \n and expanded by the driver.
recognized_rows() {
  cat <<EOF
|top
   |top
12|numbers 12
#12|numbers 12
12 34 56|numbers 12 34 56
#12 #34 #56|numbers 12 34 56
12, 34, 56|numbers 12 34 56
12,34,56|numbers 12 34 56
12\n34\n56|numbers 12 34 56
12 12|numbers 12
12 34 12|numbers 12 34
12, ,34|numbers 12 34
$LONG_NUMBER|numbers $LONG_NUMBER
EOF
}

unrecognized_rows() {
  cat <<'EOF'
12x|12x
foo|foo
12 foo|foo
12;id|12;id
$(id)|$(id)
`id`|`id`
0|0
007|007
-5|-5
#|#
##12|##12
fix|fix
fix 12|fix
12 fix|fix
list|list
list worktree|list
why|why
why 12|why
12 why|why
,|,
use|use
worktree 12|12
use 12|12
worktree branch|branch
use worktree use|use
12 use|use
12 use use worktree|use
12 worktree 34|34
12 branch worktree|worktree
12 use worktree branch|branch
12 Worktree|Worktree
12 USE branch|USE
12 please use worktree|please
12 on a branch|on
12 worktrees|worktrees
EOF
}

# isolation_rows: one "stdin|stdout" row per line, stdout's newline written as
# `;`. The suffix is the whole argument, or comes after the numbers, last;
# `use` is optional either way.
isolation_rows() {
  cat <<'EOF'
worktree|top;isolation worktree
branch|top;isolation branch
use worktree|top;isolation worktree
use branch|top;isolation branch
 use worktree |top;isolation worktree
12 worktree|numbers 12;isolation worktree
12 branch|numbers 12;isolation branch
12 use worktree|numbers 12;isolation worktree
12 use branch|numbers 12;isolation branch
#12, #34 worktree|numbers 12 34;isolation worktree
12 34 use branch|numbers 12 34;isolation branch
12,34,worktree|numbers 12 34;isolation worktree
12 12 use worktree|numbers 12;isolation worktree
EOF
}

# run_recognized <interpreter>: drive every recognized row; echo the row count.
run_recognized() {
  local interpreter="$1" row_count=0 row stdin_text expected
  while IFS= read -r row; do
    stdin_text="${row%%|*}"
    expected="${row#*|}"
    row_count=$((row_count + 1))
    # shellcheck disable=SC2059
    stdin_text="$(printf "$stdin_text")"
    parse "$interpreter" "$stdin_text"
    if [ "$status" -ne 0 ] || [ "$output" != "$expected" ]; then
      echo "row '$row': status=$status output='$output'" >&2
      return 1
    fi
  done < <(recognized_rows)
  RECOGNIZED_ROW_COUNT="$row_count"
}

run_unrecognized() {
  local interpreter="$1" row_count=0 row stdin_text token expected_error
  while IFS= read -r row; do
    stdin_text="${row%%|*}"
    token="${row#*|}"
    row_count=$((row_count + 1))
    expected_error="$(printf 'unrecognized argument: %s\n%s' "$token" "$USAGE_LINE")"
    parse "$interpreter" "$stdin_text"
    if [ "$status" -ne 2 ] || [ "$output" != "unrecognized $token" ] || [ "$stderr" != "$expected_error" ]; then
      echo "row '$row': status=$status output='$output' stderr='$stderr'" >&2
      return 1
    fi
  done < <(unrecognized_rows)
  UNRECOGNIZED_ROW_COUNT="$row_count"
}

@test "every recognized form prints its one stdout line and exits 0" {
  run_recognized bash
  [ "$RECOGNIZED_ROW_COUNT" -eq "$(recognized_rows | wc -l | tr -d ' ')" ]
  [ "$RECOGNIZED_ROW_COUNT" -ge 13 ]
}

@test "every unrecognized form exits 2 naming the first offending token" {
  run_unrecognized bash
  [ "$UNRECOGNIZED_ROW_COUNT" -eq "$(unrecognized_rows | wc -l | tr -d ' ')" ]
  [ "$UNRECOGNIZED_ROW_COUNT" -ge 35 ]
}

@test "a bare or trailing [use] worktree|branch names the isolation mode" {
  local row_count=0 row stdin_text expected
  while IFS= read -r row; do
    stdin_text="${row%%|*}"
    expected="$(printf '%s' "${row#*|}" | tr ';' '\n')"
    row_count=$((row_count + 1))
    parse bash "$stdin_text"
    if [ "$status" -ne 0 ] || [ "$output" != "$expected" ]; then
      echo "row '$row': status=$status output='$output'" >&2
      return 1
    fi
  done < <(isolation_rows)
  [ "$row_count" -eq "$(isolation_rows | wc -l | tr -d ' ')" ]
  [ "$row_count" -ge 13 ]
}

@test "a lone newline is the empty argument" {
  run --separate-stderr bash "$SCRIPT" <<<""
  [ "$status" -eq 0 ]
  [ "$output" = "top" ]
}

@test "input is never evaluated" {
  cd "$BATS_TEST_TMPDIR"
  parse bash '$(touch pwned)'
  [ "$status" -eq 2 ]
  parse bash '`touch pwned2`'
  [ "$status" -eq 2 ]
  [ -e "$BATS_TEST_TMPDIR/pwned" ] && return 1
  [ -e "$BATS_TEST_TMPDIR/pwned2" ] && return 1
  true
}

@test "an argv argument is misuse: exit 3, empty stdout, one prefixed stderr line" {
  run --separate-stderr bash "$SCRIPT" 12 </dev/null
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  case "$stderr" in
    "debt-parse-args: "*) ;;
    *) return 1 ;;
  esac
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "unreadable stdin (a directory) is misuse: exit 3, empty stdout" {
  run --separate-stderr bash "$SCRIPT" <"$BATS_TEST_TMPDIR"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  case "$stderr" in
    "debt-parse-args: "*) ;;
    *) return 1 ;;
  esac
}

@test "the script parses under macOS bash 3.2" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash -n "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "one row per grammar branch passes under /bin/bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  local major
  major="$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"')"
  [ "$major" -lt 4 ] || skip "/bin/bash is bash $major, not the 3.2 arm"
  local pairs=("|top" "12, 34 12|numbers 12 34") pair
  for pair in "${pairs[@]}"; do
    parse /bin/bash "${pair%%|*}"
    [ "$status" -eq 0 ]
    [ "$output" = "${pair#*|}" ]
  done
  parse /bin/bash "12, 34 use worktree"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'numbers 12 34\nisolation worktree')" ]
  local refusals=("12x|12x" "fix 12|fix" "list|list" "why 12|why" ",|," "007|007" "12 use|use" "12 worktree 34|34") refusal
  for refusal in "${refusals[@]}"; do
    parse /bin/bash "${refusal%%|*}"
    [ "$status" -eq 2 ]
    [ "$output" = "unrecognized ${refusal#*|}" ]
  done
  run_recognized /bin/bash
  run_unrecognized /bin/bash
}
