#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-debt's backlog-ordering `--jq` query
# (.claude/skills/gaia/references/debt.md), the most load-bearing line in the
# file: the deterministic sort every subcommand (list, why, fix) shares, and
# the source of the `labels`, `key`, `body`, and `handler` fields the
# clustering pass, the two security screens, and the spec screen all read.
#
# Two arms.
#
# ARM 1 (structural greps) anchors extraction on the `--jq '` line, the only
# one of debt.md's four fenced blocks that carries it (verify with
# `grep -c -- "--jq '" .claude/skills/gaia/references/debt.md`, which returns
# 1), so a naive first-fenced-block grab can never land on the reconcile
# pre-pass query instead, where every negative assertion below would pass
# vacuously. It carries a positive `sort_by` assertion for the same reason:
# proof the extraction landed on the ordering query, not a silent pass on the
# wrong block.
#
# ARM 2 (executable render) is the stronger gate and the reason this suite
# exists: it extracts the `--jq` PROGRAM TEXT out of debt.md with awk, feeds
# it a synthetic fixture (fixtures/debt-query/backlog.json, four issues, none
# real, not captured from git the way the isolation suite's golden fixtures
# are), and asserts on the emitted objects. Do not "simplify" this back into a
# hand-copied program: rendering it from the artifact is what makes the gate
# measure debt.md instead of measuring itself, and a hand-copied program would
# stay green through a regression in the real file.
#
# Arm 2 asserts one key at a time (`.key.line`, `.handler`, `.labels`,
# `.body`), never a whole-object comparison. A later phase adds a `difficulty`
# field to this same program; a whole-object assertion would break on a change
# that is correct by design, a per-key assertion does not.
#
# Engine note: `gh --jq` runs gojq (Go regexp, where `(?m)` enables line
# anchors); a local `jq` runs Oniguruma (where `^` is always a line anchor and
# `(?m)` means dotall, harmless here since the pattern contains no `.`). The
# one frozen form in debt.md is correct under both. Arm 2 runs under whichever
# engine is on PATH and skips with a message if neither is present; GitHub's
# ubuntu-latest image ships `jq`, so the arm runs in CI.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test, and a
# `!`-negated command never fails a non-final line on any bash. Absence checks
# are written as `<positive-condition-for-the-bad-case> && return 1`, which
# means a test whose LAST statement is such a check ends with an explicit
# `true`.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DEBT_MD="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/debt-query/backlog.json"
}

# Resolves to `jq` or `gojq`, whichever is on PATH; empty if neither.
jq_bin() {
  if command -v jq >/dev/null 2>&1; then
    echo jq
  elif command -v gojq >/dev/null 2>&1; then
    echo gojq
  fi
}

# The ordering query's whole fenced code block, anchored on the unique
# `--jq '` line: the last ``` fence before it opens the block, the first ```
# fence after it closes it. Arm 1's structural greps run over this.
extract_query_fence() {
  local jq_line start end
  jq_line=$(grep -n -F -- "--jq '" "$DEBT_MD" | head -1 | cut -d: -f1)
  start=$(awk -v n="$jq_line" 'NR < n && /^```/ { s = NR } END { print s + 0 }' "$DEBT_MD")
  end=$(awk -v n="$jq_line" 'NR > n && /^```/ { print NR; exit }' "$DEBT_MD")
  sed -n "${start},${end}p" "$DEBT_MD"
}

# The bare `--jq` PROGRAM TEXT, from the line after the `--jq '` anchor up to
# the line whose only non-whitespace content is a closing `'`. Arm 2 executes
# this directly; it is never hand-copied into the suite.
extract_jq_program() {
  awk -v q="'" '
    index($0, "--jq " q) { found = 1; next }
    found && $0 ~ "^[ \t]*" q "[ \t]*$" { exit }
    found { print }
  ' "$DEBT_MD"
}

# Runs the extracted program against the fixture and prints the JSON result.
# Callers guard with `[ -n "$(jq_bin)" ] || skip ...` first.
render_backlog() {
  "$(jq_bin)" "$(extract_jq_program)" "$FIXTURE"
}

@test "Arm 1: the ordering query keeps --limit 1000, the silent-truncation repair" {
  block="$(extract_query_fence)"
  printf '%s\n' "$block" | grep -qF -- "--limit 1000" || return 1
}

@test "Arm 1: labels project as name strings, not raw label objects" {
  block="$(extract_query_fence)"
  printf '%s\n' "$block" | grep -qF -- "labels: [.labels[].name]" || return 1
}

@test "Arm 1: the dedup key is captured with the v1 gaia-debt-key prefix" {
  block="$(extract_query_fence)"
  printf '%s\n' "$block" | grep -qF -- "capture(" || return 1
  printf '%s\n' "$block" | grep -qF -- "<!-- gaia-debt-key: v1 " || return 1
}

@test "Arm 1: the Handler: line is captured" {
  block="$(extract_query_fence)"
  printf '%s\n' "$block" | grep -qF -- "^Handler:" || return 1
}

@test "Arm 1: body is emitted unconditionally, with nothing nulling it" {
  block="$(extract_query_fence)"
  printf '%s\n' "$block" | grep -qF -- "body," || return 1
  # The bad case: a computed/conditional `body:` value. The repaired query
  # only ever emits `body` as a bare shorthand key.
  printf '%s\n' "$block" | grep -qF -- "body:" && return 1
  true
}

@test "Arm 1: sort_by is unchanged, and the extraction landed on the ordering query, not the reconcile pre-pass" {
  block="$(extract_query_fence)"
  # The reconcile pre-pass carries no sort_by at all, so a wrong-block
  # extraction fails loudly here instead of passing the negative test below
  # vacuously.
  printf '%s\n' "$block" | grep -qF -- "sort_by([(-.sev), .createdAt])" || return 1
}

@test "Arm 1: the block never projects a bare number/title/createdAt straight into sev, the original defect" {
  block="$(extract_query_fence)"
  flat="$(printf '%s\n' "$block" | tr '\n' ' ' | tr -s ' ')"
  printf '%s' "$flat" | grep -qF -- "createdAt, sev:" && return 1
  true
}

@test "Arm 2: the top-severity issue sorts first" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  output="$(render_backlog)"
  [ "$(jq '.[0].number' <<<"$output")" = "101" ]
}

@test "Arm 2: labels project as an array of strings" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  output="$(render_backlog)"
  [ "$(jq -r '.[0].labels | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.[0].labels[0] | type' <<<"$output")" = "string" ]
}

@test "Arm 2: key.line coerces to a JSON number, distinguishing line=4 from line=42" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  output="$(render_backlog)"
  issue1="$(jq --arg n 101 '.[] | select(.number == ($n | tonumber))' <<<"$output")"
  issue2="$(jq --arg n 102 '.[] | select(.number == ($n | tonumber))' <<<"$output")"
  [ "$(jq '.key.line' <<<"$issue1")" = "4" ]
  [ "$(jq -r '.key.line | type' <<<"$issue1")" = "number" ]
  [ "$(jq '.key.line' <<<"$issue2")" = "42" ]
}

@test "Arm 2: handler resolves the parsed Handler: value" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  output="$(render_backlog)"
  issue1="$(jq --arg n 101 '.[] | select(.number == ($n | tonumber))' <<<"$output")"
  issue2="$(jq --arg n 102 '.[] | select(.number == ($n | tonumber))' <<<"$output")"
  [ "$(jq -r '.handler' <<<"$issue1")" = "prompt" ]
  [ "$(jq -r '.handler' <<<"$issue2")" = "plan" ]
}

@test "Arm 2: a malformed key and a keyless issue both emit key: null and handler: null" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  output="$(render_backlog)"
  issue3="$(jq --arg n 103 '.[] | select(.number == ($n | tonumber))' <<<"$output")"
  issue4="$(jq --arg n 104 '.[] | select(.number == ($n | tonumber))' <<<"$output")"
  [ "$(jq '.key' <<<"$issue3")" = "null" ]
  [ "$(jq '.handler' <<<"$issue3")" = "null" ]
  [ "$(jq '.key' <<<"$issue4")" = "null" ]
  [ "$(jq '.handler' <<<"$issue4")" = "null" ]
}

@test "Arm 2: every issue emits a non-empty string body, the security-screen contract made mechanical" {
  bin="$(jq_bin)"
  [ -n "$bin" ] || skip "neither jq nor gojq on PATH"
  output="$(render_backlog)"
  for n in 101 102 103 104; do
    issue="$(jq --arg n "$n" '.[] | select(.number == ($n | tonumber))' <<<"$output")"
    [ "$(jq -r '.body | type' <<<"$issue")" = "string" ] || return 1
    body_len="$(jq -r '.body | length' <<<"$issue")"
    [ "$body_len" -gt 0 ] || return 1
  done
}
