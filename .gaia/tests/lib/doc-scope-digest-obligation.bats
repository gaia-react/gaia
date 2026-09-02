#!/usr/bin/env bats
# SPEC-077: doc-grep coverage for the scope-resolution obligation prose that
# holds the writer's --scope-digest gate meaningful. Nothing type-checks a
# markdown instruction and no runtime assertion fires when a future edit to
# one of the five agent definitions, or to the registration page the next
# member author reads, drops a sentence or quietly paraphrases it. This
# suite pins the frozen literals the way doc-machinery-waive-prose.bats pins
# its own: grep for the text, ground-truthed against the actual source
# (verified against the tree as it stands after Phase 1 of this SPEC
# landed), never a paraphrase transcribed into the test.
#
# Three literals, three reasons:
#   Group 1: FC-2a's obligation sentence, byte-identical in every agent
#     definitions. This is the prose half of what
#     .gaia/scripts/check-scope-digest-adoption.sh's assertion 2 already
#     proves mechanically; this suite exists so the pin survives even if
#     that check is ever weakened, and because the check's own text is
#     itself read from the tree rather than hardcoded, so nothing else pins
#     the literal's own wording against silent rewrite.
#   Group 2: the same sentence in wiki/concepts/Registering a Code Audit
#     Team Member.md step 1 -- the reason it needs its own pin is that the
#     next member registered reads that page, not the five existing
#     definitions, so a drift there is invisible to every existing member's
#     own conformance.
#   Group 3: code-audit-maintainer-prose.md's compare-and-record
#     instruction. The writer-side test suite proves the marker publishes
#     and the exit status is 0 on a rotated scope for this member (its
#     --scope-digest check is advisory, never blocking); nothing else proves
#     the rotation is actually RECORDED as a finding rather than silently
#     dropped, and this literal is the only mechanism holding that
#     instruction in place.
#
# Honest limit: presence and byte-identity, not meaning and not behavior.
# This suite cannot tell whether a member that carries the literal actually
# captures anything at runtime, or whether the prose member's own findings
# sidecar in a live run really carries a rotation record; it only proves the
# instruction survives verbatim in the file a member or a human reads.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
# `.gaia/tests/` is out of `wiki-style.md`'s scope entirely and release-
# excluded, so the SPEC traceability above is correct and expected here,
# unlike in the shipped prose this suite guards.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  # Discovered, not transcribed. A hardcoded list here would assert the
  # obligation literal over the definitions that existed the day this suite
  # was written, and stay green for a newly registered member that never
  # carried the literal at all -- the same blindness the sibling check
  # .gaia/scripts/check-scope-digest-adoption.sh was repaired for.
  AGENTS=()
  local agent
  for agent in "$ROOT"/.claude/agents/code-audit-*.md; do
    [ -f "$agent" ] && AGENTS+=("$agent")
  done
  # An empty discovery has verified nothing; fail rather than pass vacuously.
  [ "${#AGENTS[@]}" -gt 0 ] || return 1
  PROSE_MEMBER="$ROOT/.claude/agents/code-audit-maintainer-prose.md"
  REGISTRATION="$ROOT/wiki/concepts/Registering a Code Audit Team Member.md"

  # FC-2a, verbatim.
  OBLIGATION_LITERAL='Capture your own content digest at scope resolution with `.gaia/scripts/audit-scope-digest.sh --capture`, and at marker-write time read that captured value back with `--read` and pass it as `--scope-digest`; never re-derive it in the writing call, and a rotation between the two means the review was superseded and you must be re-dispatched on the new HEAD.'

  # The prose member's compare-and-record instruction, verbatim (excludes
  # the trailing "You still write your earned clearance and never block the
  # merge." sentence that follows it in the file -- that sentence restates
  # the member's advisory-only posture, stated and pinned separately in the
  # member's own "Advisory-only" section, not part of this obligation).
  COMPARE_AND_RECORD_LITERAL='Before writing your findings sidecar, read your captured scope digest back with `--read` and compare it to a fresh derive; when they differ, record the rotated review scope as a finding in the sidecar and say so in your report.'
}

# --- Group 1: FC-2a is byte-identical in every agent definition -----------

@test "Group 1: the obligation literal is present in every agent definition" {
  local f
  for f in "${AGENTS[@]}"; do
    grep -qF -- "$OBLIGATION_LITERAL" "$f" || {
      echo "obligation literal missing from $f" >&2
      return 1
    }
  done
}

@test "Group 1: the obligation literal appears exactly once per agent definition" {
  local f count
  for f in "${AGENTS[@]}"; do
    count="$(grep -cF -- "$OBLIGATION_LITERAL" "$f")"
    [ "$count" -eq 1 ] || {
      echo "obligation literal appears $count times in $f, expected exactly 1" >&2
      return 1
    }
  done
}

# --- Group 2: the same sentence reaches the registration page --------------

@test "Group 2: the obligation literal is present in the registration page's step 1" {
  grep -qF -- "$OBLIGATION_LITERAL" "$REGISTRATION" || {
    echo "obligation literal missing from $REGISTRATION" >&2
    return 1
  }
}

@test "Group 2: the registration page's mention sits under its step-1 heading" {
  # extract_section_or_fail's shape (doc-machinery-waive-prose.bats): fail
  # loudly rather than pass vacuously when the heading itself is gone.
  local section
  section="$(awk '
    /^### 1\. / { found=1; print; next }
    found && /^### / { exit }
    found { print }
  ' "$REGISTRATION")"
  [ -n "$section" ] || {
    echo "step-1 heading matched nothing in $REGISTRATION" >&2
    return 1
  }
  printf '%s\n' "$section" | grep -qF -- "$OBLIGATION_LITERAL" || {
    echo "obligation literal is present in $REGISTRATION but outside its step-1 section" >&2
    return 1
  }
}

# --- Group 3: the prose member's compare-and-record instruction ------------

@test "Group 3: the compare-and-record instruction is present in the prose member's definition" {
  grep -qF -- "$COMPARE_AND_RECORD_LITERAL" "$PROSE_MEMBER" || {
    echo "compare-and-record instruction missing from $PROSE_MEMBER" >&2
    return 1
  }
}

@test "Group 3: the compare-and-record instruction appears exactly once" {
  local count
  count="$(grep -cF -- "$COMPARE_AND_RECORD_LITERAL" "$PROSE_MEMBER")"
  [ "$count" -eq 1 ] || {
    echo "compare-and-record instruction appears $count times in $PROSE_MEMBER, expected exactly 1" >&2
    return 1
  }
}

@test "Group 3: no other agent definition carries the prose member's compare-and-record instruction" {
  # This instruction is specific to code-audit-maintainer-prose.md's
  # advisory-only posture (it never refuses, so a rotated scope becomes a
  # recorded finding instead of a block); the other four members' identical
  # posture would be wrong for them, so it must not have been copy-pasted
  # across the roster.
  local f
  for f in "${AGENTS[@]}"; do
    [ "$f" = "$PROSE_MEMBER" ] && continue
    grep -qF -- "$COMPARE_AND_RECORD_LITERAL" "$f" && {
      echo "compare-and-record instruction unexpectedly present in $f" >&2
      return 1
    }
  done
  true
}
