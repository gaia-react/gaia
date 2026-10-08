#!/usr/bin/env bats

# Tests for .claude/hooks/lib/git-segments.sh, the segment helpers the two git
# deny guards (block-no-verify.sh, block-main-destructive-git.sh) share. Each
# test sources the library in a fresh bash and calls one function, so a case
# pins the function itself rather than a guard's verdict; the guards' own
# suites pin what they do with the result.

setup() {
  GIT_SEGMENTS_LIBRARY="$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" && pwd)/git-segments.sh"
}

# collapse TEXT: run gaia_collapsed_substitutions on TEXT.
collapse() {
  run bash -c '. "$1" && gaia_collapsed_substitutions "$2"' _ "$GIT_SEGMENTS_LIBRARY" "$1"
}

# command_word SEGMENT: run gaia_segment_command_word on SEGMENT.
command_word() {
  run bash -c '. "$1" && gaia_segment_command_word "$2"' _ "$GIT_SEGMENTS_LIBRARY" "$1"
}

# --- gaia_collapsed_substitutions ---

@test "collapse prints nothing for text with no substitution" {
  collapse 'git commit -m x'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "collapse replaces a substitution with a bare underscore" {
  collapse 'git -C "$(pwd)" commit --no-verify'
  [ "$status" -eq 0 ]
  [ "$output" = 'git -C "_" commit --no-verify' ]
}

@test "collapse replaces a nested substitution over successive passes" {
  collapse 'git -C $(dirname $(pwd)) commit -n'
  [ "$status" -eq 0 ]
  [ "$output" = 'git -C _ commit -n' ]
}

@test "collapse leaves a backtick span uncollapsed, byte for byte" {
  collapse 'git -C `pwd` commit -n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  collapse 'git -C `pwd` commit -m "$(cat f)" -n'
  [ "$status" -eq 0 ]
  [ "$output" = 'git -C `pwd` commit -m "_" -n' ]
}

@test "collapse leaves a substitution spanning a newline alone" {
  collapse $'git commit -m "$(cat\nf)" -n'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- gaia_segment_command_word: one input per strip alternative ---

@test "command word strips leading whitespace" {
  command_word '   git commit'
  [ "$output" = 'git commit' ]
}

@test "command word strips a NAME=value prefix" {
  command_word 'GIT_AUTHOR_NAME=x git commit'
  [ "$output" = 'git commit' ]
}

@test "command word strips a NAME+=value prefix" {
  command_word 'zz+=1 git commit'
  [ "$output" = 'git commit' ]
}

@test "command word strips a double-quoted assignment value carrying a space" {
  command_word 'GIT_AUTHOR_DATE="2024-01-01 12:00" git commit'
  [ "$output" = 'git commit' ]
}

@test "command word strips a single-quoted assignment value carrying a space" {
  command_word "GIT_AUTHOR_DATE='2024-01-01 12:00' git commit"
  [ "$output" = 'git commit' ]
}

@test "command word strips a leading redirection" {
  command_word '>/tmp/out git commit'
  [ "$output" = 'git commit' ]
  command_word '2>/dev/null git commit'
  [ "$output" = 'git commit' ]
}

@test "command word strips a brace and a bang" {
  command_word '{ git commit'
  [ "$output" = 'git commit' ]
  command_word '! git commit'
  [ "$output" = 'git commit' ]
}

@test "command word strips each reserved word" {
  local reserved_word
  for reserved_word in 'coproc' 'elif' 'else' 'while' 'until' 'then' 'do' 'if'; do
    command_word "$reserved_word git commit"
    [ "$output" = 'git commit' ]
  done
}

@test "command word strips time with its optional -p and --" {
  command_word 'time git commit'
  [ "$output" = 'git commit' ]
  command_word 'time -p git commit'
  [ "$output" = 'git commit' ]
  command_word 'time -- git commit'
  [ "$output" = 'git commit' ]
}

@test "command word strips a run of mixed prefixes" {
  command_word 'then A=1 B+=2 >/dev/null time -p git push'
  [ "$output" = 'git push' ]
}

@test "command word leaves a wrapper in place" {
  command_word 'env -i git commit'
  [ "$output" = 'env -i git commit' ]
}

@test "command word leaves a segment with no prefix unchanged" {
  command_word 'ls -la'
  [ "$output" = 'ls -la' ]
}

# --- sourcing contract ---

@test "sourcing the library does no work and prints nothing" {
  run bash -c '. "$1"' _ "$GIT_SEGMENTS_LIBRARY"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "sourcing the library twice keeps both functions defined" {
  run bash -c '. "$1" && . "$1" && type gaia_collapsed_substitutions && type gaia_segment_command_word' _ "$GIT_SEGMENTS_LIBRARY"
  [ "$status" -eq 0 ]
}

@test "the library parses under the stock macOS bash" {
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash -n "$GIT_SEGMENTS_LIBRARY"
  [ "$status" -eq 0 ]
}
