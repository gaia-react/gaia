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
# AFTER the derivation it depends on. The final test proves the parity
# assertion is not vacuous by running it against a mutated copy.
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
  CHECK_LINE='dirty_in_scope=$(printf '"'"'%s\n'"'"' "$changed" | tr '"'"'\n'"'"' '"'"'\0'"'"' | xargs -0 git -C "$AUDIT_ROOT" status --porcelain -- 2>/dev/null || true)'

  # The byte-identical refusal contract.
  REFUSAL='**A non-empty `dirty_in_scope` REFUSES this pass.**'

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
    grep -qF -- "$CHECK_LINE" "$(member_path "$m")" || {
      echo "missing or drifted dirty-scope check: $m" >&2
      return 1
    }
  done
}

@test "every member carries the byte-identical refusal contract" {
  for m in $MEMBERS; do
    grep -qF -- "$REFUSAL" "$(member_path "$m")" || {
      echo "missing or drifted refusal contract: $m" >&2
      return 1
    }
  done
}

@test "the check sits after the changed= derivation it reads" {
  for m in $MEMBERS; do
    f="$(member_path "$m")"
    derivation_line="$(grep -nF -- 'changed=$(git -C "$AUDIT_ROOT" -c core.quotePath=false diff --name-only "${BASE_SHA}...HEAD"' "$f" | head -1 | cut -d: -f1)"
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
    grep -qF -- "$METHOD_ANCHOR" "$(member_path "$m")" || {
      echo "Methodology does not name the refusal: $m" >&2
      return 1
    }
  done
}

@test "the refusal briefs: every member owes the sidecar on the dirty path" {
  for m in $MEMBERS; do
    grep -qF -- "$SIDECAR_CLAUSE" "$(member_path "$m")" || {
      echo "refusal does not oblige the findings sidecar: $m" >&2
      return 1
    }
  done
}

# assert_cut_reds NEEDLE: copy a real member file, confirm the unmutated copy
# satisfies the assertion (so a red is the mutation talking and not a broken
# fixture), cut every line carrying NEEDLE, and confirm the assertion no longer
# holds. One helper per pinned string, because a suite that proves only its
# first assertion non-vacuous is how a second, hollow one rides along.
assert_cut_reds() {
  local needle="$1" src tmp
  src="$(member_path code-audit-maintainer-shell)"
  tmp="$BATS_TEST_TMPDIR/mutant-$2.md"
  cp "$src" "$tmp"

  grep -qF -- "$needle" "$tmp" || {
    echo "fixture is broken: needle absent before mutation" >&2
    return 1
  }

  grep -vF -- "$needle" "$tmp" > "$tmp.cut"
  mv "$tmp.cut" "$tmp"

  # The bad case written as a positive match, per the bats-assertions rule: a
  # `!`-negation here would be exempted by set -e and green silently.
  grep -qF -- "$needle" "$tmp" && {
    echo "mutation did not remove the needle; the proof would be hollow" >&2
    return 1
  }
  return 0
}

@test "parity assertion reds when a member drops the check (non-vacuity)" {
  assert_cut_reds "$CHECK_LINE" check
}

@test "refusal assertion reds when a member drops the contract (non-vacuity)" {
  assert_cut_reds "$REFUSAL" refusal
}

@test "sidecar assertion reds when a member drops the obligation (non-vacuity)" {
  assert_cut_reds "$SIDECAR_CLAUSE" sidecar
}

@test "run-order assertion reds when a member drops the anchor (non-vacuity)" {
  assert_cut_reds "$METHOD_ANCHOR" anchor
}
