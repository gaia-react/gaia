#!/usr/bin/env bats
#
# Doc-conformance suite for how the audit gate describes the orchestrator's
# limits.
#
# What it guards. The orchestrator that disposes findings and applies repairs is
# held to deterministic checks, so no page may describe it as trusted rather
# than bounded, and none may lean on a human watching every orchestrator turn.
# The member definition and the merge workflow page both state the replacement
# sentence verbatim, so the two cannot drift into saying different things about
# the same limit (UAT-019).
#
# Each target reads through an env override that defaults to the real file, so a
# mutant copy proves a case can fail without touching the tree. Assertion style:
# .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  FRONTEND="${DOC_ORCHESTRATOR_BOUNDS_FRONTEND:-$REPO_ROOT/.claude/agents/code-audit-frontend.md}"
  PR_MERGE="${DOC_ORCHESTRATOR_BOUNDS_PR_MERGE:-$REPO_ROOT/wiki/concepts/PR Merge Workflow.md}"
  TARGETS=("$FRONTEND" "$PR_MERGE")

  SENTENCE='The orchestrator is bounded, not trusted: `audit-dispositions-check.sh` bounds every disposition it makes and `audit-fix-verify.sh` bounds every repair.'
  TRUST_CLAIM='trusted rather than bounded|human watches every|watches every orchestrator turn|orchestrator is trusted|orchestrator itself is trusted'
}

# flat <file>: the file on one line, so a claim that wraps still matches.
flat() {
  tr '\n' ' ' <"$1" | tr -s ' '
}

# has_sentence <file>: the replacement sentence is present verbatim.
has_sentence() {
  flat "$1" | grep -qF -- "$SENTENCE"
}

# has_trust_claim <file>: the file describes the orchestrator as trusted or
# watched turn by turn.
has_trust_claim() {
  flat "$1" | grep -qiE -- "$TRUST_CLAIM"
}

@test "UAT-019: both targets exist and are non-empty" {
  local target
  [ "${#TARGETS[@]}" -eq 2 ]
  for target in "${TARGETS[@]}"; do
    [ -s "$target" ] || {
      echo "missing or empty: $target" >&2
      return 1
    }
  done
}

@test "UAT-019: the member definition and the merge workflow page both carry the replacement sentence" {
  local target
  for target in "${TARGETS[@]}"; do
    has_sentence "$target" || {
      echo "replacement sentence missing from: $target" >&2
      return 1
    }
  done
}

@test "UAT-019: neither target says a human watches every orchestrator turn or that the orchestrator is trusted" {
  local target
  for target in "${TARGETS[@]}"; do
    if has_trust_claim "$target"; then
      echo "trust claim present in: $target" >&2
      return 1
    fi
  done
}

@test "UAT-019 non-vacuity: the sentence check fails on a copy with the sentence removed" {
  local content
  content="$(cat "$PR_MERGE")"
  printf '%s\n' "${content//"$SENTENCE"/}" >"$BATS_TEST_TMPDIR/without-sentence.md"
  # Control: the real file passes, so the failure below is the mutation's.
  has_sentence "$PR_MERGE" || return 1
  if has_sentence "$BATS_TEST_TMPDIR/without-sentence.md"; then
    echo "removing the sentence did not make the check fail" >&2
    return 1
  fi
}

@test "UAT-019 non-vacuity: the trust check fails on a copy with the old trust sentence restored" {
  cp "$FRONTEND" "$BATS_TEST_TMPDIR/trusted.md"
  printf '\nThe orchestrator itself is not bound by the gate: it is trusted rather than bounded.\n' >>"$BATS_TEST_TMPDIR/trusted.md"
  cp "$PR_MERGE" "$BATS_TEST_TMPDIR/watched.md"
  printf '\nA human watches every orchestrator turn.\n' >>"$BATS_TEST_TMPDIR/watched.md"
  # Control: the real files pass, so the failures below are the mutations'.
  has_trust_claim "$FRONTEND" && return 1
  has_trust_claim "$PR_MERGE" && return 1
  has_trust_claim "$BATS_TEST_TMPDIR/trusted.md" || {
    echo "the restored trust sentence was not caught" >&2
    return 1
  }
  has_trust_claim "$BATS_TEST_TMPDIR/watched.md" || {
    echo "the restored watch claim was not caught" >&2
    return 1
  }
}
