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
# closes neither case, because the key is a base sha plus a branch slug over a
# shared base every co-dispatched member resolves alike, and that base advances
# only when a clean round stamps its trailer, so the re-dispatch after a
# withheld round recomputes the key it just used. Reading the
# array from stdin removes the staging file, so there is no name to collide on
# and nothing to leave behind.
#
# The array reaches stdin through a single-quoted `printf` payload rather than
# through a heredoc. Worktree isolation refuses a heredoc outright (`this
# command is too complex to verify that it stays inside the worktree`), so on
# any pull request audited from a linked worktree a heredoc form is unrunnable
# and each member improvises a spelling of its own -- the drift the
# single-writer design exists to prevent, arriving by a second route.
#
# The single quotes around the payload are load-bearing rather than stylistic:
# finding text carries `$` tokens and backticks routinely (this suite's own
# subject matter is shell prose), and a double-quoted payload expands them
# before the writer ever validates the array.
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
# Assertion style: .claude/rules/bats-assertions.md.

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
  # One rule, stated once: the flag appears only in the pinned form. Every line
  # mentioning `--findings` must be `--findings -` and nothing else, so a
  # staged path (`--findings /tmp/x.json`), a redirect (`--findings - < x`), a
  # revived heredoc (`--findings - <<'FINDINGS'`), and prose that hands the
  # writer a path all fail the same way, without a second check enumerating
  # argument shapes.
  #
  # The pattern is anchored end-to-end rather than matched as a substring,
  # which is what makes the redirect and the heredoc fail here: both carry
  # `--findings -` and then keep going, so an unanchored needle would accept
  # them. Group 3 pins the producer on the other side of the pipe; this rule
  # owns the flag alone.
  #
  # Matching line by line rather than balancing two counts is the other half:
  # counts invite two scopes, and an anchored total compared against an
  # unanchored one is satisfiable from prose, so a spec carrying one staged
  # invocation and one prose copy of the pinned literal balances and passes.
  # This has no arithmetic to get backwards and names the offending line.
  for f in "${SPECS[@]}"; do
    local offenders
    grep -qE -- '^[[:space:]]*--findings -[[:space:]]*$' "$f" || {
      echo "$f prescribes no sidecar write at all" >&2
      return 1
    }
    offenders="$(grep -n -- '--findings' "$f" | grep -vE -- '^[0-9]+:[[:space:]]*--findings -[[:space:]]*$' || true)"
    [ -z "$offenders" ] || {
      echo "$f: --findings appears outside the pinned stdin form: $offenders" >&2
      return 1
    }
  done
}

@test "no spec still prescribes the shared staging filename" {
  # The original defect, verbatim. Every member handed this same placeholder,
  # which is what made one filename the filename all of them picked. Subsumed
  # by the rule above and kept anyway: it names the defect this suite exists
  # for, so a failure reads as the regression it is rather than as generic
  # drift.
  for f in "${SPECS[@]}"; do
    grep -qF -- '--findings /path/to/findings.json' "$f" && return 1
  done
  true
}

# --- Group 3: the stdin producer on the other side of the pipe --------------

@test "every findings invocation has a single-quoted printf producer" {
  # Group 2 pins the flag; without this, `--findings -` could sit at the end of
  # a call nothing feeds, and the writer would block on a stdin that never
  # arrives. Counting producers against consumers is what ties the two halves
  # of each pipeline together.
  #
  # Both counts are anchored, and to the same scope: a spec sentence quoting
  # either half inline would otherwise inflate one side with nothing on the
  # other to match it and fail a spec whose invocations are all well-formed.
  for f in "${SPECS[@]}"; do
    local producers consumers
    producers="$(grep -cE -- "^printf '%s' '.*' \\\\$" "$f" || true)"
    consumers="$(grep -cE -- '^[[:space:]]*--findings -[[:space:]]*$' "$f" || true)"
    [ "$producers" -eq "$consumers" ] || {
      echo "$f: $producers printf producers, $consumers --findings - consumers" >&2
      return 1
    }
  done
}

@test "no findings payload is double-quoted" {
  # A double-quoted payload expands `$` and backticks inside the finding text
  # before the writer validates the array, so a finding quoting shell prose
  # publishes something other than what the member wrote.
  for f in "${SPECS[@]}"; do
    grep -qE -- "^printf '%s' \"" "$f" && return 1
  done
  true
}

@test "no spec has revived the heredoc the isolation guard refuses" {
  # The construct this suite's pinned form exists to avoid. It is subsumed by
  # Group 2's anchored rule and kept anyway, so a revival reads as the
  # regression it is rather than as a generic flag-shape failure: a heredoc
  # form cannot run at all on a pull request audited from a linked worktree.
  for f in "${SPECS[@]}"; do
    grep -qF -- '--findings - <<' "$f" && return 1
  done
  true
}

# --- Group 4: the prose states the rule the command encodes ----------------
# The operative clause, not the rationale around it: a spec whose command
# drifts back to a file while this sentence stays put is the failure #1190
# names, so the sentence must be the instruction rather than its explanation.

@test "every spec states the operative staging rule" {
  for f in "${SPECS[@]}"; do
    grep -qF -- 'Stage nothing: the array goes in through the single-quoted `printf` payload above, never through a file.' "$f" || {
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
