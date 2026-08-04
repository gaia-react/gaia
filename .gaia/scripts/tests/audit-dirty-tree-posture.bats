#!/usr/bin/env bats
# The Code Audit Team's dirty-tree posture, held across all five members.
#
# A member's clearance marker attests to a per-member content digest computed
# over tracked files AT HEAD (`git ls-tree HEAD`,
# .claude/hooks/lib/audit-digest.sh), while the member reviews a file by
# `Read`ing it, which returns WORKING-TREE bytes. On a dirty tree those two
# disagree, so a pass that reviews the working copy can write a marker
# certifying content nobody read. The posture that closes it is a refusal:
# each member checks `git status --porcelain` over its OWN resolved `changed`
# set immediately after resolving it, and refuses the pass when that set is
# dirty.
#
# Scoping the check to `changed` rather than the whole tree is load-bearing in
# both directions. It is wide enough, because `changed` is exactly the set the
# member reads and certifies. And it is narrow enough that a sibling member
# self-healing in a different remit, which is legitimate and expected under
# concurrent dispatch, cannot refuse this member's pass.
#
# These assertions are structural, in the shape of audit-guard-structural.bats:
# the posture is agent-executed instruction prose rather than code, so it
# cannot be exercised end to end. What is checkable is that every member
# carries the same check, the same refusal contract, and carries the check
# AFTER the derivation it depends on. Every pin carries its own non-vacuity
# proof at the bottom of this file; see the comment there for why those are
# meaning-changing edits rather than deletions of the pinned string.
#
# Assertion style note (`.claude/rules/bats-assertions.md`): macOS's system
# `/bin/bash` (3.2) does not fail a bats @test on a false bare `[[ ... ]]`
# that isn't the test's last command, so assertions below use `grep -qF` /
# `[ ]` (real exit codes) or an explicit `return 1`, never a bare `[[ ]]`.

setup() {
  THIS_DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIR/../../.." && pwd )"

  # All five Code Audit Team members. The list is spelled out rather than
  # globbed: a glob would silently pass if a member file were renamed away,
  # which is the fail-open this suite exists to prevent.
  MEMBERS="code-audit-frontend
code-audit-github-workflows
code-audit-maintainer-node
code-audit-maintainer-prose
code-audit-maintainer-shell"

  # The byte-identical detection line. One line on purpose: a wrapped command
  # cannot be asserted byte-for-byte with a fixed-string grep, and byte
  # identity across five files is what keeps the members from drifting into
  # five subtly different checks.
  CHECK_LINE='if [ -n "$changed" ] && ! dirty_in_scope=$(printf '"'"'%s\n'"'"' "$changed" | tr '"'"'\n'"'"' '"'"'\0'"'"' | xargs -0 git -C "$AUDIT_ROOT" status --porcelain --); then'

  # The byte-identical print of the result. Load-bearing rather than cosmetic:
  # shell state does not survive between an agent's Bash calls, so a check whose
  # answer is never printed cannot reach any decision the member makes.
  PRINT_LINE='if [ -n "$dirty_in_scope" ]; then printf '"'"'DIRTY IN REVIEW SCOPE:\n%s\n'"'"' "$dirty_in_scope" >&2; fi'

  # The sentinel the remit filter must never discard, and the artifact rule that
  # keeps a withheld pass from stranding a digest-keyed refusal across a revert.
  SENTINEL_CARVEOUT='is a sentinel rather than a path and withholds unconditionally'
  NO_REFUSAL_ARTIFACT='**Withhold without writing a `.refused` artifact.**'

  # The byte-identical refusal contract.
  REFUSAL='**A non-empty `dirty_in_scope` WITHHOLDS this pass.**'

  # The obligation the refusal owes, pinned separately from the sentence that
  # opens it. A refusal that briefs nothing blocks a merge no one can clear, so
  # the sidecar write is the load-bearing half; pinning only the bolded opener
  # would let this clause be reworded or dropped with the suite still green.
  SIDECAR_CLAUSE='write the findings sidecar naming each dirty path'

  # The run-order anchor, so the refusal is reachable from the member's own
  # order of operations rather than stated only beside the code block. The
  # four specialists carry it in Methodology step 1; the default member's
  # scope run order lives under "Rules-Based Audit" -> "How to run", and it
  # carries the same phrase there.
  METHOD_ANCHOR='refuse the pass when the working tree is dirty within `changed`'
}

member_path() {
  printf '%s/.claude/agents/%s.md' "$REPO_ROOT" "$1"
}

@test "every member file exists" {
  for m in $MEMBERS; do
    [ -f "$(member_path "$m")" ] || return 1
  done
}

@test "every member carries the byte-identical dirty-scope check" {
  for m in $MEMBERS; do
    assert_carries "$(member_path "$m")" "$CHECK_LINE" || {
      echo "missing or drifted dirty-scope check: $m" >&2
      return 1
    }
  done
}

@test "every member carries the byte-identical refusal contract" {
  for m in $MEMBERS; do
    assert_carries "$(member_path "$m")" "$REFUSAL" || {
      echo "missing or drifted refusal contract: $m" >&2
      return 1
    }
  done
}

@test "the check sits after the changed= derivation it reads" {
  for m in $MEMBERS; do
    f="$(member_path "$m")"
    derivation_line="$(grep -nF -- 'changed=$(git -C "$AUDIT_ROOT" diff --name-only -z "${BASE_SHA}...HEAD"' "$f" | head -1 | cut -d: -f1)"
    check_line="$(grep -nF -- "$CHECK_LINE" "$f" | head -1 | cut -d: -f1)"
    [ -n "$derivation_line" ] || { echo "no review-base derivation found: $m" >&2; return 1; }
    [ -n "$check_line" ] || { echo "no dirty-scope check found: $m" >&2; return 1; }
    [ "$check_line" -gt "$derivation_line" ] || {
      echo "dirty-scope check precedes the derivation it reads: $m" >&2
      return 1
    }
  done
}

@test "every member names the refusal in its run order" {
  for m in $MEMBERS; do
    assert_carries "$(member_path "$m")" "$METHOD_ANCHOR" || {
      echo "run order does not name the refusal: $m" >&2
      return 1
    }
  done
}

@test "every member prints the result it computed" {
  for m in $MEMBERS; do
    assert_carries "$(member_path "$m")" "$PRINT_LINE" || {
      echo "computes dirty_in_scope and never prints it: $m" >&2
      return 1
    }
  done
}

@test "every member exempts the failure sentinel from the remit filter" {
  for m in $MEMBERS; do
    assert_carries "$(member_path "$m")" "$SENTINEL_CARVEOUT" || {
      echo "fail-closed sentinel is filterable away: $m" >&2
      return 1
    }
  done
}

@test "every member withholds without stranding a refusal artifact" {
  for m in $MEMBERS; do
    assert_carries "$(member_path "$m")" "$NO_REFUSAL_ARTIFACT" || {
      echo "does not forbid the digest-keyed refusal artifact: $m" >&2
      return 1
    }
  done
}

@test "the refusal briefs: every member owes the sidecar on the dirty path" {
  for m in $MEMBERS; do
    assert_carries "$(member_path "$m")" "$SIDECAR_CLAUSE" || {
      echo "refusal does not oblige the findings sidecar: $m" >&2
      return 1
    }
  done
}

# --- Non-vacuity ------------------------------------------------------------
#
# These prove the pins above are worth something, and they are deliberately NOT
# "delete the pinned string, confirm it is gone". That form is a tautology: it
# can only fail if `grep -v` is broken, so it holds for any pin however weak,
# including the hollow one an earlier revision of this suite actually carried.
#
# Each proof instead applies a MEANING-CHANGING edit to a copy of a real member
# and requires the pin to stop holding. A pin strong enough to be worth having
# breaks under it; a pin weakened to some short common substring survives the
# edit, the assertion still holds, and the proof reds. That is the property
# worth asserting, and it needs no arbitrary minimum-length floor to get it.

# assert_carries FILE NEEDLE: the single definition of "this file satisfies the
# pin". Both the real-member tests and the mutants call THIS function, so a
# mutant cannot pass by exercising a re-implementation of the check.
assert_carries() {
  grep -qF -- "$2" "$1"
}

# mutate_member TAG SED_EXPR: copy the shell member, confirm the copy satisfies
# NEEDLE before the edit (so a red is the mutation talking, not a broken
# fixture), apply the edit, and print the mutant's path.
mutate_member() {
  local tag="$1" expr="$2" needle="$3" tmp="$BATS_TEST_TMPDIR/mutant-$1.md"
  cp "$(member_path code-audit-maintainer-shell)" "$tmp"
  assert_carries "$tmp" "$needle" || {
    echo "fixture broken: pin does not hold before mutation ($tag)" >&2
    return 1
  }
  sed "$expr" "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  printf '%s' "$tmp"
}

# assert_pin_breaks TAG SED_EXPR NEEDLE: the whole shape in one line.
assert_pin_breaks() {
  local mutant
  mutant="$(mutate_member "$1" "$2" "$3")" || return 1
  # Bad case written as a positive match per the bats-assertions rule: a
  # `!`-negation here would be exempted by set -e and green silently.
  assert_carries "$mutant" "$3" && {
    echo "pin still holds after a meaning-changing edit; it is too weak to assert the posture ($1)" >&2
    return 1
  }
  return 0
}

@test "the check pin breaks when the status call changes meaning (non-vacuity)" {
  # --untracked-files=no narrows what the check can see. A pin that does not
  # cover the status invocation survives this and the test reds.
  assert_pin_breaks check 's|status --porcelain --|status --porcelain --untracked-files=no --|' "$CHECK_LINE"
}

@test "the refusal pin breaks when the refusal becomes a warning (non-vacuity)" {
  assert_pin_breaks refusal 's|WITHHOLDS this pass|is worth noting|' "$REFUSAL"
}

@test "the print pin breaks when the result stops reaching stderr (non-vacuity)" {
  assert_pin_breaks print 's|>&2; fi|; fi|' "$PRINT_LINE"
}

@test "the sentinel pin breaks when the carve-out is softened (non-vacuity)" {
  assert_pin_breaks sentinel 's|withholds unconditionally|is worth a look|' "$SENTINEL_CARVEOUT"
}

@test "the artifact pin breaks when the prohibition is softened (non-vacuity)" {
  assert_pin_breaks artifact 's|Withhold without writing|Consider not writing|' "$NO_REFUSAL_ARTIFACT"
}

@test "the sidecar pin breaks when the obligation is softened (non-vacuity)" {
  assert_pin_breaks sidecar 's|write the findings sidecar naming each dirty path|mention the dirty paths somewhere|' "$SIDECAR_CLAUSE"
}

@test "the run-order pin breaks when the anchor stops refusing (non-vacuity)" {
  assert_pin_breaks anchor 's|refuse the pass when the working tree is dirty|warn when the working tree is dirty|' "$METHOD_ANCHOR"
}
