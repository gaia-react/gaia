#!/usr/bin/env bats
# doc-grep coverage for how a Code Audit Team member hands its findings array
# to the shared sidecar writer (`.gaia/scripts/audit-write-findings.sh`).
#
# The defect this pins: every member spec prescribed the call with a bare
# `--findings /path/to/findings.json` placeholder. `wiki/concepts/PR Merge
# Workflow.md` dispatches every member in parallel from one message, and
# members dispatched from one session share a scratchpad, so each converges on
# the same `findings.json`. The published path is per-member and per-audit-key
# and therefore looks right; the staging file is what the writer READS, so
# member A can publish member B's array under A's name, and a file left by an
# earlier round republishes as a fresh report. Both are silent: the sidecar is
# the report of record, and `audit-noop-detect.sh --findings` reads it to tell
# a real pass from a member whose report was lost, so the gate still greens.
# Observed live during a round on PR #1186, where the prose member found a
# stale staging file holding another member's findings.
#
# The fix is stdin, not a better filename. A name derived from the audit key
# closes the cross-member collision but not the stale-round one, because the
# key is a base sha plus a branch and rotates between neither. Reading the
# array from stdin removes the staging file, so there is no name to collide on
# and nothing to leave behind.
#
# The quoted heredoc delimiter is load-bearing rather than stylistic: finding
# text carries `$` tokens and backticks routinely (this suite's own subject
# matter is shell prose), and an unquoted delimiter expands them before the
# writer ever validates the array.
#
# Nothing type-checks an agent spec and no runtime assertion fires when a
# prescribed command drifts, so this suite is the mechanism, following
# `doc-audit-remedy-set.bats` and `doc-audit-verification-gate.bats` in this
# directory: grep for frozen literals, ground-truthed against the source text.
#
# The roster comes from the `code-audit-*.md` glob rather than a hardcoded
# list, so a sixth member joins the guard by existing. The **first `@test`**
# pins the five known specs as a floor, and it is what keeps the rest of the
# suite honest: `setup()` asserts nothing, it builds the list and skips what it
# cannot read, so on an empty glob every per-spec loop below iterates zero
# times and reports `ok`. Do not delete or weaken that test to quiet a roster
# change; add the new member to it.
#
# Assertion style (.claude/rules/bats-assertions.md): macOS /bin/bash is 3.2,
# where a false non-final bare `[[ ]]` does not fail the test and a `!`-negated
# command never fails a non-final line on any bash. Every absence check below
# is written as `<positive-condition-for-the-bad-case> && return 1`, and a test
# whose last statement is such a check ends with an explicit `true`.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  SPECS=()
  for f in "$ROOT"/.claude/agents/code-audit-*.md; do
    # `-s`, not `-f`: an empty file satisfies `-f` and then greens every
    # absence check below on nothing.
    [ -s "$f" ] || continue
    SPECS+=("$f")
  done
}

# --- Group 1: the roster the rest of the suite walks -----------------------

@test "the glob resolves to at least the five known Code Audit Team specs" {
  [ "${#SPECS[@]}" -ge 5 ]
  for member in \
    code-audit-frontend \
    code-audit-github-workflows \
    code-audit-maintainer-node \
    code-audit-maintainer-prose \
    code-audit-maintainer-shell; do
    [ -s "$ROOT/.claude/agents/${member}.md" ] || {
      echo "roster member ${member}.md is missing or empty; every per-spec loop here would skip it silently" >&2
      return 1
    }
  done
}

# --- Group 2: the prescribed call reads the array from stdin ---------------

@test "every findings invocation in every spec is the stdin form" {
  # An invocation is a continuation line inside a fenced command, so it starts
  # the line; a prose mention of the flag does not, and a spec that explains
  # itself is not a defect. Prose that hands the writer a path is caught by the
  # two absence checks below, which are deliberately not anchored.
  #
  # Every anchored line is compared against the pinned form directly rather
  # than by counting both populations and comparing the totals. Two counts
  # invite two scopes: an anchored total against an unanchored one is
  # satisfiable from prose, so a spec carrying one staged invocation and one
  # prose copy of the pinned literal would balance and pass. Matching line by
  # line has no arithmetic to get backwards and names the offending line.
  for f in "${SPECS[@]}"; do
    local invocations offenders
    invocations="$(grep -nE '^[[:space:]]*--findings' "$f" || true)"
    [ -n "$invocations" ] || {
      echo "$f prescribes no sidecar write at all" >&2
      return 1
    }
    offenders="$(printf '%s\n' "$invocations" | grep -vF -- "--findings - <<'FINDINGS'" || true)"
    [ -z "$offenders" ] || {
      echo "$f: invocation not in the pinned quoted-heredoc form: $offenders" >&2
      return 1
    }
  done
}

@test "no spec still prescribes the shared staging filename" {
  # The original defect, verbatim. Every member handed this same placeholder,
  # which is what made one filename the filename all of them picked.
  for f in "${SPECS[@]}"; do
    grep -qF -- '--findings /path/to/findings.json' "$f" && return 1
  done
  true
}

@test "no spec passes a staged path of any shape to --findings" {
  # The general form, so a per-member or per-key filename does not read as a
  # fix. `- <<` is the only admitted argument; anything else is a file, and a
  # file is a name two concurrently dispatched members can both choose.
  for f in "${SPECS[@]}"; do
    grep -qE -- '--findings +[^-]' "$f" && return 1
  done
  true
}

# --- Group 3: the heredoc itself -------------------------------------------

@test "every findings heredoc is closed" {
  # An unterminated heredoc consumes the rest of the block, so the writer
  # never runs and the member reports a sidecar it did not write.
  for f in "${SPECS[@]}"; do
    local openers terminators
    openers="$(grep -cF -- "--findings - <<'FINDINGS'" "$f" || true)"
    terminators="$(grep -c '^FINDINGS$' "$f" || true)"
    [ "$openers" -eq "$terminators" ] || {
      echo "$f: $openers findings heredocs opened, $terminators closed" >&2
      return 1
    }
  done
}

@test "no findings heredoc uses an unquoted delimiter" {
  # An unquoted delimiter expands `$` and backticks inside the finding text
  # before the writer validates the array, so a finding quoting shell prose
  # publishes something other than what the member wrote.
  for f in "${SPECS[@]}"; do
    grep -qE -- "--findings - <<[^']" "$f" && return 1
  done
  true
}

# --- Group 4: the prose states the rule the command encodes ----------------
# The operative clause, not the rationale around it: a spec whose command
# drifts back to a file while this sentence stays put is the failure #1190
# names, so the sentence must be the instruction rather than its explanation.

@test "every spec states the operative staging rule" {
  for f in "${SPECS[@]}"; do
    grep -qF -- 'Stage nothing: the array goes in through the quoted heredoc above, never through a file.' "$f" || {
      echo "$f does not state the staging rule its own command encodes" >&2
      return 1
    }
  done
}

@test "no spec still offers a staged temp file as the alternative" {
  # The superseded sentence, verbatim. It presented stdin as a convenience for
  # a member that would rather not stage a file, which left the staged file
  # the default reading of the placeholder above it.
  for f in "${SPECS[@]}"; do
    grep -qF -- 'reads the array from stdin when you would rather not stage a temp file' "$f" && return 1
  done
  true
}
