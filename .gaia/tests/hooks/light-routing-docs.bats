#!/usr/bin/env bats
# Doc-grep pins for the light-routing prose the audit-loop unit executes and
# the PR Merge Workflow page describes.
#
# Prose-to-prose checks: each literal below is something an orchestrator acts
# on or a named departure a reader would otherwise infer wrongly. Every
# presence check has a red twin: a scratch copy with the literal removed must
# fail the same predicate, so the predicate is proven able to fail.
#
# GAIA_LIGHT_ROUTING_PAGE and GAIA_LIGHT_ROUTING_UNIT override the page and
# unit paths so a scratch copy can be driven through the same cases; they
# default to the real files.
#
# Assertion style: .claude/rules/bats-assertions.md.

# The pinned literals carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="${GAIA_LIGHT_ROUTING_PAGE:-$ROOT/wiki/concepts/PR Merge Workflow.md}"
  UNIT="${GAIA_LIGHT_ROUTING_UNIT:-$ROOT/.claude/agents/audit-loop-unit.md}"
  # Assembled so this file never spells the forbidden flag contiguously.
  FORBIDDEN_FLAG="--review"" light"
}

# has_literal <file> <literal>: rc 0 when the fixed string is present.
has_literal() {
  grep -qF -- "$2" "$1"
}

# scratch_without <file> <literal>: writes a copy with every line carrying the
# literal removed and prints its path.
scratch_without() {
  local scratch_copy_path="$BATS_TEST_TMPDIR/without.md"
  grep -vF -- "$2" "$1" >"$scratch_copy_path"
  printf '%s\n' "$scratch_copy_path"
}

# assert_pinned <file> <literal>: present in the real file, absent in the
# scratch copy that drops it (the red twin).
assert_pinned() {
  has_literal "$1" "$2" || { echo "missing: $2" >&2; return 1; }
  local copy
  copy="$(scratch_without "$1" "$2")"
  has_literal "$copy" "$2" && { echo "red twin did not fail: $2" >&2; return 1; }
  true
}

# light_section <file>: the page's `#### Light routing` subsection body.
light_section() {
  awk '/^#### Light routing$/ {inside_light_section=1; next} /^#{1,4} / {inside_light_section=0} inside_light_section' "$1"
}

@test "page has a Light routing subsection naming both scripts and the reviewer" {
  [ -n "$(light_section "$PAGE")" ]
  local needle
  for needle in '.gaia/scripts/audit-light-route.sh' '.gaia/scripts/audit-light-mark.sh' '`audit-light-reviewer`'; do
    grep -qF -- "$needle" <<<"$(light_section "$PAGE")" || { echo "not under Light routing: $needle" >&2; return 1; }
  done
}

@test "page names the light-clear, escalate, and Full fallback branches" {
  assert_pinned "$PAGE" '- **Light-clear branch.**'
  assert_pinned "$PAGE" '- **Escalate branch and every failure branch.**'
  assert_pinned "$PAGE" '**Full whenever it cannot establish Light**'
}

@test "page states the three named departures" {
  assert_pinned "$PAGE" '- **Ownerless Full.**'
  assert_pinned "$PAGE" '- **No re-dispatch.**'
  assert_pinned "$PAGE" '- **Main thread stays Full.**'
}

@test "page and unit never spell the light write flag" {
  grep -qF -- "$FORBIDDEN_FLAG" "$PAGE" && return 1
  grep -qF -- "$FORBIDDEN_FLAG" "$UNIT" && return 1
  # Red twin: the predicate fires on a copy that spells it.
  { cat "$PAGE"; printf 'run %s now\n' "$FORBIDDEN_FLAG"; } >"$BATS_TEST_TMPDIR/spelled-page.md"
  grep -qF -- "$FORBIDDEN_FLAG" "$BATS_TEST_TMPDIR/spelled-page.md"
  { cat "$UNIT"; printf 'run %s now\n' "$FORBIDDEN_FLAG"; } >"$BATS_TEST_TMPDIR/spelled-unit.md"
  grep -qF -- "$FORBIDDEN_FLAG" "$BATS_TEST_TMPDIR/spelled-unit.md"
}

@test "unit names the router and the light-marker script in its routing section" {
  local routing
  routing="$(awk '/^## Routing each member$/ {inside_routing_section=1; next} /^## / {inside_routing_section=0} inside_routing_section' "$UNIT")"
  [ -n "$routing" ]
  local needle
  for needle in '.gaia/scripts/audit-light-route.sh' '.gaia/scripts/audit-light-mark.sh' 'audit-member-digest.sh' '`audit-light-reviewer`'; do
    grep -qF -- "$needle" <<<"$routing" || { echo "not under Routing each member: $needle" >&2; return 1; }
  done
  assert_pinned "$UNIT" 'The light-marker script is the only light writer.'
  assert_pinned "$UNIT" 'is not re-dispatched'
  assert_pinned "$UNIT" 'every member dispatches Full.'
}

@test "unit has no instruction to write a marker other than through the light-marker script" {
  # Any line telling the unit to write or create a marker must name the
  # light-marker script or be a prohibition.
  local offending
  offending="$(grep -iE '(write|create|hand-write|mint)[^.]{0,20} (a|the|an) (earned )?(marker|clearance|verdict)' "$UNIT" \
    | grep -viE 'never|no marker|light-marker|audit-light-mark' || true)"
  [ -z "$offending" ] || { printf 'unscripted marker write: %s\n' "$offending" >&2; return 1; }
  # Red twin: an instruction to write the marker is flagged by the same filter.
  { cat "$UNIT"; printf -- '- Then write the marker for the member.\n'; } >"$BATS_TEST_TMPDIR/bad-unit.md"
  offending="$(grep -iE '(write|create|hand-write|mint)[^.]{0,20} (a|the|an) (earned )?(marker|clearance|verdict)' "$BATS_TEST_TMPDIR/bad-unit.md" \
    | grep -viE 'never|no marker|light-marker|audit-light-mark' || true)"
  [ -n "$offending" ]
}

@test "unit routing section precedes Per round and is referenced from it" {
  local routing_line per_round_line
  routing_line="$(grep -n '^## Routing each member$' "$UNIT" | cut -d: -f1)"
  per_round_line="$(grep -n '^## Per round$' "$UNIT" | cut -d: -f1)"
  [ -n "$routing_line" ]
  [ -n "$per_round_line" ]
  [ "$routing_line" -lt "$per_round_line" ]
  assert_pinned "$UNIT" 'each routed as `## Routing each member` says'
}

@test "red twin: a page copy without the escalate branch fails the pin" {
  local copy
  copy="$(scratch_without "$PAGE" '- **Escalate branch and every failure branch.**')"
  has_literal "$copy" '- **Escalate branch and every failure branch.**' && return 1
  true
}

@test "red twin: a page copy with no Light routing heading has an empty section" {
  local copy
  copy="$(scratch_without "$PAGE" '#### Light routing')"
  [ -z "$(light_section "$copy")" ]
}
