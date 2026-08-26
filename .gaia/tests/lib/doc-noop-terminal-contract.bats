#!/usr/bin/env bats
# Doc-conformance for the no-op guard's TERMINAL action, the step taken after a
# second consecutive no-op. Detection and the single hardened re-dispatch are
# stated per surface and are not this suite's subject; the ending is, because
# the ending is what drifted.
#
# The shape of the defect this guards: the terminal action is restated on
# several prose surfaces, and one of them, the pre-merge audit gate, states a
# DIFFERENT ending on purpose (stop and surface, never inline fallback, because
# a Code Audit Team member's clearance marker is that member's own attestation).
# An undeclared deliberate exception is worse than drift: the safe-looking
# reading of an unexplained difference is that the agreeing sites are right and
# the odd one is stale, and acting on that turns a fail-closed merge gate into
# an orchestrator that reviews on a member's behalf and merges.
#
# So the assertions come in two halves. The roster half derives the set of
# surfaces stating a terminal action FROM THE TREE rather than restating it, so
# a further surface added with a third ending stops the suite instead of being
# silently uncovered, and a surface that drops the statement stops it too. The
# declaration half pins that the owner page states the general ending once, that
# it admits the exception rather than asserting uniformity, and that the merge
# gate declares its own departure and names the reason.
#
# Derivation, and why by phrase. No machine-readable artifact enumerates these
# surfaces; the coupling is prose-to-prose. The marker is the terminal-statement
# phrasing itself (`second consecutive no-op`, and the shorter `second no-op`),
# which is what a surface has to write to state an ending at all. Every surface
# spells it one of those two ways on purpose: a third spelling reads as prose
# and derives as nothing, so the marker is part of the contract. A short read
# is the hazard the bats-assertion rule names, so the roster test reconciles in
# BOTH directions and fails on an empty derivation rather than passing over one.
#
# Deliberately not members, each considered rather than missed:
#   - `.gaia/tests/`, `.gaia/local/`: this suite's own tree and untracked local
#     state, neither of which is a prose surface a reader consults.
#   - `wiki/log.md`, `wiki/hot.md`, `CHANGELOG.md`: historical records, exempt
#     from the present-tense prose rules generally, and a past ending recorded
#     there is not a claim about current behaviour.
#
# Honest limit: this pins what the surfaces SAY, never what an orchestrator
# does when a member no-ops twice. There is no oracle for the second thing, and
# the class this defect belongs to (a claim in prose about behaviour living in
# another file) is why `wiki/concepts/PR Merge Workflow.md`'s fix loop carries a
# sweep-by-the-claim procedure rather than a check.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
# `.gaia/tests/` is out of `wiki-style.md`'s scope entirely and release-
# excluded, so a GitHub reference in this header would be correct here; there
# is none because the tree, not an issue, is this suite's subject.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  # The owner of the general terminal action.
  OWNER_REL='wiki/concepts/Code Review Audit Agent.md'
  # The one surface that departs from it, deliberately.
  GATE_REL='wiki/concepts/PR Merge Workflow.md'
  # The ad-hoc dispatch rule, whose pointer has to resolve to the owner.
  RULE_REL='.claude/rules/subagent-dispatch.md'

  OWNER="$ROOT/$OWNER_REL"
  GATE="$ROOT/$GATE_REL"
  RULE="$ROOT/$RULE_REL"

  # Every surface expected to state a terminal action. The roster test
  # reconciles this against the tree in both directions.
  ROSTER=(
    '.claude/agents/code-audit-frontend.md'
    '.claude/rules/subagent-dispatch.md'
    '.claude/skills/gaia/references/plan.md'
    '.claude/skills/gaia/references/spec.md'
    'wiki/concepts/Code Review Audit Agent.md'
    'wiki/concepts/PR Merge Workflow.md'
  )

  TERMINAL_RE='second( consecutive)? no-op'
}

# derive_surfaces
# Prints, one repo-relative path per line, every tracked file stating a
# terminal action. Sorted, deduped, exclusions applied.
# Exit 0 with the paths on stdout, 1 for a clean read that matched nothing, 2
# for a derivation that could not run. Piping straight into `sort` would take
# sort's status instead, which makes a repository git cannot read produce the
# same empty result as a marker phrase that moved, and those want opposite
# repairs. `git grep` exits 1 on no-match and above 1 on a real failure.
derive_surfaces() {
  local raw rc
  # `|| rc=$?`, never a bare assignment then a `$?` read: an assignment takes
  # its command substitution's status, so under the errexit bats runs each body
  # with, the bare form abandons the caller HERE and every arm below is dead.
  rc=0
  raw="$(git -C "$ROOT" grep -lEI -- "$TERMINAL_RE" -- \
    ':!.gaia/tests/*' ':!.gaia/local/*' \
    ':!wiki/log.md' ':!wiki/hot.md' ':!CHANGELOG.md')" || rc=$?
  if [ "$rc" -gt 1 ]; then
    return 2
  fi
  if [ -z "$raw" ]; then
    return 1
  fi
  printf '%s\n' "$raw" | LC_ALL=C sort -u
  return 0
}

# terminal_lines <file>
# Prints only the lines of <file> that state a terminal action.
terminal_lines() {
  grep -E -- "$TERMINAL_RE" "$1"
}

# terminal_segments <file>
# Prints the terminal SENTENCE from each such line: the marker phrase through
# the next sentence break. These surfaces write a whole paragraph on one line,
# and every line stating an ending also names dispositions, file paths, and
# breadcrumbs further along it. A whole-line read is therefore satisfied by the
# word `inline` appearing anywhere on the paragraph, including inside an
# unrelated `inline_fallback` disposition value, which greens a sentence whose
# ending was rewritten to something else entirely.
#
# Per OCCURRENCE rather than per line, for the same reason one step down: a
# paragraph stating the ending twice, a drifted first sentence beside a still
# correct second one, collapses to whichever one an anchored extraction keeps,
# and the other goes unread. Every marker in the tree today sits alone on its
# line, so nothing is currently lost either way; the loop is what keeps that a
# property of the tree rather than a precondition of this check.
terminal_segments() {
  # Through the environment, not `-v`. Three regex engines now read this one
  # pattern (`git grep -E`, `grep -E`, and awk), and only awk's `-v` performs
  # escape processing on the value, stripping a backslash before the regex ever
  # compiles: `-v re='a\.b'` matches `aXb`, where both greps match a literal
  # dot. ENVIRON does no such processing, so one definition keeps one meaning
  # across all three.
  # The assignment rides awk, not terminal_lines: a `VAR=v cmd | cmd2` prefix
  # reaches only the FIRST stage, so putting it on the left of the pipe hands
  # awk an empty pattern, which matches empty at every position and spins the
  # loop below forever. The empty-pattern guard is the backstop for that class.
  terminal_lines "$1" | TERMINAL_RE="$TERMINAL_RE" awk '
    BEGIN {
      re = ENVIRON["TERMINAL_RE"]
      if (re == "") {
        print "terminal_segments: TERMINAL_RE did not reach awk" > "/dev/stderr"
        exit 2
      }
    }
    {
      rest = $0
      while (match(rest, re)) {
        start = RSTART
        len = RLENGTH
        seg = substr(rest, start)
        rest = substr(rest, start + len)
        # Cut at the first sentence break. A period with no space after it sits
        # inside a path or a section number, not at the end of a sentence.
        if (match(seg, /\. /)) seg = substr(seg, 1, RSTART - 1)
        print seg
      }
    }'
}

# --- The roster: who states an ending at all --------------------------------

@test "the set of surfaces stating a terminal action is the roster, in both directions" {
  local derived expected rc
  # `|| rc=$?` rather than a bare assignment followed by a `$?` read. bats runs
  # each body under errexit, and an assignment takes its command substitution's
  # status, so the bare form abandons the test ON the assignment line and every
  # branch below it, this diagnostic included, becomes unreachable.
  rc=0
  derived="$(derive_surfaces)" || rc=$?
  [ "$rc" -eq 2 ] && {
    echo "the derivation could not run; git could not read this tree" >&2
    return 1
  }
  [ "$rc" -eq 1 ] && {
    echo "derivation found no surface stating a terminal action; the marker phrasing moved" >&2
    return 1
  }
  expected="$(printf '%s\n' "${ROSTER[@]}" | LC_ALL=C sort -u)"
  [ "$derived" = "$expected" ] || {
    echo "roster and tree disagree; a surface was added, removed, or renamed:" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$derived") >&2 || true
    return 1
  }
}

@test "every roster surface but the merge gate ends inline, in the terminal statement itself" {
  local rel lines
  for rel in "${ROSTER[@]}"; do
    [ "$rel" = "$GATE_REL" ] && continue
    lines="$(terminal_segments "$ROOT/$rel")"
    [ -n "$lines" ] || { echo "no terminal statement read in ${rel}" >&2; return 1; }
    # Per statement, not per file: a file whose ending drifted at one of
    # several sites would still carry `inline` at the others and green a
    # whole-file grep.
    printf '%s\n' "$lines" | grep -qvi -- 'inline' && {
      echo "a terminal statement in ${rel} names no inline ending:" >&2
      printf '%s\n' "$lines" | grep -vi -- 'inline' >&2
      return 1
    }
    # And not the merge gate's ending. Requiring `inline` alone is satisfied by
    # a line that adopts the stop-and-surface ending while still naming the
    # inline fallback it no longer takes, which is the drift direction that
    # matters: the exception is warranted only where a clearance is at stake.
    printf '%s\n' "$lines" | grep -qi -- 'stop and surface' && {
      echo "a terminal statement in ${rel} takes the merge gate's exception, which is warranted only there:" >&2
      printf '%s\n' "$lines" | grep -i -- 'stop and surface' >&2
      return 1
    }
  done
  return 0
}

@test "the merge gate's terminal statement does not fall back inline" {
  local lines
  lines="$(terminal_segments "$GATE")"
  [ -n "$lines" ] || { echo "no terminal statement read in ${GATE_REL}" >&2; return 1; }
  printf '%s\n' "$lines" | grep -qi -- 'inline' && {
    echo "${GATE_REL}'s terminal statement now names an inline ending, which is the substitution the marker gate refuses:" >&2
    printf '%s\n' "$lines" | grep -i -- 'inline' >&2
    return 1
  }
  grep -qF -- 'stop and surface to the operator' "$GATE"
}

# --- The declaration: one owner, one admitted exception ---------------------

@test "the owner page states the general terminal action and claims ownership of it" {
  grep -qF -- 'The terminal action, stated once' "$OWNER"
  grep -qF -- 'this page owns the general rule' "$OWNER"
  grep -qFi -- 'inline fallback wherever the caller may legitimately do the work itself' "$OWNER"
}

@test "the owner page admits the merge gate's exception and states its reason" {
  grep -qF -- 'One surface departs from that ending, on purpose' "$OWNER"
  grep -qF -- '[[PR Merge Workflow]]' "$OWNER"
  # The reason, not merely the fact. Without it a reader cannot tell a
  # deliberate exception from an unmaintained one, which is the whole defect.
  grep -qF -- "own attestation" "$OWNER"
}

@test "the owner page no longer asserts a uniform ending across every surface" {
  grep -qF -- 'the same one-retry-then-inline-fallback shape' "$OWNER" && {
    echo "${OWNER_REL} asserts uniformity it does not have; the merge gate does not take that ending" >&2
    return 1
  }
  return 0
}

@test "the merge gate declares its departure as deliberate and names the owner" {
  grep -qF -- 'departs from the general contract deliberately' "$GATE"
  grep -qF -- '[[Code Review Audit Agent]]' "$GATE"
  grep -qF -- "own attestation" "$GATE"
  grep -qF -- 'fail-closed' "$GATE"
}

# --- The pointer: it has to resolve ----------------------------------------

@test "the dispatch rule's full-contract pointer names a file that exists and a heading it carries" {
  local line target section
  line="$(grep -m1 -F -- 'Full contract for this shape' "$RULE")"
  [ -n "$line" ] || { echo "no full-contract pointer read in ${RULE_REL}" >&2; return 1; }

  # Both halves come out of the pointer's own text, so a repoint that moves
  # either one is checked against the new destination rather than the old.
  # Anchored to the phrase: these surfaces write a whole paragraph on one
  # line, so an unanchored extraction reads whichever path the paragraph
  # happens to name first, which is a different pointer.
  line="${line#*Full contract for this shape}"
  target="$(printf '%s\n' "$line" | grep -oE '`[^`]+\.md`' | head -n 1 | tr -d '`')"
  [ -n "$target" ] || { echo "the pointer names no file" >&2; return 1; }
  [ -f "$ROOT/$target" ] || { echo "the pointer names ${target}, which does not exist" >&2; return 1; }

  section="$(printf '%s\n' "$line" | grep -oE '`[^`]+`' | grep -v '\.md`' | head -n 1 | tr -d '`')"
  [ -n "$section" ] || { echo "the pointer names no section" >&2; return 1; }
  # Fixed-string against heading lines only. The section name is text lifted
  # out of the pointer, so splicing it into an ERE lets a rename carrying a
  # metacharacter either over-match or make grep exit 2; the sibling test below
  # already matches its own destination as a fixed string.
  grep -E '^#+ ' "$ROOT/$target" | grep -qF -- "$section" || {
    echo "${target} carries no heading matching the pointed-at section '${section}'" >&2
    return 1
  }
}

@test "the dispatch rule's retry-prefix pointer names a file that carries the prefix" {
  local line target quoted
  line="$(grep -m1 -F -- 'hardened retry prefix is written out verbatim' "$RULE")"
  [ -n "$line" ] || { echo "no retry-prefix pointer read in ${RULE_REL}" >&2; return 1; }

  line="${line#*hardened retry prefix is written out verbatim}"
  target="$(printf '%s\n' "$line" | grep -oE '`[^`]+\.md`' | head -n 1 | tr -d '`')"
  [ -n "$target" ] || { echo "the retry-prefix pointer names no file" >&2; return 1; }
  [ -f "$ROOT/$target" ] || { echo "the pointer names ${target}, which does not exist" >&2; return 1; }

  # The quoted destination is the section title inside that file.
  quoted="$(printf '%s\n' "$line" | sed -n 's/.*("\([^"]*\)").*/\1/p')"
  [ -n "$quoted" ] || { echo "the retry-prefix pointer quotes no destination" >&2; return 1; }
  grep -qF -- "$quoted" "$ROOT/$target" || {
    echo "${target} does not carry the quoted destination '${quoted}'" >&2
    return 1
  }
  # The prefix itself, not merely a section named for it.
  grep -qF -- 'RETRY (hardened, one attempt only)' "$ROOT/$target"
}

@test "the dispatch rule cites no markdown path that has gone missing" {
  local p missing
  missing=''
  while IFS= read -r p; do
    [ -f "$ROOT/$p" ] || missing="${missing}${p}"$'\n'
  done < <(grep -oE '`[^`]+\.md`' "$RULE" | tr -d '`' | LC_ALL=C sort -u)
  [ -z "$missing" ] || {
    echo "${RULE_REL} cites markdown paths that do not exist:" >&2
    printf '%s' "$missing" >&2
    return 1
  }
}
