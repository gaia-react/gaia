#!/usr/bin/env bats

# Contract and cost budget for gaia_scan_first_command
# (.claude/hooks/lib/repo-scope.sh), the word scanner both gaia_scan_gh_merge
# and cmd_targets_foreign_repo_slug read a tool call's first command through.
#
# WHY A COST BUDGET LIVES BESIDE THE CONTRACT TESTS. The scanner walks its
# input one character at a time, and the only thing that bounds how much text
# one word holds is the input itself: inside a quoted span whitespace,
# separators and newlines are all ordinary text, so a quoted `--body` is a
# single word however long the prose is. Accumulating that word one character
# at a time is quadratic, which made an ordinary multi-kilobyte pull-request
# body a multi-second synchronous stall in front of the user on a deny-capable
# gate. The scanner now accumulates into a block-bounded chunk and appends
# that chunk to the word once per block, and skips whole runs of ordinary text
# inside a quoted span in one shell operation. Both are pure cost changes, so
# the contract tests below are what prove they changed nothing observable, and
# the ceilings are what keep the quadratic form from coming back unnoticed.
#
# MEASURED (Apple Silicon macOS; bash 3.2.57 stock /bin/bash and bash 5.3.15
# Homebrew; a quoted --body of the stated size, library call, no hook process):
#
#   size    before        after
#   16KB    ~893-904ms    ~9-11ms
#   32KB    ~3060-3103ms  ~27-30ms
#
# Every ceiling below states its own headroom (over the measured after-figure)
# and its margin (below the measured before-figure, the failure mode it is
# actually guarding against), so a slow shared runner cannot red a ceiling and
# only losing the bulk accumulation can.
#
# Maintainer-only: `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

bats_require_minimum_version 1.5.0

setup() {
  LIB=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/repo-scope.sh

  # An ASCII record separator: no test payload below contains one, so joining
  # the scanned words with it is unambiguous even for a word holding a
  # newline, a space, or an empty string.
  RS=$'\036'

  # Assembled rather than written whole so this file's own text does not read
  # as a merge command to the repo's verb-arming hooks when it is edited.
  MERGE_PREFIX='gh pr me'
  MERGE_PREFIX="${MERGE_PREFIX}rge 5 --squash --body"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Runs gaia_scan_first_command on CMD in a fresh child shell and prints a
# canonical record: the return code, the closed flag, the word count, and the
# words joined by RS.
#
# The payload reaches the child on a FILE, never in argv. Linux caps a single
# exec argument at MAX_ARG_STRLEN (128KB) independently of the much larger
# total ARG_MAX, and passing a payload through argv would make the cost tests
# below depend on that cap rather than on the scanner. The read happens
# outside the timed region in time_scan_ms, so the round-trip never enters a
# measurement.
scan_record() {
  local cmd="$1" cmdfile rec
  cmdfile=$(mktemp)
  printf '%s' "$cmd" > "$cmdfile"
  rec=$(bash -c '
    . "$1"
    # -d "" reads to NUL, i.e. the whole file, keeping a trailing newline that
    # a $(<file) substitution would strip. Non-zero at EOF is expected.
    IFS= read -r -d "" _cmd < "$2" || :
    if gaia_scan_first_command "$_cmd"; then printf "rc=0\n"; else printf "rc=1\n"; fi
    printf "closed=%s\n" "$GAIA_FIRST_COMMAND_CLOSED"
    printf "n=%s\n" "${#GAIA_FIRST_COMMAND_WORDS[@]}"
    sep=""
    for w in ${GAIA_FIRST_COMMAND_WORDS[@]+"${GAIA_FIRST_COMMAND_WORDS[@]}"}; do
      printf "%s%s" "$sep" "$w"
      sep="$3"
    done
  ' _ "$LIB" "$cmdfile" "$RS")
  rm -f "$cmdfile"
  printf '%s' "$rec"
}

# assert_scan <cmd> <want_rc> <want_closed> [<want_word>...]
#
# Ends its failing branch with an explicit `return 1` rather than leaning on a
# bare comparison, per .claude/rules/bats-assertions.md: a non-final assertion
# has to fail on its own on bash 3.2.
assert_scan() {
  local cmd="$1" want_rc="$2" want_closed="$3"
  shift 3
  local joined="" sep="" w want rec
  for w in "$@"; do
    joined="$joined$sep$w"
    sep="$RS"
  done
  want="rc=$want_rc
closed=$want_closed
n=$#
$joined"
  rec=$(scan_record "$cmd")
  if [ "$rec" != "$want" ]; then
    printf 'scan mismatch\n--- want ---\n%s\n--- got ---\n%s\n' "$want" "$rec" >&2
    return 1
  fi
}

# A quoted `--body` of exactly TOTAL characters of ordinary text. Whitespace
# inside the span would be ordinary text too, so filler needs no spaces to
# reproduce the one-long-word shape a real prose body takes.
build_quoted_body() {
  local total="$1" body
  body=$(head -c "$total" < /dev/zero | tr '\0' 'y')
  printf '%s "%s"' "$MERGE_PREFIX" "$body"
}

# Times one gaia_scan_first_command call with no hook process around it, and
# sets REPLY_MS to the elapsed wall time in milliseconds. Uses bash's own
# `time` reserved word plus TIMEFORMAT, a builtin with millisecond-plus
# resolution on every bash version, so nothing here depends on a GNU-only
# (`date +%s%N`) or BSD-only (`date -v`) flag.
time_scan_ms() {
  local text="$1" textfile t
  textfile=$(mktemp)
  printf '%s' "$text" > "$textfile"
  t=$(bash -c '
    TIMEFORMAT="%R"
    . "$1"
    IFS= read -r -d "" _text < "$2" || :
    { time gaia_scan_first_command "$_text" >/dev/null; } 2>&1
  ' _ "$LIB" "$textfile")
  rm -f "$textfile"
  REPLY_MS=$(awk -v s="$t" 'BEGIN{printf "%d", (s*1000)+0.5}')
}

# ---------------------------------------------------------------------------
# Ceilings
# ---------------------------------------------------------------------------

# One scan of a 16KB quoted body. Measured ~9-11ms after, ~893-904ms before.
# Headroom: 250/11 ~= 22x. Margin below the quadratic figure: 904/250 ~= 3.6x.
# 16KB is the size that matters most: GAIA_VERB_ARM_MAX_CHARS is 16,384, so a
# payload at this size is the largest one still inside the armed population,
# and the quadratic cost was already ~0.9s there.
CEILING_SCAN_16K_MS=250

# One scan of a 32KB quoted body. Measured ~27-30ms after, ~3060-3103ms
# before. Headroom: 400/30 ~= 13x. Margin below the quadratic figure:
# 3060/400 ~= 7.7x. Doubling the size must not quadruple the time, which is
# what this second ceiling, set at well under 2x the first, actually pins.
CEILING_SCAN_32K_MS=400

# ---------------------------------------------------------------------------
# Contract: quoted spans
#
# These are the cases the bulk run-skipping touches. Inside a span the scan
# stops only at the closing quote and, in a double-quoted span, at a
# backslash; everything else is ordinary text however it would read unquoted.
# ---------------------------------------------------------------------------

@test "scan: an escaped double quote stays inside the double-quoted word" {
  assert_scan "$MERGE_PREFIX \"a\\\"b\"" 0 0 gh pr merge 5 --squash --body 'a"b'
}

@test "scan: an escaped backslash collapses to one inside a double-quoted word" {
  assert_scan "$MERGE_PREFIX \"a\\\\b\"" 0 0 gh pr merge 5 --squash --body 'a\b'
}

@test "scan: a backslash is literal inside a single-quoted word" {
  assert_scan "$MERGE_PREFIX 'a\\b'" 0 0 gh pr merge 5 --squash --body 'a\b'
}

@test "scan: a double quote is ordinary text inside a single-quoted word" {
  assert_scan "$MERGE_PREFIX 'a\"b'" 0 0 gh pr merge 5 --squash --body 'a"b'
}

@test "scan: a single quote is ordinary text inside a double-quoted word" {
  assert_scan "$MERGE_PREFIX \"a'b\"" 0 0 gh pr merge 5 --squash --body "a'b"
}

@test "scan: separators inside a quoted span do not close the command" {
  assert_scan "$MERGE_PREFIX \"a; b | c && d\"" 0 0 \
    gh pr merge 5 --squash --body 'a; b | c && d'
}

@test "scan: a newline inside a quoted span is ordinary text" {
  assert_scan "$MERGE_PREFIX \"a"$'\n'"b\"" 0 0 \
    gh pr merge 5 --squash --body "a"$'\n'"b"
}

@test "scan: a hash inside a quoted span does not open a comment" {
  assert_scan "$MERGE_PREFIX \"a #b\"" 0 0 gh pr merge 5 --squash --body 'a #b'
}

@test "scan: an empty quoted span still yields a word" {
  assert_scan "$MERGE_PREFIX \"\"" 0 0 gh pr merge 5 --squash --body ''
}

@test "scan: adjacent quoted and unquoted pieces join into one word" {
  assert_scan 'a"b"'"'"'c'"'"'d e' 0 0 abcd e
}

@test "scan: an unterminated quote still yields the text it opened" {
  assert_scan "$MERGE_PREFIX \"abc" 0 0 gh pr merge 5 --squash --body abc
}

@test "scan: a separator after a closing quote closes the command" {
  assert_scan "$MERGE_PREFIX \"ab\" && echo hi" 0 1 \
    gh pr merge 5 --squash --body ab
}

# ---------------------------------------------------------------------------
# Contract: block boundaries
#
# The scan slices its input into fixed-size blocks and accumulates a chunk per
# block, so a word that spans a block edge is the case where a bulk
# accumulation can lose or duplicate text. These sizes straddle the 256-byte
# block on both sides and land exactly on it.
# ---------------------------------------------------------------------------

@test "scan: a quoted word spanning block boundaries survives intact" {
  local size body
  for size in 255 256 257 511 512 513; do
    body=$(head -c "$size" < /dev/zero | tr '\0' 'y')
    assert_scan "$MERGE_PREFIX \"$body\"" 0 0 \
      gh pr merge 5 --squash --body "$body" || return 1
  done
}

@test "scan: an unquoted word spanning block boundaries survives intact" {
  local size word
  for size in 255 256 257 511 512 513; do
    word=$(head -c "$size" < /dev/zero | tr '\0' 'z')
    assert_scan "$MERGE_PREFIX $word end" 0 0 \
      gh pr merge 5 --squash --body "$word" end || return 1
  done
}

@test "scan: a quoted word whose escape straddles a block boundary survives" {
  local size body
  # 254 and 255 put the backslash of the trailing \" on either side of the
  # 256-byte edge, and 256 puts the escaped quote itself across it.
  for size in 254 255 256; do
    body=$(head -c "$size" < /dev/zero | tr '\0' 'y')
    assert_scan "$MERGE_PREFIX \"$body\\\"tail\"" 0 0 \
      gh pr merge 5 --squash --body "${body}\"tail" || return 1
  done
}

# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------

@test "cost: one scan of a 16KB quoted body stays inside the ceiling" {
  local p
  p=$(build_quoted_body 16384)
  time_scan_ms "$p"
  echo "scan 16KB: ${REPLY_MS}ms (ceiling ${CEILING_SCAN_16K_MS}ms)" >&2
  [ "$REPLY_MS" -le "$CEILING_SCAN_16K_MS" ]
}

@test "cost: doubling a quoted body to 32KB does not quadruple the scan" {
  local p
  p=$(build_quoted_body 32768)
  time_scan_ms "$p"
  echo "scan 32KB: ${REPLY_MS}ms (ceiling ${CEILING_SCAN_32K_MS}ms)" >&2
  [ "$REPLY_MS" -le "$CEILING_SCAN_32K_MS" ]
}
