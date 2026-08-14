#!/usr/bin/env bash
# lint-workflow-run-interpolation.sh: flag every `${{ ... }}` expression that
# sits inside a workflow `run:` block body. Exit 1 with a file:line report on
# any hit, exit 0 when clean. Run it directly from the repo root:
# `bash .gaia/scripts/lint-workflow-run-interpolation.sh`.
# gaia:maintainer-only:start
#
# Enforced by the sibling bats suite
# .gaia/scripts/tests/lint-workflow-run-interpolation.bats, which the `Audit CI
# Tests` CI job runs, and folded into .gaia/tests/shell-lint.sh so every
# shell-lint caller enforces the class. Also runnable directly:
# `bats .gaia/scripts/tests/lint-workflow-run-interpolation.bats`.
# gaia:maintainer-only:end
#
# Why: GitHub Actions substitutes `${{ }}` into the `run:` script TEXT before
# bash parses it. A value carrying a quote, a backtick, a `$(`, or a newline is
# therefore parsed as shell SYNTAX rather than passed as data. The `env:` form
# has no such hazard -- the runner sets the variable in the process environment
# and bash only ever sees the variable reference:
#
#     env:
#       PARSED_FILE: ${{ steps.parse.outputs.parsed_file }}
#     run: |
#       handler.sh "$PARSED_FILE"
#
# The class is why this is a gate rather than a review habit. The safety of an
# expansion here rests on an invariant about its PRODUCER -- that every present
# and future writer of that output keeps its value free of shell metacharacters
# -- and nothing enforces that invariant at the producer. A gate at the consumer
# is the only place the guarantee can be made structural, because the consumer
# is the only place the hazard is visible in the text.
#
# Deliberately NOT adjudicated: whether a given expression's producer happens to
# be trustworthy. `${{ github.event_name }}` is a closed enum and `${{
# steps.x.outputs.y }}` is arbitrary, but the gate demands `env:` for both. That
# is the whole point -- an exemption list for "safe" producers reintroduces the
# case-by-case judgment whose absence of enforcement is the defect, and it would
# have to be re-litigated on every context GitHub adds. Uniform is checkable;
# selective is not. The repair is always the same two lines and never wrong.
#
# Comment lines inside a `run:` body are scanned rather than skipped, unlike the
# sibling diff-quoting guard which skips them. A `#` does not neutralize this
# class: substitution happens before bash parses, so a value containing a
# newline ends the comment and the remainder of the value begins a new command.
#
# Scan surface: `.github/workflows/` only. The adopter workflow TEMPLATES under
# .gaia/cli/src/automation/templates/workflows/ carry instances of this same
# textual class and are deliberately OUT of this gate's declared surface, not
# merely unreached by it: they are a separate distribution surface that
# regenerates through `bundle:adopter`, their expressions are GitHub-controlled
# context values rather than step outputs, and they are tracked as their own
# tech-debt item. The distinction that matters is that this gate's declared
# surface is at zero and stays at zero; it does not claim the templates and then
# leave live instances in them unreached.
#
# Sibling gate: .gaia/scripts/lint-diff-name-only-quoting.sh, which scans the
# same workflow YAML for a different class. The two are kept separate because
# their scan surfaces differ (that one also reads *.sh and .husky/*) and their
# discriminations share nothing.

set -euo pipefail

# `git ls-files` rather than a filesystem walk, so an untracked scratch workflow
# is never scanned; the same discovery .gaia/tests/shell-lint.sh uses. Collected
# with a read loop rather than `mapfile`, which is bash 4+, because these
# scripts run on stock macOS /bin/bash (3.2.57).
scan_files=()
while IFS= read -r f; do
  scan_files+=("$f")
done < <(git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml' | LC_ALL=C sort)

# An empty scan set is a hard error, never a clean tree. The loop above reads
# from a process substitution, whose failure `set -o pipefail` cannot see, so a
# `git ls-files` that errors (run outside a repository, a broken object store)
# leaves the array empty and every check below vacuously passes. This gate would
# then print `clean` and exit 0 having scanned nothing, which is the lie-green
# failure gates exist to stop. Every real tree carries tracked workflows, so an
# empty result means the discovery is wrong rather than the tree.
if [ "${#scan_files[@]}" -eq 0 ]; then
  echo "lint-workflow-run-interpolation: ERROR: no tracked workflows matched the scan surface; nothing was scanned" >&2
  exit 1
fi

# scan_file <path>: print one `file:line: message` per expression in a run body.
#
# The `run:` body is located structurally rather than by regex over the whole
# file, because `${{ }}` is legal and correct everywhere ELSE in a workflow --
# in `env:`, `with:`, `if:`, `name:` -- and a file-wide grep would flag the very
# form this gate tells you to adopt.
#
# Two shapes, per YAML:
#   block scalar  `run: |`   -- body is the following lines indented deeper
#                               than the `run` key. Blank lines stay in the body.
#   inline        `run: cmd` -- the value is on the key's own line.
#
# Known blind spots, stated rather than discovered later. Both are FALSE
# NEGATIVES bounded by how rare the shape is in real workflows:
#   - A multi-line PLAIN (unquoted, no `|`/`>`) scalar continuing onto following
#     lines is read as inline, so only its first line is scanned.
#   - A `run:` written as a quoted flow scalar spanning lines is likewise read
#     as inline.
# Neither shape appears in this repository, and `actionlint` plus review cover
# the authoring of new steps; the block form is what every step here uses.
scan_file() {
  local f="$1"
  awk -v file="$f" '
    function report(n) {
      printf "%s:%d: ${{ }} expression inside a run: body; bind it through an env: block and reference \"$VAR\" instead\n", file, n
    }
    {
      if (inrun) {
        # A blank line belongs to the block scalar rather than ending it.
        if ($0 ~ /^[[:space:]]*$/) next
        col = match($0, /[^ ]/)
        if (col > runcol) {
          if (index($0, "${{") > 0) report(FNR)
          next
        }
        inrun = 0
        # Fall through: this same line may itself be the next `run:` key.
      }
      if ($0 ~ /^[[:space:]]*(-[[:space:]]+)?run:/) {
        runcol = index($0, "run:")
        value = substr($0, runcol + 4)
        # `|`, `|-`, `>`, `>+`, `|2` and friends: a block scalar header carries
        # nothing but the indicator, so anything else on the line is inline
        # content.
        if (value ~ /^[[:space:]]*[|>][-+]?[0-9]*[[:space:]]*$/) {
          inrun = 1
        } else {
          inrun = 0
          if (index($0, "${{") > 0) report(FNR)
        }
      }
    }
  ' "$f"
}

report=""
for f in ${scan_files[@]+"${scan_files[@]}"}; do
  [ -f "$f" ] || continue
  hits=$(scan_file "$f")
  [ -z "$hits" ] || report+="$hits"$'\n'
done

if [ -n "$report" ]; then
  printf '%s' "$report"
  # printf, not echo: the hint carries `$` and `{` that echo may treat
  # inconsistently across shells. The format string is single-quoted so the
  # sample code inside stays literal -- it is being printed, not run.
  # shellcheck disable=SC2016
  printf 'Fix each by binding the expression on the step:\n    env:\n      MY_VAR: ${{ steps.x.outputs.y }}\n    run: |\n      cmd "$MY_VAR"\n' >&2
  exit 1
fi

echo "lint-workflow-run-interpolation: clean" >&2
exit 0
