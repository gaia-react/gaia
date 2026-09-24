#!/usr/bin/env bats
# doc-grep coverage for the `promote` action's source-side contract in
# `.claude/skills/gaia/references/audit.md`, stated only as prose and read by
# a Sonnet Stage 1 that writes the action blocks and a Sonnet Stage 2 that
# applies them.
#
# The one claim pinned here: a same-file extraction (lifting a section out of
# an over-budget file onto a wiki page) is a single `promote` action, never a
# `promote` plus a separate `shrink` on that same `source_path`.
#
# Assertion style: .claude/rules/bats-assertions.md.

# extract_section <file> <start_ERE> <terminator_ERE>
# Prints from the first line matching <start_ERE> (inclusive) up to,
# excluding, the next line matching <terminator_ERE>.
extract_section() {
  awk -v start="$2" -v term="$3" '
    $0 ~ start { found=1; print; next }
    found && $0 ~ term { exit }
    found { print }
  ' "$1"
}

# extract_section_or_fail <file> <start_ERE> <terminator_ERE>
# extract_section, plus guards on both ends. Never call this on the left of
# a pipe: a pipeline's exit status is its LAST command's, so capture first,
# normalize second.
extract_section_or_fail() {
  local out start_line
  out="$(extract_section "$1" "$2" "$3")"
  [ -n "$out" ] || {
    echo "section anchor '${2}' matched nothing in ${1}; a scoped assertion here would pass vacuously" >&2
    return 1
  }
  start_line="$(awk -v start="$2" '$0 ~ start { print NR; exit }' "$1")"
  [ -n "$start_line" ] || {
    echo "start anchor '${2}' resolved to no line number in ${1}" >&2
    return 1
  }
  awk -v s="$start_line" -v term="$3" 'NR > s && $0 ~ term { found = 1; exit } END { exit !found }' "$1" || {
    echo "terminator '${3}' matches nothing after line ${start_line} of ${1}; either the section ran to EOF and swallowed the rest of the file, or it is the file's last section, which this helper does not support" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# normalize_ws
# Collapses newlines and runs of whitespace to single spaces and trims the
# ends, so a sentence rewrapped at another width still compares equal.
normalize_ws() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# scoped <start_ERE> <terminator_ERE>
# extract_section_or_fail + normalize_ws, in the two-step order that keeps
# the guard's exit status (see its header).
scoped() {
  local out
  out="$(extract_section_or_fail "$AUDIT" "$1" "$2")" || return 1
  printf '%s\n' "$out" | normalize_ws
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  AUDIT="$ROOT/.claude/skills/gaia/references/audit.md"

  # `-s`, not `-f`: an empty file would satisfy `-f` and only then fail
  # obliquely, inside `extract_section_or_fail`'s own vacuous-match guard,
  # rather than with a clear message naming the missing source here.
  [ -s "$AUDIT" ] || {
    echo "missing or empty $AUDIT" >&2
    return 1
  }
}

@test "the schema states that a same-file extraction is this one action" {
  local promote
  promote="$(scoped '^### Promote' '^### ')"
  grep -qF -- 'never a promote plus a `shrink` on `source_path`' <<<"$promote"
}
