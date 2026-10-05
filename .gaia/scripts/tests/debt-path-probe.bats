#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-path-probe.sh, the /gaia-debt staleness probe.
# Each status (tracked, gone, keyless) is driven from a scratch repository,
# then the index-not-filesystem and exact-match rules, every refusal and
# unreadable-input arm, and the data-not-command-text property: a dedup-key
# path comes from an editable issue body, so shell metacharacters in it must
# be compared as data and never executed.
#
# The script is resolved from DEBT_PATH_PROBE_SCRIPT when set, so a scratch
# copy (the old interpolating probe included) can be run through the same
# assertions to prove they can fail.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/debt-path-probe.bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${DEBT_PATH_PROBE_SCRIPT:-$(cd "$BATS_TEST_DIRNAME/.." && pwd)/debt-path-probe.sh}"
  REPO="$BATS_TEST_TMPDIR/repo"
  BACKLOG="$BATS_TEST_TMPDIR/backlog.json"
  export SCRIPT
  mkdir -p "$REPO/src" "$REPO/docs" "$REPO/build"
  git -C "$REPO" init -q
  printf 'x\n' >"$REPO/src/app.ts"
  printf 'x\n' >"$REPO/docs/my notes.md"
  printf 'x\n' >"$REPO/build/out.js" # on disk, never added
  git -C "$REPO" add -- src/app.ts "docs/my notes.md"
}

# write_backlog <path>...: a backlog of one keyed issue per path, numbered
# 1..n in order. A path of "-" writes a null key instead.
write_backlog() {
  local path index=0 members=""
  for path in "$@"; do
    index=$((index + 1))
    members="$members$(jq -nc --argjson number "$index" --arg p "$path" \
      '{number: $number, sev: 1, body: "unused",
        key: (if $p == "-" then null else {class: "c", path: $p, line: 1} end)}'),"
  done
  printf '[%s]' "${members%,}" >"$BACKLOG"
}

# probe: runs the script from inside the scratch repository, backlog on stdin.
probe() {
  run --separate-stderr bash -c 'cd "$1" && bash "$SCRIPT" <"$2"' _ "$REPO" "$BACKLOG"
}

# status_of <number>: the reported status of one issue in $output.
status_of() {
  printf '%s' "$output" | jq -r --argjson n "$1" '.[] | select(.number == $n) | .status'
}

# ========== statuses ==========

@test "a tracked path reports tracked" {
  write_backlog src/app.ts
  probe
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "tracked" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].path')" = "src/app.ts" ]
}

@test "a tracked path containing a space reports tracked" {
  write_backlog "docs/my notes.md"
  probe
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "tracked" ]
}

@test "a path absent from the index reports gone" {
  write_backlog src/renamed.ts
  probe
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "gone" ]
}

@test "an issue with a null key reports keyless with a null path" {
  write_backlog -
  probe
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "keyless" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].path')" = "null" ]
}

@test "every issue is reported once, in backlog order" {
  write_backlog src/app.ts - src/renamed.ts "docs/my notes.md"
  probe
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.[] | [.number, .status]]')" \
    = '[[1,"tracked"],[2,"keyless"],[3,"gone"],[4,"tracked"]]' ]
}

@test "an empty backlog reports an empty array" {
  printf '[]' >"$BACKLOG"
  probe
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c .)" = "[]" ]
}

# ========== index, exact match ==========

@test "an untracked file on disk at the path still reports gone" {
  write_backlog build/out.js
  probe
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "gone" ]
}

@test "a directory, a glob, and pathspec magic are not file matches" {
  write_backlog src "src/*.ts" ":(top)src/app.ts" "src/app.ts/"
  probe
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.[].status]')" = '["gone","gone","gone","gone"]' ]
}

@test "the index is read from the repository root when run from a subdirectory" {
  write_backlog src/app.ts "docs/my notes.md"
  run --separate-stderr bash -c 'cd "$1/docs" && bash "$SCRIPT" <"$2"' _ "$REPO" "$BACKLOG"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '[.[].status]')" = '["tracked","tracked"]' ]
}

# ========== data, not command text ==========

@test "a path carrying command substitution is reported gone and never executed" {
  local marker="$BATS_TEST_TMPDIR/marker-dollar"
  write_backlog "src/\$(touch $marker).ts"
  probe
  [ -e "$marker" ] && return 1
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "gone" ]
  [ "$(printf '%s' "$output" | jq -r '.[0].path')" = "src/\$(touch $marker).ts" ]
}

@test "a path carrying backticks is reported gone and never executed" {
  local marker="$BATS_TEST_TMPDIR/marker-backtick"
  write_backlog "src/\`touch $marker\`.ts"
  probe
  [ -e "$marker" ] && return 1
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "gone" ]
}

@test "a path that closes the quote and chains a command is never executed" {
  local marker="$BATS_TEST_TMPDIR/marker-quote"
  write_backlog "src/a.ts\"; touch \"$marker"
  probe
  [ -e "$marker" ] && return 1
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "gone" ]
}

@test "a tracked file whose name is literally a command substitution reports tracked" {
  printf 'x\n' >"$REPO/src/\$(touch pwned).ts"
  git -C "$REPO" add -- "src/\$(touch pwned).ts"
  write_backlog "src/\$(touch pwned).ts"
  probe
  [ -e "$REPO/pwned" ] && return 1
  [ "$status" -eq 0 ]
  [ "$(status_of 1)" = "tracked" ]
}

# ========== refusals ==========

@test "refusal: a backlog that is a JSON object" {
  printf '{"number": 1}' >"$BACKLOG"
  probe
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-path-probe: "* ]]
}

@test "refusal: an issue without a numeric number" {
  printf '[{"number": "1", "key": null}]' >"$BACKLOG"
  probe
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-path-probe: "* ]]
}

@test "refusal: any argument at all" {
  write_backlog src/app.ts
  run --separate-stderr bash -c 'cd "$1" && bash "$SCRIPT" src/app.ts <"$2"' _ "$REPO" "$BACKLOG"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-path-probe: "* ]]
}

# ========== unreadable input ==========

@test "unreadable: empty stdin" {
  run --separate-stderr bash -c 'cd "$1" && bash "$SCRIPT" </dev/null' _ "$REPO"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-path-probe: "* ]]
}

@test "unreadable: stdin that is not JSON" {
  printf 'not json at all' >"$BACKLOG"
  probe
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-path-probe: "* ]]
}

@test "unreadable: outside a git repository" {
  write_backlog src/app.ts
  mkdir -p "$BATS_TEST_TMPDIR/plain"
  run --separate-stderr env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" \
    bash -c 'cd "$1" && bash "$SCRIPT" <"$2"' _ "$BATS_TEST_TMPDIR/plain" "$BACKLOG"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-path-probe: "* ]]
}

@test "unreadable: jq absent from PATH is exit 3 and the message names jq" {
  write_backlog src/app.ts
  local tools="$BATS_TEST_TMPDIR/tools"
  mkdir -p "$tools"
  ln -s "$(command -v bash)" "$tools/bash"
  ln -s "$(command -v cat)" "$tools/cat"
  ln -s "$(command -v git)" "$tools/git"
  run --separate-stderr bash -c 'cd "$1" && PATH="$3" "$3/bash" "$SCRIPT" <"$2"' _ "$REPO" "$BACKLOG" "$tools"
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [[ "$stderr" == "debt-path-probe: "*jq* ]]
}
