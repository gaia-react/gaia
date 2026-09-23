#!/usr/bin/env bats
# Doc-conformance for the standing early-stop paragraph ("How your run ends:
# ..."), the instruction a dispatched subagent's prompt carries so that it does
# not end its turn on a progress report and hand back a partial result that
# reads as finished.
#
# The paragraph is copied verbatim into every prompt that carries it, because a
# prompt author needs the text in place rather than behind a pointer. Copies
# drift, and a drifted copy still reads as the instruction, so this suite pins
# two things: which surfaces carry it, reconciled against the tree in BOTH
# directions, and that every copy is byte-identical to the owner's.
#
# The owner is `.claude/skills/gaia/references/plan.md`: edit the paragraph
# there first, then every roster member.
#
# Derivation is by the paragraph's own opening words, which a surface has to
# write to carry it at all. `.gaia/tests/` (this suite), `.gaia/local/`, and the
# historical records (`wiki/log.md`, `wiki/hot.md`, `CHANGELOG.md`) are not
# carriers.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  OWNER_REL='.claude/skills/gaia/references/plan.md'

  ROSTER=(
    '.claude/agents/code-audit-frontend.md'
    '.claude/skills/gaia/references/plan.md'
    '.gaia/cli/health/runbook.md'
    'wiki/concepts/PR Merge Workflow.md'
    'wiki/decisions/Claude Integration Fitness.md'
  )

  OPEN_RE='How your run ends: a reply with no tool call'
  # The whole paragraph, opening words to closing words, on one line.
  PARA_RE='How your run ends: .*then say which\.'
}

# derive_carriers
# Prints every tracked carrier, one repo-relative path per line, sorted.
# Exit 1 for a clean read that matched nothing, 2 when git could not read.
derive_carriers() {
  local raw rc
  rc=0
  raw="$(set -o pipefail; git -C "$ROOT" grep -lFI -z -- "$OPEN_RE" -- \
    ':!.gaia/tests/*' ':!.gaia/local/*' \
    ':!wiki/log.md' ':!wiki/hot.md' ':!CHANGELOG.md' | tr '\0' '\n')" || rc=$?
  if [ "$rc" -gt 1 ]; then
    return 2
  fi
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" | LC_ALL=C sort -u
}

@test "the carriers derived from the tree equal the roster, in both directions" {
  local derived rc expected
  rc=0
  derived="$(derive_carriers)" || rc=$?
  [ "$rc" -eq 0 ]
  expected="$(printf '%s\n' "${ROSTER[@]}" | LC_ALL=C sort -u)"
  if [ "$derived" != "$expected" ]; then
    printf 'derived:\n%s\nroster:\n%s\n' "$derived" "$expected" >&2
    return 1
  fi
}

@test "the owner carries exactly one copy of the paragraph" {
  local n
  n="$(grep -oE -- "$PARA_RE" "$ROOT/$OWNER_REL" | wc -l | tr -d ' ')"
  [ "$n" -eq 1 ]
}

@test "every copy on every roster member is byte-identical to the owner's" {
  local canon member copy count
  canon="$(grep -oE -- "$PARA_RE" "$ROOT/$OWNER_REL")"
  [ -n "$canon" ]
  for member in "${ROSTER[@]}"; do
    count=0
    while IFS= read -r copy; do
      count=$((count + 1))
      if [ "$copy" != "$canon" ]; then
        printf 'drifted copy in %s:\n%s\n' "$member" "$copy" >&2
        return 1
      fi
    done < <(grep -oE -- "$PARA_RE" "$ROOT/$member")
    # A member whose paragraph was split across lines, or truncated before its
    # closing words, matches the opening but never the whole paragraph.
    if [ "$count" -lt 1 ]; then
      printf '%s carries the opening words but no complete paragraph\n' "$member" >&2
      return 1
    fi
  done
}

@test "every carrier's opening-words count equals its complete-paragraph count" {
  local member opens whole
  for member in "${ROSTER[@]}"; do
    opens="$(grep -oF -- "$OPEN_RE" "$ROOT/$member" | wc -l | tr -d ' ')"
    whole="$(grep -oE -- "$PARA_RE" "$ROOT/$member" | wc -l | tr -d ' ')"
    if [ "$opens" -ne "$whole" ]; then
      printf '%s: %s openings, %s complete paragraphs\n' "$member" "$opens" "$whole" >&2
      return 1
    fi
  done
}
