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
# sibling path-quoting guard which skips them. A `#` does not neutralize this
# class: substitution happens before bash parses, so a value containing a
# newline ends the comment and the remainder of the value begins a new command.
#
# Scan surface: `.github/workflows/`, the composite actions under
# `.github/actions/*/action.yml`, and the adopter workflow templates under
# .gaia/cli/src/automation/templates/workflows/ (including its `partials/`). A
# composite action's `run:` steps are the same shell-by-another-name as a
# workflow's and carry the identical hazard, and the workflows here invoke them,
# so scanning the callers but not the callees would leave the class enforced
# only up to the first `uses:` hop. Every composite action in this tree is at
# zero today, so that half is coverage held rather than instances repaired.
#
# The templates render into an ADOPTER's own CI, so the invariant an
# un-indirected expression rests on is inherited by every adopter clone and by
# every future edit to a template, where neither this repo's review nor the
# adopter's can see it. That is the same reason the class is a gate rather than
# a review habit, applied one distribution hop further out. The expressions
# there are GitHub-controlled context values rather than step outputs, which is
# a weaker risk profile, and it is deliberately not adjudicated here for the
# same reason the producer of any other expression is not: an exemption list for
# "safe" producers reintroduces the case-by-case judgment whose absence of
# enforcement is the defect.
#
# Three properties of the template surface the scan depends on:
#   - `.tmpl`, not `.yml`, hence the separate globs below.
#   - A `partials/` file is a FRAGMENT that is not parseable as a standalone
#     workflow: its indentation context is supplied by whatever includes it, and
#     it may open mid-step. The `run:`-body locator holds anyway because it is
#     purely relative -- it compares each body line's indentation against the
#     column of the `run:` key it just read, never against an absolute depth or
#     a document structure -- so a fragment scans exactly as a whole file does.
#   - The mustache placeholders (`{{tool_id}}`) that appear inside these bodies
#     are NOT confusable with an Actions expression: the detector matches the
#     literal `${{`, and a mustache tag carries no `$`.
#   - A SECTION tag (`{{#x}}`, `{{^x}}`, `{{/x}}`) fences part of a body from
#     column 0, which read by indentation alone is a dedent out of the block.
#     That shape does not occur in a real workflow, so it arrives with this
#     surface rather than pre-existing it, and left unhandled it would end the
#     scan early and leave the rest of the body unread while the gate still
#     printed clean. The in-body test below treats a section tag as
#     continuation for that reason; see the comment there for why an include is
#     deliberately excluded from the same treatment.
#
# `.gaia/cli/templates/workflows/` is a build artifact copied from `src/` by
# `bundle:adopter` and is deliberately NOT scanned. Scanning both would report
# every hit twice, and scanning the artifact alone would name a file the repair
# must not hand-edit. Artifact-equals-source is held by
# `audit-template-dogfood.test.ts` and `verify-cli-bundle-fresh.sh`, so a repair
# to the source that never regenerates fails there rather than here.
#
# Sibling gate: .gaia/scripts/lint-git-path-quoting.sh, which scans the same
# workflow YAML for a different class. The two are kept separate because their
# scan surfaces differ (that one also reads *.sh, .husky/*, and the fenced
# blocks of tracked markdown) and their discriminations share nothing.

set -euo pipefail

# Script-relative, never cwd-relative: every fixture test runs this guard with
# cwd inside a throwaway repo that carries no .gaia/scripts/. Bracketed with
# set +e/-e because this file arms errexit itself, the shape
# .gaia/scripts/lint-errexit-source-guard.sh demands for an unbracketed load in
# an errexit-reachable file. This gate reads none of the library's awk, only its
# scan-surface discovery.
_gaia_guard_lib_dir="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_lib_dir" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_lib_dir="."; fi
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
set +e; [ -f "$_gaia_guard_lib_dir/guard-awk-lib.sh" ] && . "$_gaia_guard_lib_dir/guard-awk-lib.sh" 2>/dev/null; set -e
type gaia_guard_scan_files >/dev/null 2>&1 || {
  printf 'lint-workflow-run-interpolation: guard-awk-lib.sh is missing beside this script\n' >&2
  exit 2
}

# The scan surface comes from the shared library rather than from a read loop
# here, so every gate consuming it discovers the same set the same way and a
# widened pathspec cannot reach one of them and miss the others. The call fills
# GAIA_GUARD_SCAN_FILES and returns non-zero on an empty surface, which is a
# hard error rather than a clean tree; the status is read directly, because a
# substitution would swallow it.
#
# A git pathspec glob is matched without FNM_PATHNAME, so its `*` crosses `/`.
# The library's one templates glob therefore reaches `partials/` and any
# directory added under it later, which is why it needs no second glob for the
# fragments this gate reads.
gaia_guard_scan_files lint-workflow-run-interpolation workflows || exit 1

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
# Known blind spots, stated rather than discovered later. All three are FALSE
# NEGATIVES bounded by how rare the shape is in real workflows:
#   - A multi-line PLAIN (unquoted, no `|`/`>`) scalar continuing onto following
#     lines is read as inline, so only its first line is scanned.
#   - A `run:` written as a quoted flow scalar spanning lines is likewise read
#     as inline.
#   - A partial include sitting INSIDE a `run:` body ends the scan there, per
#     the exclusion below, so the rest of that body goes unread. The resolver
#     replaces the include token with the partial's bytes verbatim and applies
#     no indentation of its own, so a column-0 include splices the fragment's
#     authored, deeper indentation straight back into the same rendered block
#     scalar. Scanning the partial's own file does not recover those lines: a
#     fragment holding only body lines carries no `run:` key, so read
#     standalone it has no block for them to be inside. Every include in this
#     tree sits at step or document level rather than inside a body, which is
#     what bounds this.
# None of the three appears in this repository, and `actionlint` plus review
# cover the authoring of new steps; the block form is what every step here uses.
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
        # A SECTION tag (`{{#x}}`, `{{^x}}`, `{{/x}}`) is written at column 0 in
        # these templates. The renderer replaces a `{{#x}}`...`{{/x}}` pair with
        # the text between the tags, consuming the tag text but not the newline
        # that ended its line, so each tag renders as a BLANK line rather than
        # vanishing, and a blank line belongs to the block scalar rather than
        # ending it. In the template, though, the tag is a line at column 1,
        # which read by column alone is a dedent that would end the block and
        # leave every remaining body line unscanned while the gate still printed
        # clean. Treat it as continuation, and scan the line itself, since a tag
        # may carry body content after it on the same line.
        #
        # The partial-include form `{{> x }}` is deliberately NOT continuation.
        # An include splices a whole document region rather than fencing lines
        # of this body, so latching across one would carry `inrun` into the
        # `matrix:` and `env:` mappings that follow an include in these
        # templates and false-flag the very `env:` form this gate prescribes.
        # An include therefore falls through to the column test below and ends
        # the block, which is what it does today.
        #
        # A bare `{{x}}` interpolation at column 0 is likewise not continuation:
        # it renders to text at column 0, which would terminate the block scalar
        # in the rendered YAML too, so treating it as a dedent matches what
        # Actions would see.
        tag = $0
        sub(/^[[:space:]]+/, "", tag)
        if (substr(tag, 1, 2) == "{{") {
          c = substr(tag, 3, 1)
          if (c == "#" || c == "^" || c == "/") {
            if (index($0, "${{") > 0) report(FNR)
            next
          }
        }
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
for f in ${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"}; do
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
