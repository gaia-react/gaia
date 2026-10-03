#!/usr/bin/env bash
# SC2016 is intentional file-wide: the awk program below is single-quoted
# precisely so every `$` and awk field reference reaches awk as literal
# program text. shellcheck's built-in awk heuristic, which exempts a literal
# single-quoted program handed to a bare `awk` command word, does not extend
# to one handed to a variable command word ("$GAIA_AWK"), so this file needs
# the directive that a bare-`awk` invocation would not have.
# shellcheck disable=SC2016
#
# lint-workflow-run-interpolation.sh: flag every `${{ ... }}` expression that
# sits inside a workflow `run:` block body. Run it directly from the repo root:
# `bash .gaia/scripts/lint-workflow-run-interpolation.sh`.
#
# Exit 0 when clean, and 1 either with a file:line report on any hit or on a
# scan surface that came back empty. Four statuses say the gate never ran at
# all: 2 when guard-awk-lib.sh is missing beside this script, 3 when the
# scan-surface discovery failed, 5 when no awk interpreter is present at all,
# and 6 when GAIA_AWK resolves to an interpreter that identifies as neither
# mawk nor BWK one-true-awk.
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
# sibling path-quoting guard which skips them. A `#` does not neutralize this
# class: substitution happens before bash parses, so a value containing a
# newline ends the comment and the remainder of the value begins a new command.
#
# Scan surface: `.github/workflows/` and the composite actions under
# `.github/actions/`. A composite action's `run:` steps are the same
# shell-by-another-name as a workflow's and carry the identical hazard, and the
# workflows here invoke them, so scanning the callers but not the callees would
# leave the class enforced only up to the first `uses:` hop. Every composite
# action in this tree is at zero today, so that half is coverage held rather
# than instances repaired.
#
# Sibling gate: .gaia/scripts/lint-git-path-quoting.sh, which scans the same
# workflow YAML for a different class. The two are kept separate because their
# scan surfaces differ (that one also reads *.sh, .githooks/*, and the fenced
# blocks of tracked markdown) and their discriminations share nothing.

set -euo pipefail

# Script-relative, never cwd-relative: every fixture test runs this guard with
# cwd inside a throwaway repo that carries no .gaia/scripts/. Bracketed with
# set +e/-e because this file arms errexit itself, and an unbracketed load
# would abort the script outright if the library were ever present but
# unparseable. This gate reads none of the library's awk, only its
# scan-surface discovery.
_gaia_guard_library_directory="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_library_directory" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_library_directory="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_library_directory/guard-awk-lib.sh" ] && . "$_gaia_guard_library_directory/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_scan_files >/dev/null 2>&1 || {
  printf 'lint-workflow-run-interpolation: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    printf 'lint-workflow-run-interpolation: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present\n' >&2
    exit 5
    ;;
  6)
    printf 'lint-workflow-run-interpolation: GAIA_AWK resolved to an unsanctioned interpreter (%s); the sanctioned set is mawk and BWK one-true-awk\n' "$GAIA_AWK_IDENTITY" >&2
    exit 6
    ;;
esac

# The scan surface comes from the shared library rather than from a read loop
# here, so every gate consuming it discovers the same set the same way and a
# widened pathspec cannot reach one of them and miss the others. The call fills
# GAIA_GUARD_SCAN_FILES and returns non-zero on an empty surface, which is a
# hard error rather than a clean tree; the status is read directly, because a
# substitution would swallow it.
#
gaia_guard_scan_files lint-workflow-run-interpolation workflows || exit $?

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
# Neither appears in this repository, and `actionlint` plus review
# cover the authoring of new steps; the block form is what every step here uses.
scan_file() {
  local file_path="$1"
  "$GAIA_AWK" -v file="$file_path" '
    function report(line_number) {
      printf "%s:%d: ${{ }} expression inside a run: body; bind it through an env: block and reference \"$VAR\" instead\n", file, line_number
    }
    {
      if (inside_run_body) {
        # A blank line belongs to the block scalar rather than ending it.
        if ($0 ~ /^[[:space:]]*$/) next
        column = match($0, /[^ ]/)
        if (column > run_column) {
          if (index($0, "${{") > 0) report(FNR)
          next
        }
        inside_run_body = 0
        # Fall through: this same line may itself be the next `run:` key.
      }
      if ($0 ~ /^[[:space:]]*(-[[:space:]]+)?run:/) {
        run_column = index($0, "run:")
        value = substr($0, run_column + 4)
        # `|`, `|-`, `>`, `>+`, `|2`, `|2-` and friends: a block scalar header
        # carries nothing but the indicator and an optional comment, so anything
        # else on the line is inline content.
        #
        # Two details this pattern is deliberately loose about, both because
        # tightening either buys a false negative and neither can produce a false
        # positive on real YAML:
        #   - `[-+0-9]*` accepts the chomping and indentation indicators in
        #     EITHER order, because YAML permits both (`|2-` and `|-2`). Spelling
        #     it `[-+]?[0-9]*` matches only one order and sends the other down
        #     the inline arm, which skips the whole body.
        #   - `(#.*)?` accepts a trailing comment. `run: | # note` is legal YAML
        #     that Actions accepts and whose body parses normally; without this,
        #     the header falls to the inline arm and every line of the body goes
        #     unscanned.
        # An expression inside that trailing comment is not scanned, and that is
        # correct rather than a gap: the comment is part of the header line, not
        # of the block scalar, so it never reaches the script text Actions
        # substitutes into.
        if (value ~ /^[[:space:]]*[|>][-+0-9]*[[:space:]]*(#.*)?$/) {
          inside_run_body = 1
        } else {
          inside_run_body = 0
          if (index($0, "${{") > 0) report(FNR)
        }
      }
    }
  ' "$file_path"
}

report=""
for file_path in ${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"}; do
  [ -f "$file_path" ] || continue
  hits=$(scan_file "$file_path")
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
