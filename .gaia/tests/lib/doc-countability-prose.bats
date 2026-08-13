#!/usr/bin/env bats
# UAT-010 (SPEC-051): doc-grep coverage for the countable-findings prose
# rewrite. The Code Audit Team's five member sidecar contracts, plus
# wiki/concepts/Policy-Memory Loop.md, used to say a classless finding is
# omitted / not a countable finding / ineligible below warning. That is now
# false: a finding carrying a valid finding_class counts at any severity, and
# a genuine no-map is stamped `holistic/unclassified` and included, routed to
# the tally's distinct unclassified signal instead of being dropped.
#
# This suite asserts two things per changed prose surface: the specific false
# sentences are gone (not merely surrounded), and the new present-tense
# contract is stated. Grep targets are ground-truthed against the actual
# source text (backticks, arrows, and markdown emphasis break a naive
# paraphrase), verified by hand against this tree before being written below.
#
# Parallel-execution note: the code-comment assertions against
# compute-tally.ts, tally.ts, and finding-class.ts target files a sibling
# task (task-tally-core) sweeps in the same parallel phase. Run standalone,
# those two tests may fail while that sweep is still in flight; the
# authoritative pass is the orchestrator's post-phase gate once both
# sub-agents have landed. Every other test in this file is this task's own
# surface and must pass standalone.

# assert_absent_across <ERE pattern> <file...>
# Fails the calling test if <pattern> (extended regex, case-insensitive)
# matches any listed file.
assert_absent_across() {
  local pattern="$1"
  shift
  local f
  for f in "$@"; do
    grep -Eiq -- "$pattern" "$f" && {
      echo "stale phrase /${pattern}/ survives in ${f}" >&2
      return 1
    }
  done
  return 0
}

# assert_absent_fixed_across <fixed string> <file...>
# Same as above, but a literal substring match (no regex metacharacters),
# used where the surrounding markdown (backticks, word-boundary punctuation)
# makes a regex-based check fragile across grep flavors.
assert_absent_fixed_across() {
  local needle="$1"
  shift
  local f
  for f in "$@"; do
    grep -Fiq -- "$needle" "$f" && {
      echo "stale phrase '${needle}' survives in ${f}" >&2
      return 1
    }
  done
  return 0
}

# extract_section <file> — prints the "## Findings sidecar" section body
# (from that heading up to, excluding, the next "## " heading).
extract_section() {
  awk '
    /^## Findings sidecar/ {found=1; print; next}
    found && /^## / {exit}
    found {print}
  ' "$1"
}

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  AGENT_FILES=(
    "$ROOT/.claude/agents/code-audit-frontend.md"
    "$ROOT/.claude/agents/code-audit-github-workflows.md"
    "$ROOT/.claude/agents/code-audit-maintainer-node.md"
    "$ROOT/.claude/agents/code-audit-maintainer-shell.md"
    "$ROOT/.claude/agents/code-audit-maintainer-prose.md"
  )
  WIKI_PAGE="$ROOT/wiki/concepts/Policy-Memory Loop.md"
  TALLY_CORE="$ROOT/.gaia/cli/src/harden/compute-tally.ts"
  TALLY_EMIT="$ROOT/.gaia/cli/src/harden/tally.ts"
  FINDING_CLASS="$ROOT/.gaia/cli/src/schemas/finding-class.ts"
}

# --- AC#1: deleted false sentences -----------------------------------------

@test "UAT-010: agent files and wiki page delete the 'not a countable finding' claim" {
  assert_absent_across "is not .*a countable finding" "${AGENT_FILES[@]}" "$WIKI_PAGE"
}

@test "UAT-010: agent files and wiki page delete the classless 'omitted from findings[]' clause" {
  # `.?` (not a literal backtick) tolerates the inline-code backticks the real
  # text wraps `findings[]` in; a literal-backtick pattern would miss it.
  assert_absent_across "omitted from .?findings.?" "${AGENT_FILES[@]}" "$WIKI_PAGE"
}

@test "UAT-010: agent files and wiki page delete the classless 'omit it' instruction" {
  assert_absent_fixed_across "omit it" "${AGENT_FILES[@]}" "$WIKI_PAGE"
}

@test "UAT-010: code-audit-frontend.md deletes the 'dropped before it reaches the tally' claim" {
  assert_absent_fixed_across "dropped before it reaches the tally" "$ROOT/.claude/agents/code-audit-frontend.md"
}

@test "UAT-010: wiki page deletes 'is ineligible' and 'warning-floor'" {
  assert_absent_fixed_across "is ineligible" "$WIKI_PAGE"
  assert_absent_fixed_across "warning-floor" "$WIKI_PAGE"
}

@test "UAT-010: code-audit-maintainer-prose.md deletes the Suggestion '(not counted)' fragment" {
  assert_absent_fixed_across "(not counted)" "$ROOT/.claude/agents/code-audit-maintainer-prose.md"
}

@test "UAT-010: compute-tally.ts and tally.ts drop the severity-gating comment phrasing" {
  # Parallel-execution note (see file header): owned by task-tally-core; may
  # still fail here if that sibling task has not yet landed its sweep.
  assert_absent_fixed_across "never qualify" "$TALLY_CORE" "$TALLY_EMIT"
  assert_absent_fixed_across "dropped before counting" "$TALLY_CORE" "$TALLY_EMIT"
  assert_absent_fixed_across "at countable severity" "$TALLY_CORE" "$TALLY_EMIT"
  assert_absent_fixed_across "error/warning severity" "$TALLY_CORE" "$TALLY_EMIT"
}

@test "UAT-010: finding-class.ts drops the stale 'never reaches the tally, that is the only thing it means' claim" {
  # Parallel-execution note (see file header): owned by task-tally-core; may
  # still fail here if that sibling task has not yet landed its sweep.
  #
  # Deliberately NOT a bare "never reaches the tally" check: the file's
  # top-of-file docstring makes a separate, still-true claim ("free-text
  # drift never reaches the tally") that is frozen, byte-intact prose outside
  # the one permitted edit (the OUT_OF_SCOPE_FALLBACK_FINDING_CLASS
  # docstring). A bare check on that phrase would never pass even after a
  # correct sweep. "the only thing it means" is the distinctive fragment of
  # the actual stale sentence and doesn't collide with the frozen claim.
  assert_absent_fixed_across "the only thing it means" "$FINDING_CLASS"
}

# --- AC#2: new present-tense phrasing present -------------------------------

@test "UAT-010: wiki page states a classless finding is stamped holistic/unclassified" {
  grep -Fq "holistic/unclassified" "$WIKI_PAGE"
}

@test "UAT-010: wiki page states a valid-class finding counts at any severity" {
  grep -Fq "at any severity" "$WIKI_PAGE"
}

# --- AC#3: no working-doc refs in the changed wiki prose --------------------

@test "UAT-010: wiki page carries no UAT/SPEC/PR/date working-doc references" {
  assert_absent_across "UAT-[0-9]" "$WIKI_PAGE"
  assert_absent_across "SPEC-[0-9]" "$WIKI_PAGE"
  assert_absent_across "PR #[0-9]" "$WIKI_PAGE"
  assert_absent_across "as of [0-9]{4}" "$WIKI_PAGE"
}

# --- AC#4: every agent file's Findings sidecar section names the stamp -----

@test "UAT-010: each agent file's Findings sidecar section names holistic/unclassified as the stamped key" {
  local f section
  for f in "${AGENT_FILES[@]}"; do
    section="$(extract_section "$f")"
    [ -n "$section" ] || {
      echo "no '## Findings sidecar' section found in $f" >&2
      return 1
    }
    printf '%s' "$section" | grep -Fq "holistic/unclassified" || {
      echo "Findings sidecar section in $f does not mention holistic/unclassified" >&2
      return 1
    }
  done
  return 0
}
