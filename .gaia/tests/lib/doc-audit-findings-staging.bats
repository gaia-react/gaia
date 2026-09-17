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
# The fix is a staging directory no sibling can share, written fresh in the
# call before the writer. `audit-scratch-dir.sh <member> <KEY_BASE>` mints a
# directory keyed to the audit key AND the member name, so co-dispatched members
# never pick the same file. A name derived from the audit key alone closes
# neither case, because the key is a base sha plus a branch slug over a shared
# base every co-dispatched member resolves alike, and that base advances only
# when a clean round stamps its trailer, so the re-dispatch after a withheld
# round recomputes the key it just used. Writing the file fresh with `printf`
# immediately before the writer is what keeps an earlier round's file from
# republishing.
#
# The stage is a `printf` redirect, and the writer a separate command, rather
# than a pipe, a heredoc, or the `Write` tool, because worktree isolation
# refuses each of those: a pipe feeding a program text that carries the token
# `git` (any finding path under `.github/` does), a heredoc outright (`this
# command is too complex to verify that it stays inside the worktree`), and
# `Write` into the scratch directory, which resolves into the main checkout
# through the `.gaia/local` symlink. On a pull request audited from a linked
# worktree each of those is unrunnable, and each member improvises a spelling of
# its own -- the drift the single-writer design exists to prevent.
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

# --- Group 2: the prescribed call reads a member-private staged file ----------

@test "every findings invocation in every spec reads the member-private staged file" {
  # One rule, stated once: the flag appears only in the pinned form. Every line
  # mentioning `--findings` must be `--findings <scratch>/findings.json` and
  # nothing else, so stdin (`--findings -`), a fixed session-scratchpad path
  # (`--findings /tmp/x.json`), a revived heredoc, and prose that hands the
  # writer some other path all fail the same way, without a second check
  # enumerating argument shapes. Anchored end to end, so a line carrying the
  # pinned form and then more (a redirect, a heredoc opener) fails too.
  #
  # The offenders check runs FIRST so a drifted spec is reported by its
  # offending line rather than as "prescribes no sidecar write at all".
  for f in "${SPECS[@]}"; do
    local offenders
    offenders="$(grep -n -- '--findings' "$f" | grep -vE -- '^[0-9]+:[[:space:]]*--findings <scratch>/findings\.json[[:space:]]*$' || true)"
    [ -z "$offenders" ] || {
      echo "$f: --findings appears outside the pinned staged-file form: $offenders" >&2
      return 1
    }
    grep -qE -- '^[[:space:]]*--findings <scratch>/findings\.json[[:space:]]*$' "$f" || {
      echo "$f carries no --findings line of any shape, so it prescribes no sidecar write at all" >&2
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

# --- Group 3: the producer that stages the file, paired with its writer ---------

@test "every staged producer is immediately followed by its writer call" {
  # Group 2 pins the flag. This pins the producer and ties each one to a writer.
  #
  # Counts alone balance cardinalities and associate nothing: a spec could stage
  # the array in one place and call the writer somewhere unrelated, so the
  # member runs the writer against whatever file an earlier call left, which
  # is the stale republish this suite exists to forbid. So each producer must be
  # followed, fence to fence, by the literal-root writer call: its own fence
  # closes, one blank line, the next fence opens on the writer. The writer is
  # anchored at `<root>` for the reason audit-root-resolution.bats stage 8b
  # gives: an unanchored spelling runs the session cwd's copy of the writer.
  #
  # The totals are checked too, so a writer call with no producer ahead of it
  # (reading a file nothing in the spec stages) fails as well.
  for f in "${SPECS[@]}"; do
    local producers writers consumers unpaired
    producers="$(grep -cE -- "^printf '%s' '.*' > <scratch>/findings\\.json$" "$f" || true)"
    writers="$(grep -cE -- '^bash <root>/\.gaia/scripts/audit-write-findings\.sh \\$' "$f" || true)"
    consumers="$(grep -cE -- '^[[:space:]]*--findings <scratch>/findings\.json[[:space:]]*$' "$f" || true)"
    [ "$producers" -gt 0 ] || { echo "$f: no staged printf producer" >&2; return 1; }
    [ "$producers" -eq "$writers" ] || { echo "$f: $producers producers, $writers writer calls" >&2; return 1; }
    [ "$writers" -eq "$consumers" ] || { echo "$f: $writers writer calls, $consumers staged-file consumers" >&2; return 1; }
    unpaired="$(awk '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (line[i] ~ /^printf .%s. .*> <scratch>\/findings\.json$/) {
            if (!(line[i+1] == "```" && line[i+2] == "" && line[i+3] == "```bash" && line[i+4] ~ /^bash <root>\/\.gaia\/scripts\/audit-write-findings\.sh \\$/)) print i
          }
        }
      }' "$f")"
    [ -z "$unpaired" ] || {
      echo "$f: producer(s) at line(s) $unpaired are not immediately followed by the writer call" >&2
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

@test "no spec pipes the payload into the writer, which the isolation guard refuses" {
  # A pipe into the writer is the superseded stdin form. The confinement
  # refuses it whenever the payload carries the token `git`, which any finding
  # path under `.github/` does, so it is unrunnable from a linked worktree.
  for f in "${SPECS[@]}"; do
    grep -qE -- '\|[[:space:]]*bash[[:space:]].*audit-write-findings\.sh' "$f" && return 1
  done
  true
}

@test "no spec has revived the heredoc the isolation guard refuses" {
  # Subsumed by Group 2's anchored rule for the flag line, and extended to the
  # producer, so a revival reads as the regression it is: a heredoc form cannot
  # run at all on a pull request audited from a linked worktree.
  for f in "${SPECS[@]}"; do
    grep -qF -- '--findings - <<' "$f" && return 1
    grep -qE -- "^printf '%s'.*<<" "$f" && return 1
  done
  true
}

# --- Group 4: the prose states the rule the command encodes ----------------
# The operative clause, not the rationale around it: a spec whose command
# drifts while this sentence stays put is the failure #1190 names, so the
# sentence must be the instruction rather than its explanation.

@test "every spec states the operative staging rule" {
  for f in "${SPECS[@]}"; do
    grep -qF -- '**Stage the array in your own scratch directory, as a file written fresh with `printf` in the call immediately before the writer.**' "$f" || {
      echo "$f does not state the staging rule its own command encodes" >&2
      return 1
    }
    grep -qF -- 'and a heredoc is refused outright' "$f" || {
      echo "$f no longer states that the heredoc form is refused" >&2
      return 1
    }
  done
}

@test "no spec still states the superseded stdin staging rule" {
  for f in "${SPECS[@]}"; do
    grep -qF -- 'Stage nothing: the array goes in through the single-quoted `printf` payload above, never through a file.' "$f" && return 1
  done
  true
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
